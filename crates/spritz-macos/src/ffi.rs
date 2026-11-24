use crate::engine::{drag_resolve_from_json, HostCallbacks, SpritzEngine};
use crate::event_tap::{is_speech_cycle_event, translate_cgevent, CGEventRef, EventTapSink};
use spritz_core::config::SpritzConfig;
use spritz_core::slots::{DragOutcome, PickerMode};
use spritz_core::telemetry::{default_telemetry_path, TelemetryStore};
use std::ffi::{c_char, c_void, CStr, CString};

#[repr(C)]
pub struct SpritzCallbacks {
    pub ctx: *mut c_void,
    pub on_state_changed: Option<extern "C" fn(*mut c_void)>,
    pub on_copy_toast: Option<extern "C" fn(*mut c_void, *const c_char)>,
    pub on_touchbar_notify: Option<extern "C" fn(*mut c_void, *const c_char)>,
    pub on_insert_after_yield: Option<extern "C" fn(*mut c_void, *const c_char, bool)>,
    pub on_open_settings: Option<extern "C" fn(*mut c_void)>,
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { Some(CStr::from_ptr(ptr).to_string_lossy().into_owned()) }
}

fn into_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .map(CString::into_raw)
        .unwrap_or_else(|_| CString::new("").unwrap().into_raw())
}

#[no_mangle]
pub extern "C" fn spritz_free_cstr(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn spritz_cli_telemetry_report() -> *mut c_char {
    let store = TelemetryStore::load_or_default(&default_telemetry_path());
    into_c_string(store.format_report())
}

#[no_mangle]
pub extern "C" fn spritz_engine_create(
    callbacks: SpritzCallbacks,
    instance_id: *const c_char,
    initial_login_status: i32,
) -> *mut SpritzEngine {
    let inst = cstr_to_string(instance_id).unwrap_or_default();
    let host_cb = HostCallbacks {
        ctx: callbacks.ctx,
        on_state_changed: callbacks.on_state_changed,
        on_copy_toast: callbacks.on_copy_toast,
        on_touchbar_notify: callbacks.on_touchbar_notify,
        on_insert_after_yield: callbacks.on_insert_after_yield,
        on_open_settings: callbacks.on_open_settings,
    };
    Box::into_raw(SpritzEngine::new(host_cb, inst, initial_login_status))
}

#[no_mangle]
pub extern "C" fn spritz_engine_destroy(engine: *mut SpritzEngine) {
    if engine.is_null() {
        return;
    }
    unsafe {
        let mut boxed = Box::from_raw(engine);
        boxed.shutdown();
    }
}

#[no_mangle]
pub extern "C" fn spritz_snapshot_json(engine: *const SpritzEngine) -> *mut c_char {
    if engine.is_null() {
        return into_c_string("{}".to_string());
    }
    let eng = unsafe { &*engine };
    let json = serde_json::to_string(&eng.build_snapshot()).unwrap_or_else(|_| "{}".to_string());
    into_c_string(json)
}

#[no_mangle]
pub extern "C" fn spritz_preview_snapshot_json(
    with_alternatives: bool,
) -> *mut c_char {
    // Pure render helper for --render-preview without spawning an event tap.
    let mut cfg = SpritzConfig::load_or_default(&SpritzConfig::default_path());
    if cfg.skin_tone == spritz_core::emoji::SkinTone::Default {
        cfg.skin_tone = spritz_core::emoji::SkinTone::Light;
    }
    let st = spritz_core::config::SpritzState::load_or_default(
        &spritz_core::config::SpritzState::default_path(),
    );
    let db = spritz_core::db::EmojiDatabase::global();
    let model = spritz_core::slots::PickerModel::open(
        db,
        &st.usage_counts,
        &st.recent_emoji,
        &st.numbered_emoji,
        &st.letter_bindings,
        &st.released_hexes,
        &st.released_letters,
        None,
        true,
    );
    let tone = cfg.skin_tone;
    let slots: Vec<crate::engine::SlotDto> = model
        .picker_slots
        .iter()
        .map(|s| {
            let em = s.emoji_idx.map(|i| &db.all[i]);
            crate::engine::SlotDto {
                id: s.id.clone(),
                hex: em.map(|e| e.hexcode.clone()),
                glyph: em.map(|e| e.toned_glyph(tone).into_owned()),
                label: em.map(|e| e.label.clone()),
                shortcode: em.map(|e| e.primary_shortcode().to_string()),
                shortcut: s.shortcut.map(|c| c.to_string()),
            }
        })
        .collect();
    let sections: Vec<crate::engine::SectionDto> = model
        .sections
        .iter()
        .map(|s| crate::engine::SectionDto {
            category: s.category.as_str().to_string(),
            title: s.category.title().to_string(),
            tab_symbol: s.category.tab_symbol().to_string(),
            start_index: s.start_index,
            count: s.count,
        })
        .collect();

    let dictation = if with_alternatives {
        crate::engine::DictationDto {
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
        crate::engine::DictationDto {
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

    let dto = crate::engine::SnapshotDto {
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
        globe_enabled: cfg.globe_enabled,
        replace_system_picker: cfg.replace_system_picker,
        launch_at_login: cfg.launch_at_login,
        show_menu_bar_icon: true,
        use_frequency_boost: true,
        needs_logout_for_globe: false,
        refinement_provider: cfg.refinement_provider,
        voice_mode: cfg.voice_mode,
        chatgpt_running: true,
        chatgpt_fn_hook_active: true,
        total_emoji_inserted: st.total_emoji_inserted,
        config_path: SpritzConfig::default_path().to_string_lossy().into_owned(),
        picker: Some(crate::engine::PickerViewDto {
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
    };
    into_c_string(serde_json::to_string(&dto).unwrap_or_else(|_| "{}".to_string()))
}

#[no_mangle]
pub extern "C" fn spritz_poll_permissions(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.poll_permissions();
    }
}

#[no_mangle]
pub extern "C" fn spritz_on_app_activated(
    engine: *mut SpritzEngine,
    pid: i32,
    bundle_id: *const c_char,
) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.on_app_activated(pid, cstr_to_string(bundle_id).unwrap_or_default());
    }
}

#[no_mangle]
pub extern "C" fn spritz_on_space_changed(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.on_space_changed();
    }
}

#[no_mangle]
pub extern "C" fn spritz_on_sleep_or_resign(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.on_sleep_or_resign();
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_chatgpt_running(engine: *mut SpritzEngine, running: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_chatgpt_running(running);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_login_status(engine: *mut SpritzEngine, status: i32) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_login_status(status);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_ui_suspended(engine: *mut SpritzEngine, suspended: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_ui_suspended(suspended);
    }
}

#[no_mangle]
pub extern "C" fn spritz_toggle_browser(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.toggle_browser();
    }
}

#[no_mangle]
pub extern "C" fn spritz_show_browser(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.show_browser();
    }
}

#[no_mangle]
pub extern "C" fn spritz_collapse_browser(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.collapse_browser();
    }
}

#[no_mangle]
pub extern "C" fn spritz_begin_search(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.begin_search();
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_query(engine: *mut SpritzEngine, query: *const c_char) {
    if let (Some(eng), Some(q)) = (unsafe { engine.as_mut() }, cstr_to_string(query)) {
        eng.set_query(&q);
    }
}

#[no_mangle]
pub extern "C" fn spritz_select_mode(engine: *mut SpritzEngine, mode_raw: *const c_char) {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return;
    };
    let Some(raw) = cstr_to_string(mode_raw) else {
        return;
    };
    let mode = match raw.as_str() {
        "suggested" => PickerMode::Suggested,
        "mostUsed" => PickerMode::MostUsed,
        "recent" => PickerMode::Recent,
        "all" => PickerMode::All,
        _ => return,
    };
    eng.select_mode(mode);
}

#[no_mangle]
pub extern "C" fn spritz_select_category(engine: *mut SpritzEngine, category: *const c_char) {
    if let (Some(eng), Some(cat)) = (unsafe { engine.as_mut() }, cstr_to_string(category)) {
        eng.select_category(&cat);
    }
}

#[no_mangle]
pub extern "C" fn spritz_pick_hex(
    engine: *mut SpritzEngine,
    hex: *const c_char,
    keep_open: bool,
) {
    if let (Some(eng), Some(h)) = (unsafe { engine.as_mut() }, cstr_to_string(hex)) {
        eng.pick_emoji_by_hex(&h, keep_open);
    }
}

#[no_mangle]
pub extern "C" fn spritz_resolve_drag_and_drop(
    engine: *mut SpritzEngine,
    source_hex: *const c_char,
    point_x: f64,
    point_y: f64,
    frames_json: *const c_char,
) {
    let (Some(eng), Some(src), Some(fjson)) = (
        unsafe { engine.as_mut() },
        cstr_to_string(source_hex),
        cstr_to_string(frames_json),
    ) else {
        return;
    };
    let Some(outcome) = drag_resolve_from_json(point_x, point_y, &src, &fjson) else {
        return;
    };
    match outcome {
        DragOutcome::Cancel => {}
        DragOutcome::Unassign => eng.drag_drop_unassign(&src),
        DragOutcome::Number(idx) => eng.drag_drop_onto_empty_number(&src, idx),
        DragOutcome::Letter(l) => eng.drag_drop_onto_empty_letter(&src, l),
        DragOutcome::Emoji(tgt) => eng.drag_drop_onto_emoji(&src, &tgt),
    }
}

#[no_mangle]
pub extern "C" fn spritz_handle_local_cgevent(
    engine: *mut SpritzEngine,
    cgevent: *const c_void,
) -> bool {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return false;
    };
    let ev = cgevent as CGEventRef;
    if let Some(backward) = is_speech_cycle_event(ev) {
        return eng.on_speech_cycle(backward);
    }
    let Some(input) = translate_cgevent(ev) else {
        return false;
    };
    eng.handle_key_input(input)
}

#[no_mangle]
pub extern "C" fn spritz_post_synthetic_text(
    engine: *const SpritzEngine,
    delete_chars: usize,
    text: *const c_char,
) {
    if let (Some(eng), Some(txt)) = (unsafe { engine.as_ref() }, cstr_to_string(text)) {
        eng.post_synthetic_text(delete_chars, &txt);
    }
}

#[no_mangle]
pub extern "C" fn spritz_pause_for_secs(engine: *mut SpritzEngine, secs: f64) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.pause_for_secs(secs);
    }
}

#[no_mangle]
pub extern "C" fn spritz_resume(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.resume();
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_skin_tone(engine: *mut SpritzEngine, tone: *const c_char) {
    if let (Some(eng), Some(t)) = (unsafe { engine.as_mut() }, cstr_to_string(tone)) {
        eng.set_skin_tone(&t);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_globe_enabled(engine: *mut SpritzEngine, enabled: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_globe_enabled(enabled);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_replace_system_picker(engine: *mut SpritzEngine, enabled: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_replace_system_picker(enabled);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_launch_at_login(engine: *mut SpritzEngine, enabled: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.set_launch_at_login(enabled);
    }
}

#[no_mangle]
pub extern "C" fn spritz_set_refinement_provider(engine: *mut SpritzEngine, raw: *const c_char) {
    if let (Some(eng), Some(s)) = (unsafe { engine.as_mut() }, cstr_to_string(raw)) {
        eng.set_refinement_provider(&s);
    }
}

#[no_mangle]
pub extern "C" fn spritz_analyse_focused_text(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.analyse_focused_text();
    }
}

#[no_mangle]
pub extern "C" fn spritz_select_dictation_choice(engine: *mut SpritzEngine, index: usize) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.select_dictation_choice(index);
    }
}

#[no_mangle]
pub extern "C" fn spritz_choose_dictation_choice(
    engine: *mut SpritzEngine,
    index: usize,
    keep_open: bool,
) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.choose_dictation_alternative(index, keep_open);
    }
}

#[no_mangle]
pub extern "C" fn spritz_publish_touchbar(engine: *mut SpritzEngine, force: bool) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.publish_touchbar(force);
    }
}

#[no_mangle]
pub extern "C" fn spritz_handle_touchbar_request(
    engine: *mut SpritzEngine,
    request_json: *const c_char,
    has_login_result: bool,
    login_status: i32,
    login_error: *const c_char,
) {
    let (Some(eng), Some(json)) = (unsafe { engine.as_mut() }, cstr_to_string(request_json)) else {
        return;
    };
    let err = cstr_to_string(login_error).unwrap_or_default();
    let lr = if has_login_result {
        Some((login_status, err.as_str()))
    } else {
        None
    };
    eng.handle_touchbar_request(&json, lr);
}

#[no_mangle]
pub extern "C" fn spritz_flush_telemetry(engine: *mut SpritzEngine) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.flush_telemetry();
    }
}

#[no_mangle]
pub extern "C" fn spritz_telemetry_report(engine: *const SpritzEngine) -> *mut c_char {
    if let Some(eng) = unsafe { engine.as_ref() } {
        into_c_string(eng.telemetry_report())
    } else {
        into_c_string(String::new())
    }
}
