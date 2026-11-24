use serde::Serialize;
use spritz_core::config::{write_atomic_0600, SpritzState};
use spritz_core::context::match_context;
use spritz_core::db::EmojiDatabase;
use spritz_core::emoji::{canonical_hex, EmojiCategory};
use spritz_core::keyboard::{CandidateItem, KeyboardConfig, KeyboardSession, Lexicon, ShiftState};
use spritz_core::search::search_emojis;
use spritz_core::slots::NUMBER_SLOT_COUNT;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::path::PathBuf;
use std::slice;
use std::time::SystemTime;

const DEFAULT_PINNED_HEXES: &[&str] = &[
    "1F602", "2764", "1F44D", "1F525", "1F389", "1F605", "1F914", "1F970", "1F60E", "2728",
];

pub struct SpritzIosEngine {
    db: &'static EmojiDatabase,
    config_path: PathBuf,
    state_path: PathBuf,
    config_mtime: Option<SystemTime>,
    state_mtime: Option<SystemTime>,
    session: KeyboardSession,
    state: SpritzState,
    last_candidates: Vec<CandidateItem>,
    last_context_before: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct EmojiItemDto {
    hex: String,
    glyph: String,
    label: String,
    category: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EmojiSectionDto {
    category: String,
    title: String,
    symbol: String,
    start_index: usize,
    count: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EmojiSnapshotDto {
    mode: String,
    available_modes: Vec<String>,
    pinned: Vec<EmojiItemDto>,
    items: Vec<EmojiItemDto>,
    sections: Vec<EmojiSectionDto>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EmojiPickDto {
    hex: String,
    glyph: String,
}

impl SpritzIosEngine {
    fn new(config_dir: PathBuf, state_dir: PathBuf) -> Self {
        let config_path = config_dir.join("keyboard.json");
        let state_path = state_dir.join("state.json");
        let config = load_keyboard_config(&config_path);
        let state = SpritzState::load_or_default(&state_path);
        let config_mtime = file_mtime(&config_path);
        let state_mtime = file_mtime(&state_path);
        Self {
            db: EmojiDatabase::global(),
            config_path,
            state_path,
            config_mtime,
            state_mtime,
            session: KeyboardSession::new(config),
            state,
            last_candidates: Vec::new(),
            last_context_before: String::new(),
        }
    }

    fn maybe_reload(&mut self) {
        let cur_cfg_mtime = file_mtime(&self.config_path);
        if cur_cfg_mtime != self.config_mtime && cur_cfg_mtime.is_some() {
            self.session.config = load_keyboard_config(&self.config_path);
            self.config_mtime = cur_cfg_mtime;
        }
        let cur_st_mtime = file_mtime(&self.state_path);
        if cur_st_mtime != self.state_mtime && cur_st_mtime.is_some() {
            self.state = SpritzState::load_or_default(&self.state_path);
            self.state_mtime = cur_st_mtime;
        }
    }

    fn save_config(&mut self) -> bool {
        let Ok(body) = serde_json::to_string_pretty(&self.session.config) else {
            return false;
        };
        if write_atomic_0600(&self.config_path, body.as_bytes()).is_ok() {
            self.config_mtime = file_mtime(&self.config_path);
            true
        } else {
            false
        }
    }

    fn save_state(&mut self) {
        if self.state.save_atomic(&self.state_path).is_ok() {
            self.state_mtime = file_mtime(&self.state_path);
        }
    }

    fn item_dto(&self, idx: usize) -> EmojiItemDto {
        let em = &self.db.all[idx];
        let cat = EmojiCategory::ALL
            .into_iter()
            .find(|c| c.matches_group(em.group))
            .unwrap_or(EmojiCategory::SmileysPeople);
        EmojiItemDto {
            hex: em.hexcode.clone(),
            glyph: em.toned_glyph(self.session.config.skin_tone).into_owned(),
            label: em.label.clone(),
            category: cat.as_str().to_string(),
        }
    }

    fn resolved_pinned_indices(&self) -> Vec<usize> {
        let mut out = Vec::with_capacity(NUMBER_SLOT_COUNT);
        let mut seen = HashSet::new();
        for hex in &self.state.numbered_emoji {
            if !hex.is_empty() {
                if let Some(idx) = self.db.index_of(hex) {
                    if seen.insert(idx) {
                        out.push(idx);
                        if out.len() >= NUMBER_SLOT_COUNT {
                            return out;
                        }
                    }
                }
            }
        }
        for hex in DEFAULT_PINNED_HEXES {
            if let Some(idx) = self.db.index_of(hex) {
                if seen.insert(idx) {
                    out.push(idx);
                    if out.len() >= NUMBER_SLOT_COUNT {
                        return out;
                    }
                }
            }
        }
        for idx in 0..self.db.all.len() {
            if out.len() >= NUMBER_SLOT_COUNT {
                break;
            }
            if seen.insert(idx) {
                out.push(idx);
            }
        }
        out
    }

    fn emoji_snapshot(&mut self, mode: &str, query: &str, context_before: Option<&str>) -> EmojiSnapshotDto {
        self.maybe_reload();
        let suggested_hits = match_context(self.db, context_before, &self.state.usage_counts);
        let mut available_modes = Vec::new();
        if !suggested_hits.is_empty() {
            available_modes.push("suggested".to_string());
        }
        available_modes.push("pinned".to_string());
        available_modes.push("recent".to_string());
        available_modes.push("all".to_string());

        let effective_mode = match mode {
            "suggested" if !suggested_hits.is_empty() => "suggested",
            "pinned" | "recent" | "all" => mode,
            _ => {
                if !suggested_hits.is_empty() && mode == "auto" {
                    "suggested"
                } else {
                    "pinned"
                }
            }
        };

        let pinned_indices = self.resolved_pinned_indices();
        let pinned: Vec<EmojiItemDto> = pinned_indices.iter().map(|&i| self.item_dto(i)).collect();

        let trimmed_query = query.trim();
        let mut sections = Vec::new();
        let items: Vec<EmojiItemDto> = if !trimmed_query.is_empty() {
            search_emojis(self.db, trimmed_query, &self.state.usage_counts, true, 80)
                .into_iter()
                .map(|i| self.item_dto(i))
                .collect()
        } else {
            match effective_mode {
                "suggested" => suggested_hits.iter().map(|&i| self.item_dto(i)).collect(),
                "recent" => {
                    let mut list = Vec::new();
                    let mut seen = HashSet::new();
                    for h in &self.state.recent_emoji {
                        if let Some(idx) = self.db.index_of(h) {
                            if seen.insert(idx) {
                                list.push(self.item_dto(idx));
                            }
                        }
                    }
                    if list.is_empty() {
                        pinned.clone()
                    } else {
                        list
                    }
                }
                "pinned" => {
                    let mut idxs = pinned_indices.clone();
                    let mut seen: HashSet<usize> = idxs.iter().copied().collect();
                    let mut used: Vec<(usize, u64)> = self
                        .state
                        .usage_counts
                        .iter()
                        .filter_map(|(hex, &cnt)| self.db.index_of(hex).map(|idx| (idx, cnt)))
                        .collect();
                    used.sort_by(|a, b| b.1.cmp(&a.1));
                    for (idx, _) in used {
                        if seen.insert(idx) {
                            idxs.push(idx);
                            if idxs.len() >= 48 {
                                break;
                            }
                        }
                    }
                    for h in &self.state.recent_emoji {
                        if idxs.len() >= 48 {
                            break;
                        }
                        if let Some(idx) = self.db.index_of(h) {
                            if seen.insert(idx) {
                                idxs.push(idx);
                            }
                        }
                    }
                    for idx in 0..self.db.all.len() {
                        if idxs.len() >= 48 {
                            break;
                        }
                        if seen.insert(idx) {
                            idxs.push(idx);
                        }
                    }
                    idxs.into_iter().map(|i| self.item_dto(i)).collect()
                }
                _ => {
                    let mut flat = Vec::with_capacity(self.db.all.len());
                    for sec in &self.db.sections {
                        let start = flat.len();
                        for &idx in &sec.indices {
                            flat.push(self.item_dto(idx));
                        }
                        sections.push(EmojiSectionDto {
                            category: sec.category.as_str().to_string(),
                            title: sec.category.title().to_string(),
                            symbol: sec.category.tab_symbol().to_string(),
                            start_index: start,
                            count: sec.indices.len(),
                        });
                    }
                    flat
                }
            }
        };

        EmojiSnapshotDto {
            mode: effective_mode.to_string(),
            available_modes,
            pinned,
            items,
            sections,
        }
    }
}

fn file_mtime(path: &PathBuf) -> Option<SystemTime> {
    fs::metadata(path).ok().and_then(|m| m.modified().ok())
}

fn load_keyboard_config(path: &PathBuf) -> KeyboardConfig {
    match fs::read_to_string(path) {
        Ok(txt) => serde_json::from_str(&txt).unwrap_or_default(),
        Err(_) => KeyboardConfig::default(),
    }
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_string)
}

fn into_c_string(s: String) -> *mut c_char {
    let sanitized = if s.contains('\0') {
        s.replace('\0', "")
    } else {
        s
    };
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("{}").unwrap())
        .into_raw()
}

fn serialize_output(eng: &mut SpritzIosEngine, out: spritz_core::keyboard::KeyboardOutput) -> *mut c_char {
    eng.last_candidates = out.candidates.clone();
    let json = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
    into_c_string(json)
}

#[no_mangle]
pub extern "C" fn spritz_ios_create(
    config_dir: *const c_char,
    state_dir: *const c_char,
) -> *mut SpritzIosEngine {
    let cfg = cstr_to_string(config_dir)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("spritz-ios"));
    let st = cstr_to_string(state_dir)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| cfg.clone());
    Box::into_raw(Box::new(SpritzIosEngine::new(cfg, st)))
}

#[no_mangle]
pub extern "C" fn spritz_ios_destroy(engine: *mut SpritzIosEngine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

#[no_mangle]
pub extern "C" fn spritz_ios_free_cstr(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn spritz_ios_lexicon_count() -> usize {
    Lexicon::global().words.len()
}

#[no_mangle]
pub extern "C" fn spritz_ios_tap_key(
    engine: *mut SpritzIosEngine,
    ch: *const c_char,
    x: f32,
    y: f32,
    context_before: *const c_char,
    system_known: bool,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let key_str = cstr_to_string(ch).unwrap_or_default();
    let Some(key_ch) = key_str.chars().next() else {
        let out = eng
            .session
            .sync_context_checked(Some(&ctx), system_known, eng.db, &eng.state.usage_counts);
        return serialize_output(eng, out);
    };
    let out = eng
        .session
        .tap_key_checked(key_ch, x, y, Some(&ctx), system_known, eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_insert_direct(
    engine: *mut SpritzIosEngine,
    text: *const c_char,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let txt = cstr_to_string(text).unwrap_or_default();
    let out = eng
        .session
        .insert_direct(&txt, Some(&ctx), eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_tap_space(
    engine: *mut SpritzIosEngine,
    context_before: *const c_char,
    system_known: bool,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let out = eng
        .session
        .tap_space_checked(Some(&ctx), system_known, eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_tap_return(
    engine: *mut SpritzIosEngine,
    context_before: *const c_char,
    system_known: bool,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let out = eng
        .session
        .tap_return_checked(Some(&ctx), system_known, eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_tap_backspace(
    engine: *mut SpritzIosEngine,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let prev_rej = eng.session.config.rejected_corrections.len();
    let out = eng
        .session
        .tap_backspace(Some(&ctx), eng.db, &eng.state.usage_counts);
    if eng.session.config.rejected_corrections.len() != prev_rej {
        let _ = eng.save_config();
    }
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_swipe_delete_word(
    engine: *mut SpritzIosEngine,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let out = eng
        .session
        .swipe_delete_word(Some(&ctx), eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_undo_last_delete(engine: *mut SpritzIosEngine) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = eng.last_context_before.clone();
    let out = eng
        .session
        .undo_last_delete(Some(&ctx), eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_finish_glide(
    engine: *mut SpritzIosEngine,
    xy_pairs: *const f32,
    point_count: usize,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let points: Vec<(f32, f32)> = if !xy_pairs.is_null() && point_count > 0 {
        let raw = unsafe { slice::from_raw_parts(xy_pairs, point_count * 2) };
        raw.chunks_exact(2).map(|p| (p[0], p[1])).collect()
    } else {
        Vec::new()
    };
    let out = eng
        .session
        .finish_glide(&points, Some(&ctx), eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_accept_candidate(
    engine: *mut SpritzIosEngine,
    index: usize,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let cand_text = eng
        .last_candidates
        .get(index)
        .map(|c| c.text.clone())
        .unwrap_or_default();
    if cand_text.is_empty() {
        let out = eng
            .session
            .sync_context(Some(&ctx), eng.db, &eng.state.usage_counts);
        return serialize_output(eng, out);
    }
    let out = eng
        .session
        .accept_candidate(&cand_text, Some(&ctx), eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_set_shift(engine: *mut SpritzIosEngine, state: i32) {
    if let Some(eng) = unsafe { engine.as_mut() } {
        eng.session.shift_state = ShiftState::from_i32(state);
    }
}

#[no_mangle]
pub extern "C" fn spritz_ios_sync_context(
    engine: *mut SpritzIosEngine,
    context_before: *const c_char,
    system_known: bool,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    let ctx = cstr_to_string(context_before).unwrap_or_default();
    eng.last_context_before = ctx.clone();
    let out = eng
        .session
        .sync_context_checked(Some(&ctx), system_known, eng.db, &eng.state.usage_counts);
    serialize_output(eng, out)
}

#[no_mangle]
pub extern "C" fn spritz_ios_emoji_snapshot(
    engine: *mut SpritzIosEngine,
    mode: *const c_char,
    query: *const c_char,
    context_before: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    let mode_s = cstr_to_string(mode).unwrap_or_else(|| "pinned".to_string());
    let query_s = cstr_to_string(query).unwrap_or_default();
    let ctx_s = cstr_to_string(context_before);
    let snap = eng.emoji_snapshot(&mode_s, &query_s, ctx_s.as_deref());
    into_c_string(serde_json::to_string(&snap).unwrap_or_else(|_| "{}".to_string()))
}

#[no_mangle]
pub extern "C" fn spritz_ios_emoji_pick(
    engine: *mut SpritzIosEngine,
    hex: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    let raw_hex = cstr_to_string(hex).unwrap_or_default();
    let canon = eng
        .db
        .canonical_hex_for(&raw_hex)
        .map(str::to_string)
        .or_else(|| canonical_hex(&raw_hex))
        .unwrap_or(raw_hex);
    let glyph = eng
        .db
        .index_of(&canon)
        .map(|i| {
            eng.db.all[i]
                .toned_glyph(eng.session.config.skin_tone)
                .into_owned()
        })
        .unwrap_or_default();
    if !canon.is_empty() {
        eng.state.record_pick(&canon);
        eng.save_state();
    }
    into_c_string(
        serde_json::to_string(&EmojiPickDto { hex: canon, glyph })
            .unwrap_or_else(|_| "{}".to_string()),
    )
}

#[no_mangle]
pub extern "C" fn spritz_ios_emoji_pin(
    engine: *mut SpritzIosEngine,
    slot_index: usize,
    hex: *const c_char,
) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("[]".to_string());
    };
    if slot_index < NUMBER_SLOT_COUNT {
        if eng.state.numbered_emoji.len() < NUMBER_SLOT_COUNT {
            let defaults = eng.resolved_pinned_indices();
            eng.state.numbered_emoji = defaults
                .into_iter()
                .map(|i| eng.db.all[i].hexcode.clone())
                .collect();
            while eng.state.numbered_emoji.len() < NUMBER_SLOT_COUNT {
                eng.state.numbered_emoji.push(String::new());
            }
        }
        let raw_hex = cstr_to_string(hex).unwrap_or_default();
        let canon = if raw_hex.is_empty() {
            String::new()
        } else {
            eng.db
                .canonical_hex_for(&raw_hex)
                .map(str::to_string)
                .or_else(|| canonical_hex(&raw_hex))
                .unwrap_or(raw_hex)
        };
        eng.state.numbered_emoji[slot_index] = canon;
        eng.save_state();
    }
    let pinned: Vec<EmojiItemDto> = eng
        .resolved_pinned_indices()
        .into_iter()
        .map(|i| eng.item_dto(i))
        .collect();
    into_c_string(serde_json::to_string(&pinned).unwrap_or_else(|_| "[]".to_string()))
}

#[no_mangle]
pub extern "C" fn spritz_ios_get_config_json(engine: *mut SpritzIosEngine) -> *mut c_char {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return into_c_string("{}".to_string());
    };
    eng.maybe_reload();
    into_c_string(
        serde_json::to_string(&eng.session.config).unwrap_or_else(|_| "{}".to_string()),
    )
}

#[no_mangle]
pub extern "C" fn spritz_ios_set_config_json(
    engine: *mut SpritzIosEngine,
    json: *const c_char,
) -> bool {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return false;
    };
    let Some(txt) = cstr_to_string(json) else {
        return false;
    };
    let Ok(cfg) = serde_json::from_str::<KeyboardConfig>(&txt) else {
        return false;
    };
    eng.session.config = cfg;
    eng.save_config()
}

#[no_mangle]
pub extern "C" fn spritz_ios_learn_word(
    engine: *mut SpritzIosEngine,
    word: *const c_char,
) -> bool {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return false;
    };
    let Some(w) = cstr_to_string(word) else {
        return false;
    };
    let trimmed = w.trim();
    if trimmed.is_empty() {
        return false;
    }
    if !eng
        .session
        .config
        .personal_words
        .iter()
        .any(|p| p.eq_ignore_ascii_case(trimmed))
    {
        eng.session.config.personal_words.push(trimmed.to_string());
    }
    eng.save_config()
}

#[no_mangle]
pub extern "C" fn spritz_ios_forget_word(
    engine: *mut SpritzIosEngine,
    word: *const c_char,
) -> bool {
    let Some(eng) = (unsafe { engine.as_mut() }) else {
        return false;
    };
    let Some(w) = cstr_to_string(word) else {
        return false;
    };
    let trimmed = w.trim();
    eng.session
        .config
        .personal_words
        .retain(|p| !p.eq_ignore_ascii_case(trimmed));
    eng.save_config()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    unsafe fn take_str(ptr: *mut c_char) -> String {
        let s = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        spritz_ios_free_cstr(ptr);
        s
    }

    #[test]
    fn ffi_lifecycle_typing_and_emoji_roundtrip() {
        let dir = std::env::temp_dir().join(format!("spritz_ios_ffi_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let dir_c = CString::new(dir.to_string_lossy().as_ref()).unwrap();

        unsafe {
            let eng = spritz_ios_create(dir_c.as_ptr(), dir_c.as_ptr());
            assert!(!eng.is_null());

            assert!(spritz_ios_lexicon_count() > 20_000);

            spritz_ios_set_shift(eng, 0);
            let k = CString::new("t").unwrap();
            let ctx = CString::new("").unwrap();
            let r1 = take_str(spritz_ios_tap_key(eng, k.as_ptr(), 0.45, 0.16, ctx.as_ptr(), false));
            assert!(r1.contains(r#""insert":"t""#));

            let ctx2 = CString::new("teh").unwrap();
            let sp = take_str(spritz_ios_tap_space(eng, ctx2.as_ptr(), false));
            assert!(sp.contains(r#""insert":"the ""#));

            let ret_ctx = CString::new("teh").unwrap();
            let ret = take_str(spritz_ios_tap_return(eng, ret_ctx.as_ptr(), false));
            assert!(ret.contains(r#""insert":"the\n""#));

            let sync = take_str(spritz_ios_sync_context(eng, ctx.as_ptr(), false));
            assert!(sync.contains("shiftState"));

            let mode = CString::new("pinned").unwrap();
            let q = CString::new("fire").unwrap();
            let snap = take_str(spritz_ios_emoji_snapshot(
                eng,
                mode.as_ptr(),
                q.as_ptr(),
                ctx.as_ptr(),
            ));
            assert!(snap.contains("1F525"));

            let hex = CString::new("1F525").unwrap();
            let pick = take_str(spritz_ios_emoji_pick(eng, hex.as_ptr()));
            assert!(pick.contains("🔥"));

            let w = CString::new("Antigravity").unwrap();
            assert!(spritz_ios_learn_word(eng, w.as_ptr()));
            let cfg = take_str(spritz_ios_get_config_json(eng));
            assert!(cfg.contains("Antigravity"));
            assert!(spritz_ios_forget_word(eng, w.as_ptr()));

            spritz_ios_destroy(eng);
        }

        let _ = fs::remove_dir_all(&dir);
    }
}
