use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone)]
pub struct ChatGptWatcher {
    chat_running: Arc<AtomicBool>,
    fn_hook_active: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

impl ChatGptWatcher {
    pub fn start() -> Self {
        let chat_running = Arc::new(AtomicBool::new(false));
        let fn_hook_active = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));

        let cr = Arc::clone(&chat_running);
        let fa = Arc::clone(&fn_hook_active);
        let st = Arc::clone(&stop);
        std::thread::spawn(move || {
            while !st.load(Ordering::Relaxed) {
                if cr.load(Ordering::Relaxed) {
                    let uid = unsafe { libc::getuid() };
                    let active = Command::new("/usr/bin/pgrep")
                        .args(["-u", &uid.to_string(), "-f", "bare-modifier-monitor.*--key Fn"])
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .status()
                        .map_or(false, |s| s.success());
                    fa.store(active, Ordering::Relaxed);
                } else {
                    fa.store(false, Ordering::Relaxed);
                }
                for _ in 0..60 {
                    if st.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
        });

        Self {
            chat_running,
            fn_hook_active,
            stop,
        }
    }

    pub fn set_chatgpt_running(&self, running: bool) {
        self.chat_running.store(running, Ordering::Relaxed);
        if !running {
            self.fn_hook_active.store(false, Ordering::Relaxed);
            return;
        }
        let fa = Arc::clone(&self.fn_hook_active);
        let cr = Arc::clone(&self.chat_running);
        std::thread::spawn(move || {
            if !cr.load(Ordering::Relaxed) {
                return;
            }
            let uid = unsafe { libc::getuid() };
            let active = Command::new("/usr/bin/pgrep")
                .args(["-u", &uid.to_string(), "-f", "bare-modifier-monitor.*--key Fn"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map_or(false, |s| s.success());
            fa.store(active, Ordering::Relaxed);
        });
    }

    pub fn is_running(&self) -> bool {
        self.chat_running.load(Ordering::Relaxed)
    }

    pub fn is_fn_hook_active(&self) -> bool {
        self.fn_hook_active.load(Ordering::Relaxed)
    }
}

impl Drop for ChatGptWatcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}
