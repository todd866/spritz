use crate::ax::{inspect_focused_element_for_pid, read_field_value_and_selection};
use crate::cf::{dispatch_main, CFRef};
use spritz_core::dictation::{build_text_review_prompt, RefinementResult, REFINEMENT_SCHEMA_JSON};
use spritz_core::insertion::DictatedInsertion;
use spritz_core::telemetry::TelemetryMetric;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct BaselineCapture {
    pub element: CFRef,
    pub pid: i32,
    pub focus_generation: u64,
    pub before: String,
    pub sel_loc: usize,
    pub sel_len: usize,
}

pub enum NativeCaptureEvent {
    BaselineFailed(u64),
    DiffMismatch(u64),
    Timeout(u64),
    Captured {
        gen_id: u64,
        text: String,
        baseline: BaselineCapture,
    },
}

pub struct NativeDictationCapture {
    generation: Arc<AtomicU64>,
    state: Arc<Mutex<NativeCaptureInner>>,
}

struct NativeCaptureInner {
    gen_id: u64,
    active: bool,
    released: bool,
    baseline: Option<BaselineCapture>,
}

impl Default for NativeDictationCapture {
    fn default() -> Self {
        Self {
            generation: Arc::new(AtomicU64::new(0)),
            state: Arc::new(Mutex::new(NativeCaptureInner {
                gen_id: 0,
                active: false,
                released: false,
                baseline: None,
            })),
        }
    }
}

impl NativeDictationCapture {
    pub fn cancel(&self) -> u64 {
        let next = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let mut st = self.state.lock().unwrap();
        st.gen_id = next;
        st.active = false;
        st.released = false;
        st.baseline = None;
        next
    }

    pub fn start<F>(&self, pid: i32, focus_generation: u64, on_event: F)
    where
        F: Fn(NativeCaptureEvent) + Send + Sync + 'static,
    {
        let gen_id = self.cancel();
        {
            let mut st = self.state.lock().unwrap();
            st.active = true;
        }
        let gen_arc = Arc::clone(&self.generation);
        let state_arc = Arc::clone(&self.state);
        let cb = Arc::new(on_event);

        std::thread::spawn(move || {
            if gen_arc.load(Ordering::SeqCst) != gen_id {
                return;
            }
            let snap = inspect_focused_element_for_pid(pid, 0.25);
            if gen_arc.load(Ordering::SeqCst) != gen_id {
                return;
            }
            let Some(el) = snap.element.filter(|_| snap.is_editable && !snap.is_secure) else {
                dispatch_main(move || cb(NativeCaptureEvent::BaselineFailed(gen_id)));
                return;
            };
            let Some((val, loc, len)) = read_field_value_and_selection(&el, 0.25) else {
                dispatch_main(move || cb(NativeCaptureEvent::BaselineFailed(gen_id)));
                return;
            };
            if gen_arc.load(Ordering::SeqCst) != gen_id {
                return;
            }
            let baseline = BaselineCapture {
                element: el,
                pid,
                focus_generation,
                before: val,
                sel_loc: loc,
                sel_len: len,
            };
            let should_poll = {
                let mut st = state_arc.lock().unwrap();
                if st.gen_id != gen_id || !st.active {
                    return;
                }
                st.baseline = Some(baseline.clone());
                st.released
            };
            if should_poll {
                run_poll_loop(gen_id, gen_arc, baseline, cb);
            }
        });
    }

    pub fn finish<F>(&self, on_event: F)
    where
        F: Fn(NativeCaptureEvent) + Send + Sync + 'static,
    {
        let (gen_id, baseline) = {
            let mut st = self.state.lock().unwrap();
            if !st.active {
                return;
            }
            st.released = true;
            (st.gen_id, st.baseline.clone())
        };
        if let Some(baseline) = baseline {
            let gen_arc = Arc::clone(&self.generation);
            let cb = Arc::new(on_event);
            std::thread::spawn(move || {
                run_poll_loop(gen_id, gen_arc, baseline, cb);
            });
        }
    }
}

fn run_poll_loop<F>(
    gen_id: u64,
    gen_arc: Arc<AtomicU64>,
    baseline: BaselineCapture,
    cb: Arc<F>,
) where
    F: Fn(NativeCaptureEvent) + Send + Sync + 'static,
{
    let mut previous: Option<String> = None;
    let mut stable = 0u32;
    let mut transient_errors = 0u32;
    let mut mismatch_streak = 0u32;

    for _ in 0..120 {
        std::thread::sleep(Duration::from_millis(250));
        if gen_arc.load(Ordering::SeqCst) != gen_id {
            return;
        }
        let Some((val, loc, len)) = read_field_value_and_selection(&baseline.element, 0.25) else {
            transient_errors += 1;
            if transient_errors >= 3 {
                dispatch_main(move || cb(NativeCaptureEvent::DiffMismatch(gen_id)));
                return;
            }
            continue;
        };
        transient_errors = 0;

        if val == baseline.before {
            mismatch_streak = 0;
            continue;
        }

        let Some(text) = DictatedInsertion::extract(
            &baseline.before,
            baseline.sel_loc,
            baseline.sel_len,
            &val,
            loc,
            len,
        ) else {
            mismatch_streak += 1;
            if mismatch_streak >= 3 {
                dispatch_main(move || cb(NativeCaptureEvent::DiffMismatch(gen_id)));
                return;
            }
            continue;
        };
        mismatch_streak = 0;

        if previous.as_deref() == Some(text.as_str()) {
            stable += 1;
        } else {
            stable = 0;
            previous = Some(text.clone());
        }

        if stable >= 2 {
            dispatch_main(move || {
                cb(NativeCaptureEvent::Captured {
                    gen_id,
                    text,
                    baseline,
                })
            });
            return;
        }
    }

    dispatch_main(move || cb(NativeCaptureEvent::Timeout(gen_id)));
}

// MARK: - Agy Refinement Runner

#[derive(Default)]
pub struct AgyRefinementRunner {
    token: Arc<AtomicU64>,
    live_child_pid: Arc<Mutex<Option<u32>>>,
}

impl AgyRefinementRunner {
    pub fn resolve_executable() -> Option<PathBuf> {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let candidates = [
            home.join(".local/bin/agy"),
            PathBuf::from("/opt/homebrew/bin/agy"),
            PathBuf::from("/usr/local/bin/agy"),
        ];
        candidates.into_iter().find(|p| is_executable(p))
    }

    pub fn cancel(&self) {
        self.token.fetch_add(1, Ordering::SeqCst);
        let pid = self.live_child_pid.lock().unwrap().take();
        if let Some(pid) = pid {
            terminate_pid(pid);
        }
    }

    pub fn run<F>(&self, session_id: u64, transcript: String, on_done: F)
    where
        F: FnOnce(u64, Option<RefinementResult>, TelemetryMetric, f64) + Send + 'static,
    {
        self.cancel();
        let my_token = self.token.load(Ordering::SeqCst);
        let Some(exe) = Self::resolve_executable() else {
            dispatch_main(move || on_done(session_id, None, TelemetryMetric::RefinementFailure, 0.0));
            return;
        };
        let token_arc = Arc::clone(&self.token);
        let pid_slot = Arc::clone(&self.live_child_pid);

        std::thread::spawn(move || {
            let started = Instant::now();
            let home = std::env::var("HOME").unwrap_or_default();
            let exec_dir = exe
                .parent()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let path_env = format!("{exec_dir}:{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin");

            let mut cmd = Command::new(&exe);
            cmd.args([
                "-p",
                "--model",
                "gemini-4-hydrogen-low",
                "--disable-slash-commands",
                "--output-format",
                "json",
                "--json-schema",
                REFINEMENT_SCHEMA_JSON,
            ])
            .current_dir("/private/tmp")
            .env("PATH", path_env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());

            for k in [
                "GEMINI_API_KEY",
                "GOOGLE_API_KEY",
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
            ] {
                cmd.env_remove(k);
            }

            let Ok(mut child) = cmd.spawn() else {
                dispatch_main(move || on_done(session_id, None, TelemetryMetric::RefinementFailure, 0.0));
                return;
            };

            let child_pid = child.id();
            {
                let mut guard = pid_slot.lock().unwrap();
                if token_arc.load(Ordering::SeqCst) != my_token {
                    drop(guard);
                    terminate_pid(child_pid);
                    let _ = child.wait();
                    return;
                }
                *guard = Some(child_pid);
            }

            let prompt = build_text_review_prompt(&transcript, None);
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(prompt.as_bytes());
            }

            let stdout = child.stdout.take();
            let reader_buf = Arc::new(Mutex::new(Vec::<u8>::new()));
            let reader_done = Arc::new(AtomicBool::new(false));
            if let Some(mut out) = stdout {
                let buf = Arc::clone(&reader_buf);
                let done = Arc::clone(&reader_done);
                std::thread::spawn(move || {
                    let mut tmp = [0u8; 8192];
                    while let Ok(n) = out.read(&mut tmp) {
                        if n == 0 {
                            break;
                        }
                        let mut b = buf.lock().unwrap();
                        if b.len() < 512_000 {
                            let rem = 512_000 - b.len();
                            b.extend_from_slice(&tmp[..n.min(rem)]);
                        }
                    }
                    done.store(true, Ordering::SeqCst);
                });
            } else {
                reader_done.store(true, Ordering::SeqCst);
            }

            let deadline = Duration::from_secs(45);
            let exit_ok = loop {
                if token_arc.load(Ordering::SeqCst) != my_token {
                    terminate_pid(child_pid);
                    let _ = child.wait();
                    return;
                }
                match child.try_wait() {
                    Ok(Some(status)) => break status.success(),
                    Ok(None) => {
                        if started.elapsed() >= deadline {
                            terminate_pid(child_pid);
                            let _ = child.wait();
                            break false;
                        }
                        std::thread::sleep(Duration::from_millis(50));
                    }
                    Err(_) => break false,
                }
            };

            {
                let mut guard = pid_slot.lock().unwrap();
                if *guard == Some(child_pid) {
                    *guard = None;
                }
            }

            // Wait briefly for stdout pipe EOF after process exit.
            let flush_until = Instant::now() + Duration::from_millis(200);
            while !reader_done.load(Ordering::SeqCst) && Instant::now() < flush_until {
                std::thread::sleep(Duration::from_millis(10));
            }

            if token_arc.load(Ordering::SeqCst) != my_token {
                return;
            }

            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            let parsed = if exit_ok {
                let raw = String::from_utf8_lossy(&reader_buf.lock().unwrap()).into_owned();
                RefinementResult::parse_agy(&raw)
            } else {
                None
            };
            let metric = if parsed.is_some() {
                TelemetryMetric::RefinementReady
            } else {
                TelemetryMetric::RefinementFailure
            };
            dispatch_main(move || on_done(session_id, parsed, metric, elapsed_ms));
        });
    }
}

fn is_executable(path: &PathBuf) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && (m.permissions().mode() & 0o111 != 0))
        .unwrap_or(false)
}

fn terminate_pid(pid: u32) {
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(2));
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGKILL);
        }
    });
}
