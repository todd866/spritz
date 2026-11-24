use crate::ax::{
    self, is_accessibility_trusted, is_classic_text_role, read_preceding_context,
    resolve_caret_for_cache, spawn_ax_snapshot, verify_focused_element_fast, CaretResolution,
    FocusSnapshot, FocusedElementCache,
};
use crate::cf::{dispatch_main, ensure_main_dispatcher_installed, epoch_secs, monotonic_uptime_secs, CFRef, CGRect, MainTimer};
use crate::chatgpt_watch::ChatGptWatcher;
use crate::event_tap::{has_input_monitoring_permission, EventTap, EventTapSink, KeyInput};
use crate::inserter;
use crate::refinement::{AgyRefinementRunner, NativeCaptureEvent, NativeDictationCapture};
use crate::secure_input::{is_secure_event_input_enabled, secure_input_holder_pid};
use crate::system_picker::{
    restore_globe_key, set_cgs_character_palette_enabled, take_over_globe_key, CarbonToggleHotkey,
};
use crate::touchbar_io::TouchBarWriter;
use serde::Serialize;
use spritz_core::config::{SpritzConfig, SpritzState};
use spritz_core::db::EmojiDatabase;
use spritz_core::dictation::{DictationReceipt, DictationState, RefinementProvider, VoiceMode};
use spritz_core::emoji::{EmojiCategory, SkinTone};
use spritz_core::fn_gesture::FnAction;
use spritz_core::insertion::{BrowserPickPolicy, RecentTypingState};
use spritz_core::slots::{Direction, DragOutcome, PickerMode, PickerModel};
use spritz_core::telemetry::{default_telemetry_path, TelemetryMetric, TelemetryStore};
use spritz_core::touchbar::{
    HandledRequestRing, QuickEmojiEntry, TouchBarIncomingRequest, TouchBarLoginReceipt,
    TouchBarRequestPolicy, TouchBarRequestResult, TouchBarSignature,
};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

static ACTIVE_ENGINE_PTR: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy)]
pub struct HostCallbacks {
    pub ctx: *mut c_void,
    pub on_state_changed: Option<extern "C" fn(*mut c_void)>,
    pub on_copy_toast: Option<extern "C" fn(*mut c_void, *const c_char)>,
    pub on_touchbar_notify: Option<extern "C" fn(*mut c_void, *const c_char)>,
    pub on_insert_after_yield: Option<extern "C" fn(*mut c_void, *const c_char, bool)>,
    pub on_open_settings: Option<extern "C" fn(*mut c_void)>,
}

impl Default for HostCallbacks {
    fn default() -> Self {
        Self {
            ctx: std::ptr::null_mut(),
            on_state_changed: None,
            on_copy_toast: None,
            on_touchbar_notify: None,
            on_insert_after_yield: None,
            on_open_settings: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RectDto {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<CGRect> for RectDto {
    fn from(r: CGRect) -> Self {
        Self {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SlotDto {
    pub id: String,
    pub hex: Option<String>,
    pub glyph: Option<String>,
    pub label: Option<String>,
    pub shortcode: Option<String>,
    pub shortcut: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmojiCellDto {
    pub hex: String,
    pub glyph: String,
    pub label: String,
    pub shortcode: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SectionDto {
    pub category: String,
    pub title: String,
    pub tab_symbol: String,
    pub start_index: usize,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PickerViewDto {
    pub mode: PickerMode,
    pub available_modes: Vec<PickerMode>,
    pub search_input_active: bool,
    pub is_searching: bool,
    pub shows_categories: bool,
    pub query: String,
    pub active_category: String,
    pub shortcut_selected_index: usize,
    pub selected_index: usize,
    pub scroll_target_slot: Option<String>,
    pub scroll_target_grid: Option<usize>,
    pub scroll_slot_seq: u64,
    pub scroll_grid_seq: u64,
    pub slots: Vec<SlotDto>,
    pub grid_items: Vec<EmojiCellDto>,
    pub sections: Vec<SectionDto>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DictationDto {
    pub has_strip_content: bool,
    pub strip_height: f64,
    pub choices: Vec<String>,
    pub labels: Vec<String>,
    pub selected: usize,
    pub text_preview_active: bool,
    pub busy: bool,
    pub status: String,
    pub review_notes: String,
    pub copy_only: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotDto {
    pub visible: bool,
    pub anchor: Option<RectDto>,
    pub anchored_by_fallback: bool,
    pub anchor_update_seq: u64,
    pub capture_local_keys: bool,
    pub active: bool,
    pub paused_until: Option<f64>,
    pub accessibility: bool,
    pub input_monitoring: bool,
    pub all_permissions_granted: bool,
    pub secure_input: bool,
    pub secure_input_pid: i32,
    pub skin_tone: SkinTone,
    pub globe_enabled: bool,
    pub replace_system_picker: bool,
    pub launch_at_login: bool,
    pub show_menu_bar_icon: bool,
    pub use_frequency_boost: bool,
    pub needs_logout_for_globe: bool,
    pub refinement_provider: RefinementProvider,
    pub voice_mode: VoiceMode,
    pub chatgpt_running: bool,
    pub chatgpt_fn_hook_active: bool,
    pub total_emoji_inserted: u64,
    pub config_path: String,
    pub picker: Option<PickerViewDto>,
    pub dictation: DictationDto,
}

struct PendingBridgeOpen {
    request_id: String,
    expected_pid: i32,
    expected_element: CFRef,
    started_uptime: f64,
    _timeout_timer: Option<MainTimer>,
}

pub struct SpritzEngine {
    db: &'static EmojiDatabase,
    config_path: PathBuf,
    state_path: PathBuf,
    telemetry_path: PathBuf,
    pub config: SpritzConfig,
    pub state: SpritzState,
    pub telemetry: TelemetryStore,
    telemetry_dirty: u32,

    callbacks: HostCallbacks,
    alive: Arc<AtomicBool>,
    instance_id: String,

    accessibility: bool,
    input_monitoring: bool,
    ui_suspended: bool,
    active: bool,
    needs_logout_for_globe: bool,
    login_status: i32,

    focus_cache: FocusedElementCache,
    recent_typing: RecentTypingState,
    event_tap: Option<EventTap<SpritzEngine>>,
    carbon_hotkey: Option<CarbonToggleHotkey>,
    chatgpt_watch: ChatGptWatcher,

    picker: Option<PickerModel>,
    picker_visible: bool,
    picker_anchor: Option<CGRect>,
    anchored_by_fallback: bool,
    anchor_update_seq: u64,
    capture_local_keys: bool,
    capture_pid: Option<i32>,
    capture_element: Option<CFRef>,
    capture_have_info: bool,
    capture_editable: bool,
    capture_secure: bool,
    live_open_seq: u64,

    dictation: DictationState,
    dictation_element: Option<CFRef>,
    dictation_expiry_timer: Option<MainTimer>,
    receipt_capture_timer: Option<MainTimer>,
    native_capture: NativeDictationCapture,
    agy_runner: AgyRefinementRunner,
    scroll_slot_seq: u64,
    scroll_grid_seq: u64,

    touchbar_writer: TouchBarWriter,
    handled_requests: HandledRequestRing,
    last_request_result: Option<TouchBarRequestResult>,
    login_receipt: Option<TouchBarLoginReceipt>,
    pending_bridge_open: Option<PendingBridgeOpen>,

    pause_resume_timer: Option<MainTimer>,
}

impl SpritzEngine {
    pub fn new(callbacks: HostCallbacks, instance_id: String, initial_login_status: i32) -> Box<Self> {
        ensure_main_dispatcher_installed();
        ax::set_global_ax_timeout(0.5);

        let config_path = SpritzConfig::default_path();
        let state_path = SpritzState::default_path();
        let telemetry_path = default_telemetry_path();

        let config = SpritzConfig::load_or_default(&config_path);
        let mut state = SpritzState::load_or_default(&state_path);
        if state.first_launch_date.is_none() {
            state.first_launch_date = Some(epoch_secs());
            let _ = state.save_atomic(&state_path);
        }
        let telemetry = TelemetryStore::load_or_default(&telemetry_path);

        if config.replace_system_picker {
            set_cgs_character_palette_enabled(false);
        }

        let accessibility = is_accessibility_trusted();
        let input_monitoring = has_input_monitoring_permission();

        let mut engine = Box::new(Self {
            db: EmojiDatabase::global(),
            config_path,
            state_path,
            telemetry_path,
            config,
            state,
            telemetry,
            telemetry_dirty: 0,
            callbacks,
            alive: Arc::new(AtomicBool::new(true)),
            instance_id,
            accessibility,
            input_monitoring,
            ui_suspended: false,
            active: false,
            needs_logout_for_globe: false,
            login_status: initial_login_status,
            focus_cache: FocusedElementCache::default(),
            recent_typing: RecentTypingState::default(),
            event_tap: None,
            carbon_hotkey: None,
            chatgpt_watch: ChatGptWatcher::start(),
            picker: None,
            picker_visible: false,
            picker_anchor: None,
            anchored_by_fallback: false,
            anchor_update_seq: 0,
            capture_local_keys: false,
            capture_pid: None,
            capture_element: None,
            capture_have_info: false,
            capture_editable: false,
            capture_secure: false,
            live_open_seq: 0,
            dictation: DictationState::default(),
            dictation_element: None,
            dictation_expiry_timer: None,
            receipt_capture_timer: None,
            native_capture: NativeDictationCapture::default(),
            agy_runner: AgyRefinementRunner::default(),
            scroll_slot_seq: 0,
            scroll_grid_seq: 0,
            touchbar_writer: TouchBarWriter::default(),
            handled_requests: HandledRequestRing::default(),
            last_request_result: None,
            login_receipt: None,
            pending_bridge_open: None,
            pause_resume_timer: None,
        });

        let raw_ptr: *mut SpritzEngine = &mut *engine;
        ACTIVE_ENGINE_PTR.store(raw_ptr as usize, Ordering::SeqCst);

        engine.sync_carbon_hotkey();
        engine.schedule_pause_timer();
        engine.reconcile();
        engine.publish_touchbar(true);
        engine
    }

    pub fn shutdown(&mut self) {
        self.alive.store(false, Ordering::SeqCst);
        ACTIVE_ENGINE_PTR.store(0, Ordering::SeqCst);
        self.event_tap = None;
        self.carbon_hotkey = None;
        self.native_capture.cancel();
        self.agy_runner.cancel();
        let _ = self.telemetry.save_atomic(&self.telemetry_path);
        let _ = self.state.save_atomic(&self.state_path);
    }

    fn notify_ui(&self) {
        if let Some(cb) = self.callbacks.on_state_changed {
            cb(self.callbacks.ctx);
        }
    }

    fn record_metric(&mut self, metric: TelemetryMetric, duration_ms: Option<f64>) {
        let day = TelemetryStore::utc_day_now();
        self.telemetry.record_at_day(day, metric, duration_ms);
        self.telemetry_dirty += 1;
        if self.telemetry_dirty >= 10 {
            self.flush_telemetry();
        }
    }

    pub fn flush_telemetry(&mut self) {
        self.telemetry_dirty = 0;
        let _ = self.telemetry.save_atomic(&self.telemetry_path);
    }

    pub fn telemetry_report(&self) -> String {
        self.telemetry.format_report()
    }

    pub fn reconcile(&mut self) {
        self.accessibility = is_accessibility_trusted();
        self.input_monitoring = has_input_monitoring_permission();

        let now = epoch_secs();
        let paused = self.state.paused_until.map_or(false, |u| u > now);
        if self.state.paused_until.is_some() && !paused {
            self.state.paused_until = None;
            let _ = self.state.save_atomic(&self.state_path);
        }

        let should_run =
            self.accessibility && self.input_monitoring && !paused && !self.ui_suspended;
        if should_run {
            if self.event_tap.is_none() {
                let raw: *mut SpritzEngine = self;
                self.event_tap = EventTap::start(raw);
            }
            self.active = self.event_tap.is_some();
        } else {
            self.event_tap = None;
            self.active = false;
        }
        self.publish_touchbar(false);
        self.notify_ui();
    }

    pub fn poll_permissions(&mut self) {
        let ax = is_accessibility_trusted();
        let im = has_input_monitoring_permission();
        if ax != self.accessibility || im != self.input_monitoring {
            self.reconcile();
        }
    }

    pub fn set_ui_suspended(&mut self, suspended: bool) {
        if self.ui_suspended != suspended {
            self.ui_suspended = suspended;
            self.reconcile();
        }
    }

    pub fn set_login_status(&mut self, status: i32) {
        if self.login_status != status {
            self.login_status = status;
            self.publish_touchbar(false);
        }
    }

    pub fn set_chatgpt_running(&mut self, running: bool) {
        if self.chatgpt_watch.is_running() != running {
            self.chatgpt_watch.set_chatgpt_running(running);
            self.notify_ui();
        }
    }

    pub fn pause_for_secs(&mut self, secs: f64) {
        self.state.paused_until = Some(epoch_secs() + secs.max(1.0));
        let _ = self.state.save_atomic(&self.state_path);
        self.collapse_browser();
        self.schedule_pause_timer();
        self.reconcile();
    }

    pub fn resume(&mut self) {
        self.state.paused_until = None;
        self.pause_resume_timer = None;
        let _ = self.state.save_atomic(&self.state_path);
        self.reconcile();
    }

    fn schedule_pause_timer(&mut self) {
        self.pause_resume_timer = None;
        let Some(until) = self.state.paused_until else {
            return;
        };
        let remaining = until - epoch_secs();
        if remaining <= 0.0 {
            self.state.paused_until = None;
            return;
        }
        let alive = Arc::clone(&self.alive);
        self.pause_resume_timer = MainTimer::after_secs(remaining + 0.1, move || {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
            if ptr != 0 {
                unsafe { (&mut *(ptr as *mut SpritzEngine)).reconcile() };
            }
        });
    }

    // MARK: - Settings mutations

    pub fn set_skin_tone(&mut self, raw: &str) {
        let tone = SkinTone::from_str_lossy(raw);
        if self.config.skin_tone != tone {
            self.config.skin_tone = tone;
            let _ = self.config.save_atomic(&self.config_path);
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    pub fn set_globe_enabled(&mut self, enabled: bool) {
        self.config.globe_enabled = enabled;
        if enabled {
            self.needs_logout_for_globe = take_over_globe_key(&mut self.config.prior_fn_usage_type);
        } else {
            restore_globe_key(&mut self.config.prior_fn_usage_type);
            self.needs_logout_for_globe = false;
        }
        let _ = self.config.save_atomic(&self.config_path);
        self.notify_ui();
    }

    pub fn set_replace_system_picker(&mut self, enabled: bool) {
        self.config.replace_system_picker = enabled;
        if enabled {
            if self.state.prior_character_palette_enabled.is_none() {
                self.state.prior_character_palette_enabled =
                    Some(crate::system_picker::cgs_character_palette_enabled());
            }
            set_cgs_character_palette_enabled(false);
        } else {
            let restore = self.state.prior_character_palette_enabled.take().unwrap_or(true);
            set_cgs_character_palette_enabled(restore);
        }
        let _ = self.config.save_atomic(&self.config_path);
        let _ = self.state.save_atomic(&self.state_path);
        self.sync_carbon_hotkey();
        self.notify_ui();
    }

    pub fn set_launch_at_login(&mut self, enabled: bool) {
        self.config.launch_at_login = enabled;
        let _ = self.config.save_atomic(&self.config_path);
        self.notify_ui();
    }

    pub fn set_refinement_provider(&mut self, raw: &str) {
        self.config.refinement_provider = RefinementProvider::from_raw(raw);
        if self.config.refinement_provider == RefinementProvider::Off {
            self.agy_runner.cancel();
            self.dictation.busy = false;
        }
        let _ = self.config.save_atomic(&self.config_path);
        self.notify_ui();
    }

    fn sync_carbon_hotkey(&mut self) {
        if self.config.replace_system_picker {
            if self.carbon_hotkey.is_none() {
                extern "C" fn on_hotkey(_ctx: *mut c_void) {
                    let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                    if ptr != 0 {
                        unsafe { (&mut *(ptr as *mut SpritzEngine)).toggle_browser() };
                    }
                }
                self.carbon_hotkey =
                    CarbonToggleHotkey::register_ctrl_cmd_space(on_hotkey, std::ptr::null_mut());
            }
        } else {
            self.carbon_hotkey = None;
        }
    }

    // MARK: - App / Workspace / AX focus lifecycle

    pub fn on_app_activated(&mut self, pid: i32, bundle_id: String) {
        self.collapse_browser();
        self.native_capture.cancel();
        self.clear_dictation();
        self.recent_typing.clear();

        extern "C" fn noop_note() {}
        let _ = noop_note;

        self.focus_cache
            .observe_app(pid, bundle_id, ax_observer_event);
        self.spawn_cache_seed(pid, false);
        self.publish_touchbar(false);
    }

    pub fn on_space_changed(&mut self) {
        if self.picker_visible {
            self.collapse_browser();
        }
    }

    pub fn on_sleep_or_resign(&mut self) {
        self.native_capture.cancel();
        self.clear_dictation();
        self.collapse_browser();
    }

    fn spawn_cache_seed(&mut self, pid: i32, is_live_typing: bool) {
        let seq = self.focus_cache.next_refresh_seq();
        let alive = Arc::clone(&self.alive);
        let timeout = if is_live_typing { 0.15 } else { 0.5 };
        spawn_ax_snapshot(pid, seq, timeout, move |_s, snap| {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
            if ptr != 0 {
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                if is_live_typing {
                    eng.focus_cache.apply_live_refresh(snap);
                } else {
                    eng.focus_cache.apply_snapshot(snap, true);
                }
                eng.publish_touchbar(false);
            }
        });
    }

    fn handle_ax_event(&mut self, pid: i32, element: Option<CFRef>, is_window: bool) {
        if self.focus_cache.focused_pid != Some(pid) {
            return;
        }
        if is_window {
            if let Some(win_el) = element {
                if let Some(r) = ax::read_ax_rect(&win_el) {
                    self.focus_cache.active_window_frame = Some(r);
                    self.publish_touchbar(false);
                }
            }
            return;
        }
        let Some(el) = element else {
            self.spawn_cache_seed(pid, false);
            return;
        };
        let same_el = self.focus_cache.element.as_ref() == Some(&el);
        if !same_el && !self.capture_local_keys {
            if self.picker_visible {
                self.collapse_browser();
            }
            self.native_capture.cancel();
            self.clear_dictation();
        }
        let seq = self.focus_cache.next_refresh_seq();
        let alive = Arc::clone(&self.alive);
        spawn_ax_snapshot(pid, seq, 0.25, move |_s, snap| {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
            if ptr != 0 {
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                eng.focus_cache.apply_snapshot(snap, true);
                eng.publish_touchbar(false);
            }
        });
    }

    // MARK: - Picker open / close / pick / drag

    pub fn toggle_browser(&mut self) {
        if self.picker_visible {
            self.collapse_browser();
        } else {
            self.show_browser();
        }
    }

    pub fn show_browser(&mut self) {
        if !self.active {
            return;
        }
        self.record_metric(TelemetryMetric::PickerOpen, None);

        let pid = self.focus_cache.focused_pid;
        let el = self.focus_cache.element.clone();
        self.capture_pid = pid;
        self.capture_element = el.clone();
        self.capture_have_info = self.focus_cache.have_field_info;
        self.capture_editable = self.focus_cache.is_editable;
        self.capture_secure = self.focus_cache.is_secure;

        let context_text = if !self.capture_secure {
            el.as_ref().and_then(read_preceding_context)
        } else {
            None
        };

        let model = PickerModel::open(
            self.db,
            &self.state.usage_counts,
            &self.state.recent_emoji,
            &self.state.numbered_emoji,
            &self.state.letter_bindings,
            &self.state.released_hexes,
            &self.state.released_letters,
            context_text.as_deref(),
            self.config.use_frequency_boost,
        );

        self.persist_initial_numbered(&model);

        let CaretResolution { rect, by_fallback } = resolve_caret_for_cache(&self.focus_cache);
        let capture_local = is_secure_event_input_enabled();
        if capture_local {
            self.record_metric(TelemetryMetric::SecureInputFallback, None);
        }

        self.picker = Some(model);
        self.picker_visible = true;
        self.picker_anchor = rect;
        self.anchored_by_fallback = by_fallback;
        self.anchor_update_seq = self.anchor_update_seq.wrapping_add(1);
        self.capture_local_keys = capture_local;
        self.dictation.embedded = true;
        if let Some(exp) = self.dictation.expires_at_secs {
            if epoch_secs() > exp {
                self.dictation.clear(true);
            }
        }

        // Handle pending TouchBar show-picker validation before revealing.
        if let Some(mut pending) = self.pending_bridge_open.take() {
            let valid = self.focus_cache.focused_pid == Some(pending.expected_pid)
                && self.focus_cache.element.as_ref() == Some(&pending.expected_element)
                && self.focus_cache.have_field_info
                && self.focus_cache.is_editable
                && !self.focus_cache.is_secure;
            if !valid {
                pending._timeout_timer = None;
                self.collapse_browser();
                self.finish_bridge_request(pending.request_id, "focus-changed", None);
                return;
            }
            let latency_ms = (monotonic_uptime_secs() - pending.started_uptime) * 1000.0;
            pending._timeout_timer = None;
            self.finish_bridge_request(pending.request_id, "visible", Some(latency_ms));
        }

        // If AX role was missing or non-classic (e.g. Chrome AXHeading), refresh live off-thread.
        if let Some(fpid) = pid {
            if !self.focus_cache.have_field_info
                || !is_classic_text_role(self.focus_cache.role.as_deref())
                || by_fallback
            {
                self.live_open_seq = self.live_open_seq.wrapping_add(1);
                let my_seq = self.live_open_seq;
                let alive = Arc::clone(&self.alive);
                spawn_ax_snapshot(fpid, my_seq, 0.15, move |s, snap| {
                    if !alive.load(Ordering::SeqCst) {
                        return;
                    }
                    let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                    if ptr != 0 {
                        unsafe {
                            (&mut *(ptr as *mut SpritzEngine)).on_live_open_refresh(s, snap);
                        }
                    }
                });
            }
        }

        self.publish_touchbar(false);
        self.notify_ui();
    }

    fn on_live_open_refresh(&mut self, seq: u64, snap: FocusSnapshot) {
        if seq != self.live_open_seq || !self.picker_visible {
            return;
        }
        if self.capture_pid != Some(snap.pid) {
            return;
        }
        self.focus_cache.apply_live_refresh(snap.clone());
        self.capture_element = snap.element;
        self.capture_have_info = snap.have_field_info;
        self.capture_editable = snap.is_editable;
        self.capture_secure = snap.is_secure;

        if self.anchored_by_fallback {
            let CaretResolution { rect, by_fallback } = resolve_caret_for_cache(&self.focus_cache);
            if let Some(new_rect) = rect {
                self.picker_anchor = Some(new_rect);
                self.anchored_by_fallback = by_fallback;
                self.anchor_update_seq = self.anchor_update_seq.wrapping_add(1);
                self.notify_ui();
            }
        }
    }

    fn persist_initial_numbered(&mut self, model: &PickerModel) {
        if self.state.numbered_emoji.len() >= 10 {
            return;
        }
        let edits = model.export_edits(self.db);
        self.state.numbered_emoji = edits.numbered_emoji;
        self.state.letter_bindings = edits.letter_bindings;
        let _ = self.state.save_atomic(&self.state_path);
    }

    pub fn collapse_browser(&mut self) {
        if let Some(mut pending) = self.pending_bridge_open.take() {
            pending._timeout_timer = None;
            self.finish_bridge_request(pending.request_id, "focus-changed", None);
        }
        let was_visible = self.picker_visible;
        self.picker_visible = false;
        self.picker = None;
        self.picker_anchor = None;
        self.capture_local_keys = false;
        self.capture_pid = None;
        self.capture_element = None;
        self.capture_have_info = false;
        self.capture_editable = false;
        self.capture_secure = false;
        self.dictation.embedded = false;
        self.dictation.text_preview_active = false;
        if was_visible {
            self.record_metric(TelemetryMetric::PickerCancel, None);
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    pub fn begin_search(&mut self) {
        if let Some(p) = &mut self.picker {
            p.begin_search();
            self.notify_ui();
        }
    }

    pub fn set_query(&mut self, query: &str) {
        if let Some(p) = &mut self.picker {
            p.set_query(self.db, query.to_string());
            self.scroll_grid_seq = self.scroll_grid_seq.wrapping_add(1);
            self.notify_ui();
        }
    }

    pub fn select_mode(&mut self, mode: PickerMode) {
        if let Some(p) = &mut self.picker {
            p.select_mode(self.db, mode);
            self.scroll_slot_seq = self.scroll_slot_seq.wrapping_add(1);
            self.scroll_grid_seq = self.scroll_grid_seq.wrapping_add(1);
            self.notify_ui();
        }
    }

    pub fn select_category(&mut self, category_raw: &str) {
        let Some(cat) = EmojiCategory::from_raw(category_raw) else {
            return;
        };
        if let Some(p) = &mut self.picker {
            p.select_category(self.db, cat);
            self.scroll_slot_seq = self.scroll_slot_seq.wrapping_add(1);
            self.notify_ui();
        }
    }

    pub fn drag_drop_onto_emoji(&mut self, source_hex: &str, target_hex: &str) {
        let changed = self
            .picker
            .as_mut()
            .map_or(false, |p| p.drop_onto_emoji(self.db, source_hex, target_hex));
        if changed {
            self.persist_picker_edits();
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    pub fn drag_drop_onto_empty_number(&mut self, source_hex: &str, index: usize) {
        let changed = self
            .picker
            .as_mut()
            .map_or(false, |p| p.drop_onto_empty_number(self.db, source_hex, index));
        if changed {
            self.persist_picker_edits();
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    pub fn drag_drop_onto_empty_letter(&mut self, source_hex: &str, letter: char) {
        let changed = self
            .picker
            .as_mut()
            .map_or(false, |p| p.drop_onto_empty_letter(self.db, source_hex, letter));
        if changed {
            self.persist_picker_edits();
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    pub fn drag_drop_unassign(&mut self, source_hex: &str) {
        let changed = self
            .picker
            .as_mut()
            .map_or(false, |p| p.drop_on_unassigned(self.db, source_hex));
        if changed {
            self.persist_picker_edits();
            self.publish_touchbar(false);
            self.notify_ui();
        }
    }

    fn persist_picker_edits(&mut self) {
        if let Some(p) = &self.picker {
            let edits = p.export_edits(self.db);
            self.state.numbered_emoji = edits.numbered_emoji;
            self.state.letter_bindings = edits.letter_bindings;
            self.state.released_hexes = edits.released_hexes;
            self.state.released_letters = edits.released_letters;
            let _ = self.state.save_atomic(&self.state_path);
        }
    }

    pub fn pick_emoji_by_hex(&mut self, hex: &str, keep_open: bool) {
        let Some(idx) = self.db.index_of(hex) else {
            return;
        };
        if let Some(p) = &mut self.picker {
            p.select_emoji_index(self.db, idx);
        }
        self.perform_pick(idx, keep_open);
    }

    fn perform_pick(&mut self, emoji_idx: usize, keep_open: bool) {
        let emoji = &self.db.all[emoji_idx];
        let canon_hex = emoji.hexcode.clone();
        let glyph = emoji.toned_glyph(self.config.skin_tone).into_owned();

        let recent_match = self
            .recent_typing
            .is_recent(self.capture_pid, monotonic_uptime_secs());
        let copy = BrowserPickPolicy::should_copy_to_clipboard(
            self.capture_have_info,
            self.capture_editable,
            self.capture_secure,
            recent_match,
        );
        let used_local_capture = self.capture_local_keys;
        let capture_el = self.capture_element.clone();

        if !keep_open {
            // Suppress PickerCancel telemetry for an intentional pick.
            self.picker_visible = false;
            self.picker = None;
            self.picker_anchor = None;
            self.capture_local_keys = false;
            self.capture_pid = None;
            self.capture_element = None;
            self.dictation.embedded = false;
            self.dictation.text_preview_active = false;
            self.notify_ui();
        }

        self.state.record_pick(&canon_hex);
        let _ = self.state.save_atomic(&self.state_path);
        self.record_metric(TelemetryMetric::InsertionAttempt, None);

        if copy {
            self.record_metric(TelemetryMetric::ClipboardFallback, None);
            if let Some(cb) = self.callbacks.on_copy_toast {
                if let Ok(cs) = CString::new(glyph) {
                    cb(self.callbacks.ctx, cs.as_ptr());
                }
            }
        } else if used_local_capture {
            if let Some(cb) = self.callbacks.on_insert_after_yield {
                if let Ok(cs) = CString::new(glyph) {
                    cb(self.callbacks.ctx, cs.as_ptr(), keep_open);
                }
            }
        } else {
            inserter::replace_text(0, &glyph, capture_el.as_ref());
        }

        self.publish_touchbar(false);
    }

    pub fn post_synthetic_text(&self, delete_chars: usize, text: &str) {
        inserter::replace_text(delete_chars, text, self.focus_cache.element.as_ref());
    }

    // MARK: - Dictation capture, alternatives & review

    pub fn analyse_focused_text(&mut self) {
        let Some(pid) = self.focus_cache.focused_pid else {
            return;
        };
        let session = self.dictation.session_id;
        let alive = Arc::clone(&self.alive);
        std::thread::spawn(move || {
            let snap = ax::inspect_focused_element_for_pid(pid, 0.25);
            let Some(el) = snap.element.filter(|_| snap.is_editable && !snap.is_secure) else {
                return;
            };
            let Some((value, sel_loc, sel_len)) = ax::read_field_value_and_selection(&el, 0.25) else {
                return;
            };
            if value.trim().is_empty() || value.len() > 24_000 {
                return;
            }
            dispatch_main(move || {
                if !alive.load(Ordering::SeqCst) {
                    return;
                }
                let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                if ptr != 0 {
                    let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                    if eng.dictation.session_id != session {
                        return;
                    }
                    eng.begin_dictation_alternatives(value, Some(el), Some(pid), sel_loc, sel_len, true);
                }
            });
        });
    }

    pub fn select_dictation_choice(&mut self, index: usize) {
        if index < self.dictation.choices.len() {
            self.dictation.selected = index;
            self.dictation.text_preview_active = true;
            self.notify_ui();
        }
    }

    pub fn choose_dictation_alternative(&mut self, index: usize, keep_open: bool) {
        if index >= self.dictation.choices.len() || self.dictation.applying {
            return;
        }
        let chosen = self.dictation.choices[index].clone();
        if self.dictation.copy_only {
            self.copy_dictation_choice(&chosen);
            return;
        }
        let (Some(receipt), Some(el), Some(pid)) = (
            self.dictation.receipt.clone(),
            self.dictation_element.clone(),
            self.dictation.target_pid,
        ) else {
            self.dictation.copy_only = true;
            self.dictation.status = "Copy to use".to_string();
            self.notify_ui();
            return;
        };

        if self.focus_cache.focused_pid != Some(pid)
            || self.focus_cache.bridge_focus_generation != self.dictation.target_focus_generation
        {
            self.dictation.copy_only = true;
            self.dictation.status = "Focus changed · copy to use".to_string();
            self.notify_ui();
            return;
        }

        self.dictation.applying = true;
        let session_id = self.dictation.session_id;
        let rev = self.dictation.revision;
        let alive = Arc::clone(&self.alive);

        std::thread::spawn(move || {
            let live = ax::read_field_value_and_selection(&el, 0.25);
            dispatch_main(move || {
                if !alive.load(Ordering::SeqCst) {
                    return;
                }
                let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                if ptr == 0 {
                    return;
                }
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                if eng.dictation.session_id != session_id || eng.dictation.revision != rev {
                    return;
                }
                eng.dictation.applying = false;
                let Some((val, loc, len)) = live else {
                    eng.dictation.copy_only = true;
                    eng.dictation.status = "Text changed · copy to use".to_string();
                    eng.notify_ui();
                    return;
                };
                if !receipt.matches(&val, loc, len) {
                    eng.dictation.copy_only = true;
                    eng.dictation.status = "Text changed · copy to use".to_string();
                    eng.notify_ui();
                    return;
                }
                inserter::replace_text(receipt.delete_char_count, &chosen, Some(&el));
                eng.dictation.revision = eng.dictation.revision.wrapping_add(1);
                eng.dictation.receipt = None;
                eng.dictation.current_text = chosen.clone();
                eng.dictation.applied_index = index;
                eng.record_metric(TelemetryMetric::RefinementChosen, None);
                if !keep_open {
                    eng.collapse_browser();
                } else {
                    eng.notify_ui();
                }
                eng.capture_dictation_receipt(chosen);
            });
        });
    }

    fn copy_dictation_choice(&mut self, text: &str) {
        self.record_metric(TelemetryMetric::RefinementCopy, None);
        if let Some(cb) = self.callbacks.on_copy_toast {
            if let Ok(cs) = CString::new(text) {
                cb(self.callbacks.ctx, cs.as_ptr());
            }
        }
        self.notify_ui();
    }

    fn clear_dictation(&mut self) {
        if self.dictation.busy {
            self.record_metric(TelemetryMetric::RefinementCancel, None);
        }
        self.agy_runner.cancel();
        self.dictation_element = None;
        self.dictation_expiry_timer = None;
        self.receipt_capture_timer = None;
        let preserve_embedded = self.picker_visible;
        self.dictation.clear(preserve_embedded);
        self.notify_ui();
    }

    fn begin_dictation_alternatives(
        &mut self,
        text: String,
        element: Option<CFRef>,
        pid: Option<i32>,
        sel_loc: usize,
        sel_len: usize,
        capture_whole_field: bool,
    ) {
        self.agy_runner.cancel();
        self.dictation.begin_native(
            text.clone(),
            pid,
            self.focus_cache.bridge_focus_generation,
            element.is_some(),
            epoch_secs(),
        );
        self.dictation_element = element.clone();
        if capture_whole_field {
            if element.is_some() {
                let _ = (sel_loc, sel_len);
                self.capture_dictation_receipt(text.clone());
            }
        } else {
            self.capture_dictation_receipt(text.clone());
        }
        self.schedule_dictation_expiry();

        if self.config.refinement_provider == RefinementProvider::Antigravity
            && text.len() <= 24_000
        {
            self.dictation.busy = true;
            self.record_metric(TelemetryMetric::RefinementStart, None);
            let session_id = self.dictation.session_id;
            let alive = Arc::clone(&self.alive);
            self.agy_runner.run(session_id, text, move |sid, res, metric, elapsed_ms| {
                if !alive.load(Ordering::SeqCst) {
                    return;
                }
                let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                if ptr == 0 {
                    return;
                }
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                if eng.dictation.session_id != sid {
                    return;
                }
                if let Some(r) = res {
                    eng.dictation.apply_refinement_result(r);
                    eng.record_metric(metric, Some(elapsed_ms));
                } else {
                    eng.dictation.mark_refinement_unavailable();
                    eng.record_metric(metric, Some(elapsed_ms));
                }
                eng.notify_ui();
            });
        }
        self.notify_ui();
    }

    fn capture_dictation_receipt(&mut self, expected_text: String) {
        let Some(el) = self.dictation_element.clone() else {
            self.dictation.copy_only = true;
            return;
        };
        let session_id = self.dictation.session_id;
        let rev = self.dictation.revision;
        let alive = Arc::clone(&self.alive);

        self.receipt_capture_timer = MainTimer::after_secs(0.25, move || {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let alive2 = Arc::clone(&alive);
            std::thread::spawn(move || {
                let read = ax::read_field_value_and_selection(&el, 0.25);
                dispatch_main(move || {
                    if !alive2.load(Ordering::SeqCst) {
                        return;
                    }
                    let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                    if ptr == 0 {
                        return;
                    }
                    let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                    if eng.dictation.session_id != session_id || eng.dictation.revision != rev {
                        return;
                    }
                    eng.dictation.receipt = read.and_then(|(val, loc, len)| {
                        DictationReceipt::capture(&val, loc, len, &expected_text)
                    });
                    eng.dictation.copy_only = eng.dictation.receipt.is_none();
                    if eng.dictation.copy_only && eng.dictation.status.is_empty() {
                        eng.dictation.status = "Copy to use".to_string();
                    }
                    eng.notify_ui();
                });
            });
        });
    }

    fn schedule_dictation_expiry(&mut self) {
        let session_id = self.dictation.session_id;
        let alive = Arc::clone(&self.alive);
        self.dictation_expiry_timer = MainTimer::after_secs(120.0, move || {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
            if ptr != 0 {
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                if eng.dictation.session_id == session_id {
                    eng.clear_dictation();
                }
            }
        });
    }

    fn handle_native_capture_event(&mut self, ev: NativeCaptureEvent) {
        match ev {
            NativeCaptureEvent::BaselineFailed(_) => {
                self.record_metric(TelemetryMetric::NativeBaselineFailed, None);
            }
            NativeCaptureEvent::DiffMismatch(_) => {
                self.record_metric(TelemetryMetric::NativeDiffMismatch, None);
            }
            NativeCaptureEvent::Timeout(_) => {
                self.record_metric(TelemetryMetric::NativeCaptureTimeout, None);
            }
            NativeCaptureEvent::Captured {
                gen_id: _,
                text,
                baseline,
            } => {
                self.record_metric(TelemetryMetric::NativeTranscriptCaptured, None);
                self.begin_dictation_alternatives(
                    text,
                    Some(baseline.element),
                    Some(baseline.pid),
                    baseline.sel_loc,
                    baseline.sel_len,
                    false,
                );
            }
        }
    }

    // MARK: - Touch Bar Bridge

    pub fn publish_touchbar(&mut self, force: bool) {
        let quick = self.build_quick_emoji();
        let front_pid = self.focus_cache.focused_pid.unwrap_or(0);
        let matches = self.focus_cache.focused_pid.is_some();
        let known =
            self.accessibility && self.input_monitoring && matches && self.focus_cache.have_field_info;
        let text_role = TouchBarRequestPolicy::is_text_role(self.focus_cache.role.as_deref());
        let editable = known && text_role && self.focus_cache.is_editable;
        let secure = !known || self.focus_cache.is_secure;

        let sig = TouchBarSignature {
            schema: 1,
            pid: unsafe { libc::getpid() },
            instance_id: self.instance_id.clone(),
            front_pid,
            front_bundle: self.focus_cache.front_bundle.clone(),
            focus_generation: self.focus_cache.bridge_focus_generation,
            accessibility: self.accessibility,
            input_monitoring: self.input_monitoring,
            known,
            editable,
            secure,
            selection_known: false,
            has_selection: false,
            picker_visible: self.picker_visible,
            active: self.active,
            quick_emoji: quick,
            login_status: self.login_status,
            login: self.login_receipt.clone(),
            last_request: self.last_request_result.clone(),
        };
        if let Some(payload_json) = self.touchbar_writer.write_if_changed(&sig, force) {
            if let Some(cb) = self.callbacks.on_touchbar_notify {
                if let Ok(cs) = CString::new(payload_json) {
                    cb(self.callbacks.ctx, cs.as_ptr());
                }
            }
        }
    }

    fn build_quick_emoji(&self) -> Vec<QuickEmojiEntry> {
        self.state
            .numbered_emoji
            .iter()
            .take(6)
            .filter_map(|h| {
                let emoji = self.db.get(h)?;
                Some(QuickEmojiEntry {
                    glyph: emoji.toned_glyph(self.config.skin_tone).into_owned(),
                    hex: emoji.hexcode.clone(),
                    label: emoji.label.clone(),
                })
            })
            .collect()
    }

    fn finish_bridge_request(&mut self, request_id: String, status: &str, latency_ms: Option<f64>) {
        self.last_request_result = Some(TouchBarRequestResult {
            request_id: request_id.clone(),
            status: status.to_string(),
            t: epoch_secs(),
            request_to_visible_ms: latency_ms,
        });
        self.handled_requests.record(request_id);
        self.publish_touchbar(true);
    }

    pub fn handle_touchbar_request(&mut self, json_str: &str, login_result: Option<(i32, &str)>) {
        let Ok(req) = serde_json::from_str::<TouchBarIncomingRequest>(json_str) else {
            return;
        };
        if !matches!(
            req.command.as_str(),
            "show-picker" | "pick-emoji" | "enable-login"
        ) || req.request_id.is_empty()
        {
            return;
        }
        if !TouchBarRequestPolicy::valid_age(req.issued_at, epoch_secs()) {
            self.finish_bridge_request(req.request_id, "request-expired", None);
            return;
        }
        if self.handled_requests.contains(&req.request_id)
            || self
                .pending_bridge_open
                .as_ref()
                .map_or(false, |p| p.request_id == req.request_id)
        {
            return;
        }

        if req.command == "enable-login" {
            if let Some((status, err)) = login_result {
                self.login_status = status;
                let now_u64 = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                self.login_receipt = Some(TouchBarLoginReceipt {
                    status,
                    error: err.to_string(),
                    t: now_u64,
                    request_id: req.request_id.clone(),
                    process: "running GUI app".to_string(),
                });
                let code = match status {
                    1 => "login-enabled",
                    2 => "login-requires-approval",
                    _ => "login-not-enabled",
                };
                self.finish_bridge_request(req.request_id, code, None);
            }
            return;
        }

        if self.pending_bridge_open.is_some() {
            self.finish_bridge_request(req.request_id, "busy", None);
            return;
        }
        let Some(expected_pid) = req.expected_pid else {
            self.finish_bridge_request(req.request_id, "focus-changed", None);
            return;
        };
        if self.focus_cache.focused_pid != Some(expected_pid) {
            self.finish_bridge_request(req.request_id, "focus-changed", None);
            return;
        }
        if let Some(gen) = req.focus_generation {
            if gen != self.focus_cache.bridge_focus_generation {
                self.finish_bridge_request(req.request_id, "stale-focus", None);
                return;
            }
        }
        if let Some(inst) = req.instance_id.as_deref() {
            if inst != self.instance_id {
                self.finish_bridge_request(req.request_id, "stale-instance", None);
                return;
            }
        }
        if !self.accessibility || !self.input_monitoring {
            self.finish_bridge_request(req.request_id, "permissions-missing", None);
            return;
        }
        let text_role = TouchBarRequestPolicy::is_text_role(self.focus_cache.role.as_deref());
        let Some(cached) = self.focus_cache.element.clone() else {
            self.finish_bridge_request(req.request_id, "not-editable", None);
            return;
        };
        if !self.active
            || !self.focus_cache.have_field_info
            || !text_role
            || !self.focus_cache.is_editable
            || self.focus_cache.is_secure
        {
            self.finish_bridge_request(req.request_id, "not-editable", None);
            return;
        }
        if !verify_focused_element_fast(expected_pid, &cached) {
            self.finish_bridge_request(req.request_id, "focus-unverified", None);
            return;
        }

        if req.command == "pick-emoji" {
            let quick = self.build_quick_emoji();
            let Some(hex) = req.hex.as_deref() else {
                self.finish_bridge_request(req.request_id, "unknown-emoji", None);
                return;
            };
            if !quick.iter().any(|q| q.hex == hex) {
                self.finish_bridge_request(req.request_id, "unknown-emoji", None);
                return;
            }
            self.capture_pid = Some(expected_pid);
            self.capture_element = Some(cached);
            self.capture_have_info = true;
            self.capture_editable = true;
            self.capture_secure = false;
            self.pick_emoji_by_hex(hex, false);
            self.finish_bridge_request(req.request_id, "insertion-requested", None);
            return;
        }

        if self.picker_visible {
            self.finish_bridge_request(req.request_id, "already-visible", None);
            return;
        }

        let req_id_for_timer = req.request_id.clone();
        let alive = Arc::clone(&self.alive);
        let timer = MainTimer::after_secs(2.0, move || {
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
            if ptr != 0 {
                let eng = unsafe { &mut *(ptr as *mut SpritzEngine) };
                if eng
                    .pending_bridge_open
                    .as_ref()
                    .map_or(false, |p| p.request_id == req_id_for_timer)
                {
                    eng.collapse_browser();
                    eng.finish_bridge_request(req_id_for_timer, "request-expired", None);
                }
            }
        });
        self.pending_bridge_open = Some(PendingBridgeOpen {
            request_id: req.request_id,
            expected_pid,
            expected_element: cached,
            started_uptime: monotonic_uptime_secs(),
            _timeout_timer: timer,
        });
        self.show_browser();
    }

    // MARK: - Key routing & snapshot generation

    pub fn handle_key_input(&mut self, input: KeyInput) -> bool {
        if self.dictation.embedded {
            if let KeyInput::Tab { shift } = input {
                if self.dictation.handle_embedded_tab(shift) {
                    self.record_metric(TelemetryMetric::RefinementCycle, None);
                    self.notify_ui();
                    return true;
                }
            }
            if let KeyInput::Return { .. } = input {
                if self.dictation.text_preview_active && !self.dictation.choices.is_empty() {
                    self.choose_dictation_alternative(self.dictation.selected, true);
                    return true;
                }
            }
            if self.dictation.text_preview_active {
                self.dictation.text_preview_active = false;
                self.notify_ui();
            }
        }

        if !self.picker_visible {
            match input {
                KeyInput::Char(_) | KeyInput::Backspace => {
                    self.native_capture.cancel();
                    if let Some(pid) = self.focus_cache.focused_pid {
                        self.recent_typing.record(pid, monotonic_uptime_secs());
                    }
                    if let Some(pid) = self.focus_cache.should_refresh_on_typing() {
                        self.spawn_cache_seed(pid, true);
                    }
                }
                _ => {}
            }
            return false;
        }

        match input {
            KeyInput::Escape => {
                self.collapse_browser();
                true
            }
            KeyInput::ArrowUp => {
                if let Some(p) = &mut self.picker {
                    p.move_selection(Direction::Up);
                    self.bump_scroll_seq_from_picker();
                    self.notify_ui();
                }
                true
            }
            KeyInput::ArrowDown => {
                if let Some(p) = &mut self.picker {
                    p.move_selection(Direction::Down);
                    self.bump_scroll_seq_from_picker();
                    self.notify_ui();
                }
                true
            }
            KeyInput::ArrowLeft => {
                if let Some(p) = &mut self.picker {
                    p.move_selection(Direction::Left);
                    self.bump_scroll_seq_from_picker();
                    self.notify_ui();
                }
                true
            }
            KeyInput::ArrowRight => {
                if let Some(p) = &mut self.picker {
                    p.move_selection(Direction::Right);
                    self.bump_scroll_seq_from_picker();
                    self.notify_ui();
                }
                true
            }
            KeyInput::Return { shift } | KeyInput::Tab { shift } => {
                let picked = self.picker.as_ref().and_then(|p| p.selected_emoji_index());
                if let Some(idx) = picked {
                    self.perform_pick(idx, shift);
                } else if !shift {
                    self.collapse_browser();
                }
                true
            }
            KeyInput::Backspace => {
                if let Some(p) = &mut self.picker {
                    if p.search_input_active && !p.query.is_empty() {
                        let mut next = p.query.clone();
                        next.pop();
                        p.set_query(self.db, next);
                        self.notify_ui();
                    }
                }
                true
            }
            KeyInput::Char(ch) => {
                let search_active = self.picker.as_ref().map_or(false, |p| p.search_input_active);
                if !search_active {
                    let picked = self.picker.as_ref().and_then(|p| p.emoji_for_shortcut(ch));
                    if let Some(idx) = picked {
                        self.perform_pick(idx, false);
                    }
                    return true;
                }
                if !ch.is_control() {
                    if let Some(p) = &mut self.picker {
                        let mut next = p.query.clone();
                        next.push(ch);
                        p.set_query(self.db, next);
                        self.notify_ui();
                    }
                }
                true
            }
        }
    }

    fn bump_scroll_seq_from_picker(&mut self) {
        if let Some(p) = &self.picker {
            if !p.search_input_active {
                self.scroll_slot_seq = self.scroll_slot_seq.wrapping_add(1);
            } else {
                self.scroll_grid_seq = self.scroll_grid_seq.wrapping_add(1);
            }
        }
    }

    pub fn build_snapshot(&self) -> SnapshotDto {
        let picker = self.picker.as_ref().map(|p| {
            let tone = self.config.skin_tone;
            let slots = if !p.search_input_active {
                p.picker_slots
                    .iter()
                    .map(|s| {
                        let em = s.emoji_idx.map(|i| &self.db.all[i]);
                        SlotDto {
                            id: s.id.clone(),
                            hex: em.map(|e| e.hexcode.clone()),
                            glyph: em.map(|e| e.toned_glyph(tone).into_owned()),
                            label: em.map(|e| e.label.clone()),
                            shortcode: em.map(|e| e.primary_shortcode().to_string()),
                            shortcut: s.shortcut.map(|c| c.to_string()),
                        }
                    })
                    .collect()
            } else {
                Vec::new()
            };

            let grid_items = if p.search_input_active {
                p.current
                    .iter()
                    .map(|&idx| {
                        let e = &self.db.all[idx];
                        EmojiCellDto {
                            hex: e.hexcode.clone(),
                            glyph: e.toned_glyph(tone).into_owned(),
                            label: e.label.clone(),
                            shortcode: e.primary_shortcode().to_string(),
                        }
                    })
                    .collect()
            } else {
                Vec::new()
            };

            let sections = p
                .sections
                .iter()
                .map(|s| SectionDto {
                    category: s.category.as_str().to_string(),
                    title: s.category.title().to_string(),
                    tab_symbol: s.category.tab_symbol().to_string(),
                    start_index: s.start_index,
                    count: s.count,
                })
                .collect();

            PickerViewDto {
                mode: p.mode,
                available_modes: p.available_modes(),
                search_input_active: p.search_input_active,
                is_searching: p.is_searching(),
                shows_categories: p.shows_categories(),
                query: p.query.clone(),
                active_category: p.active_category.as_str().to_string(),
                shortcut_selected_index: p.shortcut_selected_index,
                selected_index: p.selected_index,
                scroll_target_slot: p.scroll_target_slot.clone(),
                scroll_target_grid: p.scroll_target_grid,
                scroll_slot_seq: self.scroll_slot_seq,
                scroll_grid_seq: self.scroll_grid_seq,
                slots,
                grid_items,
                sections,
            }
        });

        let sec_pid = secure_input_holder_pid().unwrap_or(0);
        let sec_enabled = is_secure_event_input_enabled();

        SnapshotDto {
            visible: self.picker_visible,
            anchor: self.picker_anchor.map(RectDto::from),
            anchored_by_fallback: self.anchored_by_fallback,
            anchor_update_seq: self.anchor_update_seq,
            capture_local_keys: self.capture_local_keys,
            active: self.active,
            paused_until: self.state.paused_until,
            accessibility: self.accessibility,
            input_monitoring: self.input_monitoring,
            all_permissions_granted: self.accessibility && self.input_monitoring,
            secure_input: sec_enabled,
            secure_input_pid: sec_pid,
            skin_tone: self.config.skin_tone,
            globe_enabled: self.config.globe_enabled,
            replace_system_picker: self.config.replace_system_picker,
            launch_at_login: self.config.launch_at_login,
            show_menu_bar_icon: self.config.show_menu_bar_icon,
            use_frequency_boost: self.config.use_frequency_boost,
            needs_logout_for_globe: self.needs_logout_for_globe,
            refinement_provider: self.config.refinement_provider,
            voice_mode: self.config.voice_mode,
            chatgpt_running: self.chatgpt_watch.is_running(),
            chatgpt_fn_hook_active: self.chatgpt_watch.is_fn_hook_active(),
            total_emoji_inserted: self.state.total_emoji_inserted,
            config_path: self.config_path.to_string_lossy().into_owned(),
            picker,
            dictation: DictationDto {
                has_strip_content: self.dictation.has_strip_content(),
                strip_height: self.dictation.strip_height(),
                choices: self.dictation.choices.clone(),
                labels: self.dictation.labels.clone(),
                selected: self.dictation.selected,
                text_preview_active: self.dictation.text_preview_active,
                busy: self.dictation.busy,
                status: self.dictation.status.clone(),
                review_notes: self.dictation.review_notes.clone(),
                copy_only: self.dictation.copy_only,
            },
        }
    }

    pub fn build_headless_preview_snapshot(&self, with_alternatives: bool) -> SnapshotDto {
        let db = self.db;
        let model = PickerModel::open(
            db,
            &self.state.usage_counts,
            &self.state.recent_emoji,
            &self.state.numbered_emoji,
            &self.state.letter_bindings,
            &self.state.released_hexes,
            &self.state.released_letters,
            None,
            true,
        );
        let tone = self.config.skin_tone;
        let slots = model
            .picker_slots
            .iter()
            .map(|s| {
                let em = s.emoji_idx.map(|i| &db.all[i]);
                SlotDto {
                    id: s.id.clone(),
                    hex: em.map(|e| e.hexcode.clone()),
                    glyph: em.map(|e| e.toned_glyph(tone).into_owned()),
                    label: em.map(|e| e.label.clone()),
                    shortcode: em.map(|e| e.primary_shortcode().to_string()),
                    shortcut: s.shortcut.map(|c| c.to_string()),
                }
            })
            .collect();
        let sections = model
            .sections
            .iter()
            .map(|s| SectionDto {
                category: s.category.as_str().to_string(),
                title: s.category.title().to_string(),
                tab_symbol: s.category.tab_symbol().to_string(),
                start_index: s.start_index,
                count: s.count,
            })
            .collect();

        let dictation = if with_alternatives {
            DictationDto {
                has_strip_content: true,
                strip_height: spritz_core::dictation::EXPANDED_STRIP_HEIGHT,
                choices: vec![
                    "Patient reports mild shortness of breath after climbing stairs, no chest pain.".to_string(),
                    "Patient reports mild dyspnoea on exertion, with no chest pain.".to_string(),
                ],
                labels: vec!["GPT".to_string(), "Reviewed".to_string()],
                selected: 1,
                text_preview_active: true,
                busy: false,
                status: String::new(),
                review_notes: "Australian English spelling applied (dyspnoea).".to_string(),
                copy_only: false,
            }
        } else {
            DictationDto {
                has_strip_content: false,
                strip_height: spritz_core::dictation::COMPACT_STRIP_HEIGHT,
                choices: Vec::new(),
                labels: Vec::new(),
                selected: 0,
                text_preview_active: false,
                busy: false,
                status: String::new(),
                review_notes: String::new(),
                copy_only: false,
            }
        };

        SnapshotDto {
            visible: true,
            anchor: None,
            anchored_by_fallback: false,
            anchor_update_seq: 1,
            capture_local_keys: false,
            active: true,
            paused_until: None,
            accessibility: true,
            input_monitoring: true,
            all_permissions_granted: true,
            secure_input: false,
            secure_input_pid: 0,
            skin_tone: tone,
            globe_enabled: self.config.globe_enabled,
            replace_system_picker: self.config.replace_system_picker,
            launch_at_login: self.config.launch_at_login,
            show_menu_bar_icon: true,
            use_frequency_boost: true,
            needs_logout_for_globe: false,
            refinement_provider: self.config.refinement_provider,
            voice_mode: self.config.voice_mode,
            chatgpt_running: true,
            chatgpt_fn_hook_active: true,
            total_emoji_inserted: self.state.total_emoji_inserted,
            config_path: self.config_path.to_string_lossy().into_owned(),
            picker: Some(PickerViewDto {
                mode: model.mode,
                available_modes: model.available_modes(),
                search_input_active: false,
                is_searching: false,
                shows_categories: false,
                query: String::new(),
                active_category: "smileysPeople".to_string(),
                shortcut_selected_index: 0,
                selected_index: 0,
                scroll_target_slot: None,
                scroll_target_grid: None,
                scroll_slot_seq: 0,
                scroll_grid_seq: 0,
                slots,
                grid_items: Vec::new(),
                sections,
            }),
            dictation,
        }
    }
}

fn ax_observer_event(pid: i32, element: Option<CFRef>, is_window: bool) {
    let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
    if ptr != 0 {
        unsafe { (&mut *(ptr as *mut SpritzEngine)).handle_ax_event(pid, element, is_window) };
    }
}

impl EventTapSink for SpritzEngine {
    fn on_fn_action(&mut self, action: FnAction) {
        if !self.config.globe_enabled || !self.active {
            return;
        }
        match action {
            FnAction::Tap => {
                self.record_metric(TelemetryMetric::FnTap, None);
                self.toggle_browser();
            }
            FnAction::Start => {
                self.record_metric(TelemetryMetric::FnHold, None);
                self.collapse_browser();
                self.dictation.prepare_native(false);
                if let Some(pid) = self.focus_cache.focused_pid {
                    let fg = self.focus_cache.bridge_focus_generation;
                    let alive = Arc::clone(&self.alive);
                    self.native_capture.start(pid, fg, move |ev| {
                        if !alive.load(Ordering::SeqCst) {
                            return;
                        }
                        let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                        if ptr != 0 {
                            unsafe {
                                (&mut *(ptr as *mut SpritzEngine)).handle_native_capture_event(ev);
                            }
                        }
                    });
                }
                self.notify_ui();
            }
            FnAction::Finish => {
                let alive = Arc::clone(&self.alive);
                self.native_capture.finish(move |ev| {
                    if !alive.load(Ordering::SeqCst) {
                        return;
                    }
                    let ptr = ACTIVE_ENGINE_PTR.load(Ordering::SeqCst);
                    if ptr != 0 {
                        unsafe {
                            (&mut *(ptr as *mut SpritzEngine)).handle_native_capture_event(ev);
                        }
                    }
                });
            }
            FnAction::Cancel => {
                self.record_metric(TelemetryMetric::FnCancelled, None);
                self.native_capture.cancel();
            }
        }
    }

    fn on_speech_cycle(&mut self, backward: bool) -> bool {
        if !self.active {
            return false;
        }
        if !self.picker_visible {
            self.show_browser();
        }
        let handled = self.dictation.handle_embedded_tab(backward);
        if handled {
            self.record_metric(TelemetryMetric::RefinementCycle, None);
            self.notify_ui();
        }
        handled
    }

    fn on_key_input(&mut self, input: KeyInput) -> bool {
        self.handle_key_input(input)
    }

    fn on_tap_lost(&mut self) {
        self.collapse_browser();
        self.native_capture.cancel();
        self.record_metric(TelemetryMetric::TapLost, None);
        self.poll_permissions();
    }
}

pub fn drag_resolve_from_json(
    point_x: f64,
    point_y: f64,
    source_hex: &str,
    frames_json: &str,
) -> Option<DragOutcome> {
    let parsed: HashMap<String, [f64; 4]> = serde_json::from_str(frames_json).ok()?;
    let frames = parsed
        .into_iter()
        .map(|(k, v)| (k, (v[0], v[1], v[2], v[3])))
        .collect();
    Some(spritz_core::slots::resolve_drag(
        point_x,
        point_y,
        source_hex,
        &frames,
    ))
}
