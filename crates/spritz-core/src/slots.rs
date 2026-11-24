use crate::context::match_context;
use crate::db::EmojiDatabase;
use crate::emoji::{canonical_hex, EmojiCategory};
use crate::search::search_emojis;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const NUMBER_KEYS: [char; 10] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
pub const NUMBER_SLOT_COUNT: usize = 10;
pub const LETTER_KEYS: [char; 26] = [
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r',
    's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
];
pub const SHORTCUT_COLUMNS: usize = 10;
pub const GRID_COLUMNS: usize = 7;
pub const MINIMUM_SHORTCUT_SLOTS: usize = SHORTCUT_COLUMNS * 8;

const DEFAULT_FALLBACK_HEXES: &[&str] = &[
    "1F602", "2764", "1F44D", "1F62D", "1F525", "1F389", "1F605", "1F914", "1F970", "1F60E",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PickerMode {
    Suggested,
    MostUsed,
    Recent,
    All,
}

impl PickerMode {
    pub fn title(self) -> &'static str {
        match self {
            Self::Suggested => "Suggested",
            Self::MostUsed => "Most used",
            Self::Recent => "Recent",
            Self::All => "All",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PickerSlot {
    pub id: String,
    pub emoji_idx: Option<usize>,
    pub shortcut: Option<char>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SectionSpan {
    pub category: EmojiCategory,
    pub start_index: usize,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DragOutcome {
    Cancel,
    Unassign,
    Number(usize),
    Letter(char),
    Emoji(String),
}

/// Resolves a pointer drop among recorded slot rectangles (`id -> (x, y, w, h)`).
pub fn resolve_drag(
    point_x: f64,
    point_y: f64,
    source_hex: &str,
    frames: &HashMap<String, (f64, f64, f64, f64)>,
) -> DragOutcome {
    if let Some(&(x, y, w, h)) = frames.get(source_hex) {
        if point_x >= x && point_x <= x + w && point_y >= y && point_y <= y + h {
            return DragOutcome::Cancel;
        }
    }
    let mut best: Option<(&str, f64)> = None;
    for (key, &(x, y, w, h)) in frames {
        if key == source_hex {
            continue;
        }
        let ex0 = x - 4.0;
        let ey0 = y - 4.0;
        let ex1 = x + w + 4.0;
        let ey1 = y + h + 4.0;
        if point_x >= ex0 && point_x <= ex1 && point_y >= ey0 && point_y <= ey1 {
            let cx = x + w * 0.5;
            let cy = y + h * 0.5;
            let dist = (cx - point_x).hypot(cy - point_y);
            if best.map_or(true, |(_, d)| dist < d) {
                best = Some((key.as_str(), dist));
            }
        }
    }
    let Some((target, _)) = best else {
        return DragOutcome::Unassign;
    };
    if let Some(rest) = target.strip_prefix("number-") {
        if let Some(ch) = rest.chars().next() {
            if let Some(idx) = NUMBER_KEYS.iter().position(|&k| k == ch) {
                return DragOutcome::Number(idx);
            }
        }
    }
    if let Some(rest) = target.strip_prefix("letter-") {
        let mut chars = rest.chars();
        if let (Some(ch), None) = (chars.next(), chars.next()) {
            let lower = ch.to_ascii_lowercase();
            if lower.is_ascii_lowercase() {
                return DragOutcome::Letter(lower);
            }
        }
    }
    DragOutcome::Emoji(target.to_string())
}

pub fn resolve_letter_bindings(
    db: &EmojiDatabase,
    candidate_indices: &[usize],
    saved: &HashMap<String, String>,
    blocked: &HashSet<char>,
) -> HashMap<String, char> {
    let mut unique_indices = Vec::new();
    let mut seen_hex = HashSet::new();
    for &idx in candidate_indices {
        let hex = &db.all[idx].hexcode;
        if seen_hex.insert(hex.clone()) {
            unique_indices.push(idx);
        }
    }

    let mut normalized: HashMap<String, char> = HashMap::new();
    let mut saved_keys: Vec<&String> = saved.keys().collect();
    saved_keys.sort();
    for key in saved_keys {
        let Some(canon_key) = db.canonical_hex_for(key).map(str::to_string).or_else(|| canonical_hex(key)) else {
            continue;
        };
        let val = &saved[key];
        let mut chars = val.chars();
        let Some(ch) = chars.next() else { continue };
        if chars.next().is_some() || !ch.is_ascii_alphabetic() {
            continue;
        }
        let lower = ch.to_ascii_lowercase();
        if blocked.contains(&lower) {
            continue;
        }
        normalized.entry(canon_key).or_insert(lower);
    }

    let mut result: HashMap<String, char> = HashMap::new();
    let mut occupied: HashSet<char> = blocked.clone();

    for &idx in &unique_indices {
        let hex = &db.all[idx].hexcode;
        if let Some(&letter) = normalized.get(hex) {
            if occupied.insert(letter) {
                result.insert(hex.clone(), letter);
            }
        }
    }

    let max_letters = LETTER_KEYS.len();
    for &idx in &unique_indices {
        if result.len() + blocked.len() >= max_letters {
            break;
        }
        let emoji = &db.all[idx];
        if result.contains_key(&emoji.hexcode) {
            continue;
        }
        if let Some(letter) = mnemonic_choices(emoji)
            .into_iter()
            .find(|c| !occupied.contains(c))
        {
            occupied.insert(letter);
            result.insert(emoji.hexcode.clone(), letter);
        }
    }

    result
}

fn mnemonic_choices(emoji: &crate::emoji::Emoji) -> Vec<char> {
    let curated = match emoji.hexcode.as_str() {
        "2764" | "2764-FE0F" => Some('h'),
        "1F3F4-200D-2620" | "1F3F4-200D-2620-FE0F" => Some('p'),
        "1F44D" => Some('t'),
        "1F480" => Some('s'),
        "1F1E6-1F1FA" => Some('a'),
        "1F916" => Some('r'),
        "1F62D" => Some('c'),
        "1F914" => Some('t'),
        "1F525" => Some('f'),
        _ => None,
    };

    let mut out = Vec::new();
    let mut push_unique = |c: char| {
        if c.is_ascii_lowercase() && !out.contains(&c) {
            out.push(c);
        }
    };
    if let Some(c) = curated {
        push_unique(c);
    }

    let words_of = |s: &str| -> Vec<String> {
        let mut ws = Vec::new();
        let mut cur = String::new();
        for c in s.to_ascii_lowercase().chars() {
            if c.is_ascii_lowercase() {
                cur.push(c);
            } else if !cur.is_empty() {
                ws.push(std::mem::take(&mut cur));
            }
        }
        if !cur.is_empty() {
            ws.push(cur);
        }
        ws
    };

    let mut all_words = words_of(&emoji.label);
    for sc in &emoji.shortcodes {
        all_words.extend(words_of(sc));
    }
    for w in &all_words {
        if let Some(first) = w.chars().next() {
            push_unique(first);
        }
    }
    for w in &all_words {
        for c in w.chars() {
            push_unique(c);
        }
    }
    for c in LETTER_KEYS {
        push_unique(c);
    }
    out
}

#[derive(Debug, Clone)]
pub struct PickerPersistedEdits {
    pub numbered_emoji: Vec<String>,
    pub letter_bindings: HashMap<String, String>,
    pub released_hexes: Vec<String>,
    pub released_letters: Vec<String>,
}

#[derive(Debug)]
pub struct PickerModel {
    pub mode: PickerMode,
    pub numbered_slots: [Option<usize>; NUMBER_SLOT_COUNT],
    pub letter_bindings: HashMap<String, char>,
    pub released_hexes: HashSet<String>,
    pub released_letters: HashSet<char>,
    pub picker_slots: Vec<PickerSlot>,
    pub shortcut_selected_index: usize,
    pub selected_index: usize,
    pub hover_index: Option<usize>,
    pub search_input_active: bool,
    pub query: String,
    pub active_category: EmojiCategory,
    pub scroll_target_slot: Option<String>,
    pub scroll_target_grid: Option<usize>,
    pub scroll_target_category: Option<EmojiCategory>,
    pub current: Vec<usize>,
    pub most_used: Vec<usize>,
    pub recent: Vec<usize>,
    pub contextual: Vec<usize>,
    pub sections: Vec<SectionSpan>,
    pub flat: Vec<usize>,
    use_frequency_boost: bool,
    usage: HashMap<String, u64>,
}

impl PickerModel {
    #[allow(clippy::too_many_arguments)]
    pub fn open(
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
        recent_hexes: &[String],
        saved_numbers: &[String],
        saved_letters: &HashMap<String, String>,
        released_hexes_raw: &[String],
        released_letters_raw: &[String],
        context_text: Option<&str>,
        use_frequency_boost: bool,
    ) -> Self {
        let mut flat = Vec::with_capacity(db.all.len());
        let mut sections = Vec::with_capacity(db.sections.len());
        for sec in &db.sections {
            let start = flat.len();
            flat.extend_from_slice(&sec.indices);
            sections.push(SectionSpan {
                category: sec.category,
                start_index: start,
                count: sec.indices.len(),
            });
        }

        // Canonicalize usage map for consistent lookup.
        let mut canonical_usage: HashMap<String, u64> = HashMap::new();
        for (k, &v) in usage {
            let key = db
                .canonical_hex_for(k)
                .map(str::to_string)
                .or_else(|| canonical_hex(k))
                .unwrap_or_else(|| k.clone());
            *canonical_usage.entry(key).or_insert(0) += v;
        }

        let mut most_used: Vec<(usize, u64)> = db
            .all
            .iter()
            .enumerate()
            .filter_map(|(idx, e)| {
                let c = canonical_usage.get(&e.hexcode).copied().unwrap_or(0);
                (c > 0).then_some((idx, c))
            })
            .collect();
        most_used.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then_with(|| db.all[a.0].hexcode.cmp(&db.all[b.0].hexcode))
        });
        let most_used: Vec<usize> = most_used.into_iter().map(|(i, _)| i).collect();

        let fallback_indices: Vec<usize> = DEFAULT_FALLBACK_HEXES
            .iter()
            .filter_map(|h| db.index_of(h))
            .collect();
        let mut fallback_quick = Vec::new();
        let mut qseen = HashSet::new();
        for &idx in most_used.iter().chain(fallback_indices.iter()).chain(flat.iter()) {
            if qseen.insert(idx) {
                fallback_quick.push(idx);
                if fallback_quick.len() >= NUMBER_SLOT_COUNT {
                    break;
                }
            }
        }

        let released_hexes: HashSet<String> = released_hexes_raw
            .iter()
            .filter_map(|h| {
                db.canonical_hex_for(h)
                    .map(str::to_string)
                    .or_else(|| canonical_hex(h))
            })
            .collect();
        let released_letters: HashSet<char> = released_letters_raw
            .iter()
            .filter_map(|s| s.chars().next())
            .map(|c| c.to_ascii_lowercase())
            .filter(|c| c.is_ascii_lowercase())
            .collect();

        let mut numbered_slots: [Option<usize>; NUMBER_SLOT_COUNT] = [None; NUMBER_SLOT_COUNT];
        if saved_numbers.is_empty() {
            for (i, &idx) in fallback_quick.iter().take(NUMBER_SLOT_COUNT).enumerate() {
                numbered_slots[i] = Some(idx);
            }
        } else {
            let mut used_indices = HashSet::new();
            for (i, raw) in saved_numbers.iter().take(NUMBER_SLOT_COUNT).enumerate() {
                if !raw.is_empty() {
                    if let Some(idx) = db.index_of(raw) {
                        if used_indices.insert(idx) {
                            numbered_slots[i] = Some(idx);
                        }
                    }
                }
            }
            if saved_numbers.len() < NUMBER_SLOT_COUNT {
                let mut fill_cursor = 0;
                for i in saved_numbers.len()..NUMBER_SLOT_COUNT {
                    while fill_cursor < fallback_quick.len() {
                        let idx = fallback_quick[fill_cursor];
                        fill_cursor += 1;
                        let hex = &db.all[idx].hexcode;
                        if !released_hexes.contains(hex) && used_indices.insert(idx) {
                            numbered_slots[i] = Some(idx);
                            break;
                        }
                    }
                }
            }
        }

        let numbered_set: HashSet<usize> = numbered_slots.iter().flatten().copied().collect();
        let mut clean_saved_letters: HashMap<String, String> = HashMap::new();
        for (k, v) in saved_letters {
            let canon = db
                .canonical_hex_for(k)
                .map(str::to_string)
                .or_else(|| canonical_hex(k));
            if let Some(canon) = canon {
                if !released_hexes.contains(&canon) {
                    clean_saved_letters.insert(canon, v.clone());
                }
            }
        }

        let mut candidate_indices: Vec<usize> = Vec::new();
        let mut saved_extra: Vec<&String> = clean_saved_letters.keys().collect();
        saved_extra.sort();
        for &idx in most_used.iter().chain(flat.iter()) {
            let hex = &db.all[idx].hexcode;
            if !numbered_set.contains(&idx) && !released_hexes.contains(hex) {
                candidate_indices.push(idx);
            }
        }
        for key in saved_extra {
            if let Some(idx) = db.index_of(key) {
                if !numbered_set.contains(&idx) && !released_hexes.contains(&db.all[idx].hexcode) {
                    candidate_indices.push(idx);
                }
            }
        }
        let letter_bindings =
            resolve_letter_bindings(db, &candidate_indices, &clean_saved_letters, &released_letters);

        let mut recent_seen = HashSet::new();
        let recent: Vec<usize> = recent_hexes
            .iter()
            .filter_map(|h| db.index_of(h))
            .filter(|&idx| recent_seen.insert(idx))
            .collect();

        let contextual = match_context(db, context_text, &canonical_usage);
        let mode = if !contextual.is_empty() {
            PickerMode::Suggested
        } else if !most_used.is_empty() {
            PickerMode::MostUsed
        } else {
            PickerMode::All
        };

        let first_cat = sections
            .first()
            .map(|s| s.category)
            .unwrap_or(EmojiCategory::SmileysPeople);

        let mut model = Self {
            mode,
            numbered_slots,
            letter_bindings,
            released_hexes,
            released_letters,
            picker_slots: Vec::new(),
            shortcut_selected_index: 0,
            selected_index: 0,
            hover_index: None,
            search_input_active: false,
            query: String::new(),
            active_category: first_cat,
            scroll_target_slot: None,
            scroll_target_grid: None,
            scroll_target_category: None,
            current: Vec::new(),
            most_used,
            recent,
            contextual,
            sections,
            flat,
            use_frequency_boost,
            usage: canonical_usage,
        };
        model.recompute_current(db);
        model
    }

    pub fn has_context_suggestions(&self) -> bool {
        !self.contextual.is_empty()
    }

    pub fn available_modes(&self) -> Vec<PickerMode> {
        if self.has_context_suggestions() {
            vec![
                PickerMode::Suggested,
                PickerMode::MostUsed,
                PickerMode::Recent,
                PickerMode::All,
            ]
        } else {
            vec![PickerMode::MostUsed, PickerMode::Recent, PickerMode::All]
        }
    }

    pub fn is_searching(&self) -> bool {
        !self.query.trim().is_empty()
    }

    pub fn shows_categories(&self) -> bool {
        self.mode == PickerMode::All && !self.is_searching()
    }

    pub fn recompute_current(&mut self, db: &EmojiDatabase) {
        let trimmed = self.query.trim();
        if trimmed.is_empty() {
            self.current = match self.mode {
                PickerMode::Suggested => {
                    let mut out = self.contextual.clone();
                    for &i in &self.most_used {
                        if !out.contains(&i) {
                            out.push(i);
                        }
                    }
                    out
                }
                PickerMode::MostUsed => self.most_used.clone(),
                PickerMode::Recent => self.recent.clone(),
                PickerMode::All => self.flat.clone(),
            };
        } else {
            self.current =
                search_emojis(db, trimmed, &self.usage, self.use_frequency_boost, 240);
        }
        self.publish_picker_slots(db);
    }

    fn letter_slot_emoji(&self, db: &EmojiDatabase, letter: char) -> Option<usize> {
        let mut best: Option<(&String, usize)> = None;
        for (hex, &l) in &self.letter_bindings {
            if l == letter {
                if let Some(idx) = db.index_of(hex) {
                    if best.map_or(true, |(bhex, _)| hex < bhex) {
                        best = Some((hex, idx));
                    }
                }
            }
        }
        best.map(|(_, idx)| idx)
    }

    pub fn publish_picker_slots(&mut self, db: &EmojiDatabase) {
        let mut slots = Vec::with_capacity(NUMBER_SLOT_COUNT + LETTER_KEYS.len() + 64);
        let mut shown = HashSet::new();

        for (offset, &key) in NUMBER_KEYS.iter().enumerate() {
            if let Some(idx) = self.numbered_slots[offset] {
                shown.insert(idx);
                slots.push(PickerSlot {
                    id: db.all[idx].hexcode.clone(),
                    emoji_idx: Some(idx),
                    shortcut: Some(key),
                });
            } else {
                slots.push(PickerSlot {
                    id: format!("number-{key}"),
                    emoji_idx: None,
                    shortcut: Some(key),
                });
            }
        }

        for letter in LETTER_KEYS {
            if let Some(idx) = self.letter_slot_emoji(db, letter) {
                if shown.insert(idx) {
                    slots.push(PickerSlot {
                        id: db.all[idx].hexcode.clone(),
                        emoji_idx: Some(idx),
                        shortcut: Some(letter),
                    });
                    continue;
                }
            }
            slots.push(PickerSlot {
                id: format!("letter-{letter}"),
                emoji_idx: None,
                shortcut: Some(letter),
            });
        }

        for &idx in &self.current {
            if shown.insert(idx) {
                slots.push(PickerSlot {
                    id: db.all[idx].hexcode.clone(),
                    emoji_idx: Some(idx),
                    shortcut: None,
                });
            }
        }

        if !self.current.is_empty() && slots.len() < MINIMUM_SHORTCUT_SLOTS {
            for &idx in &self.flat {
                if slots.len() >= MINIMUM_SHORTCUT_SLOTS {
                    break;
                }
                if shown.insert(idx) {
                    slots.push(PickerSlot {
                        id: db.all[idx].hexcode.clone(),
                        emoji_idx: Some(idx),
                        shortcut: None,
                    });
                }
            }
        }

        self.picker_slots = slots;
        if self.shortcut_selected_index >= self.picker_slots.len() {
            self.shortcut_selected_index = 0;
        }
    }

    pub fn emoji_for_shortcut(&self, key: char) -> Option<usize> {
        if self.search_input_active {
            return None;
        }
        if let Some(pos) = NUMBER_KEYS.iter().position(|&k| k == key) {
            return self.numbered_slots[pos];
        }
        let lower = key.to_ascii_lowercase();
        if !lower.is_ascii_lowercase() {
            return None;
        }
        self.picker_slots
            .iter()
            .find(|s| s.shortcut == Some(lower))
            .and_then(|s| s.emoji_idx)
    }

    pub fn selected_emoji_index(&self) -> Option<usize> {
        if !self.search_input_active {
            return self
                .picker_slots
                .get(self.shortcut_selected_index)
                .and_then(|s| s.emoji_idx)
                .or_else(|| self.picker_slots.iter().find_map(|s| s.emoji_idx));
        }
        if let Some(h) = self.hover_index {
            if let Some(&idx) = self.current.get(h) {
                return Some(idx);
            }
        }
        self.current
            .get(self.selected_index)
            .copied()
            .or_else(|| self.current.first().copied())
    }

    pub fn begin_search(&mut self) {
        self.search_input_active = true;
    }

    pub fn exit_search(&mut self, db: &EmojiDatabase) {
        self.search_input_active = false;
        self.query.clear();
        self.hover_index = None;
        self.selected_index = 0;
        self.shortcut_selected_index = 0;
        self.recompute_current(db);
        self.scroll_target_slot = self.picker_slots.first().map(|s| s.id.clone());
        self.scroll_target_grid = Some(0);
    }

    pub fn set_query(&mut self, db: &EmojiDatabase, q: String) {
        if !q.trim().is_empty() {
            self.search_input_active = true;
        }
        self.hover_index = None;
        self.query = q;
        self.selected_index = 0;
        self.shortcut_selected_index = 0;
        self.recompute_current(db);
        self.scroll_target_grid = Some(0);
    }

    pub fn select_mode(&mut self, db: &EmojiDatabase, mode: PickerMode) {
        if mode == PickerMode::Suggested && !self.has_context_suggestions() {
            return;
        }
        self.mode = mode;
        self.scroll_target_category = None;
        self.exit_search(db);
        self.active_category = self
            .sections
            .first()
            .map(|s| s.category)
            .unwrap_or(EmojiCategory::SmileysPeople);
    }

    pub fn select_category(&mut self, db: &EmojiDatabase, cat: EmojiCategory) {
        self.mode = PickerMode::All;
        self.hover_index = None;
        self.query.clear();
        self.search_input_active = false;
        self.shortcut_selected_index = 0;
        self.recompute_current(db);

        if let Some(sec) = self.sections.iter().find(|s| s.category == cat) {
            self.selected_index = sec.start_index;
            let members: HashSet<usize> = self.flat[sec.start_index..sec.start_index + sec.count]
                .iter()
                .copied()
                .collect();
            let slot_idx = self
                .picker_slots
                .iter()
                .position(|s| {
                    s.shortcut.is_none() && s.emoji_idx.map_or(false, |i| members.contains(&i))
                })
                .or_else(|| {
                    self.picker_slots
                        .iter()
                        .position(|s| s.emoji_idx.map_or(false, |i| members.contains(&i)))
                });
            if let Some(i) = slot_idx {
                self.shortcut_selected_index = i;
                self.scroll_target_slot = Some(self.picker_slots[i].id.clone());
            }
        }
        self.active_category = cat;
    }

    pub fn select_emoji_index(&mut self, db: &EmojiDatabase, emoji_idx: usize) {
        self.hover_index = None;
        let hex = &db.all[emoji_idx].hexcode;
        if let Some(pos) = self.picker_slots.iter().position(|s| s.id == *hex) {
            self.shortcut_selected_index = pos;
        }
        if let Some(pos) = self.current.iter().position(|&i| i == emoji_idx) {
            self.selected_index = pos;
        }
    }

    pub fn move_selection(&mut self, dir: Direction) {
        if !self.search_input_active {
            let count = self.picker_slots.len();
            if count == 0 {
                return;
            }
            let cur = self.shortcut_selected_index as isize;
            let delta = match dir {
                Direction::Left => -1,
                Direction::Right => 1,
                Direction::Up => -(SHORTCUT_COLUMNS as isize),
                Direction::Down => SHORTCUT_COLUMNS as isize,
            };
            self.hover_index = None;
            self.shortcut_selected_index = (cur + delta).clamp(0, (count - 1) as isize) as usize;
            self.scroll_target_slot = self
                .picker_slots
                .get(self.shortcut_selected_index)
                .map(|s| s.id.clone());
            return;
        }

        let count = self.current.len();
        if count == 0 {
            return;
        }
        let prev = self.selected_index;
        if !self.shows_categories() {
            let cur = self.selected_index as isize;
            let delta = match dir {
                Direction::Left => -1,
                Direction::Right => 1,
                Direction::Up => -(GRID_COLUMNS as isize),
                Direction::Down => GRID_COLUMNS as isize,
            };
            self.selected_index = (cur + delta).clamp(0, (count - 1) as isize) as usize;
        } else {
            self.selected_index = self.sectioned_target(self.selected_index, dir);
        }
        if self.selected_index != prev {
            self.scroll_target_grid = Some(self.selected_index);
        }
    }

    fn sectioned_target(&self, index: usize, dir: Direction) -> usize {
        let Some(s) = self
            .sections
            .iter()
            .position(|sec| index >= sec.start_index && index < sec.start_index + sec.count)
        else {
            return index;
        };
        let sec = &self.sections[s];
        let local = index - sec.start_index;
        let col = local % GRID_COLUMNS;

        match dir {
            Direction::Left => index.saturating_sub(1),
            Direction::Right => (index + 1).min(self.flat.len().saturating_sub(1)),
            Direction::Down => {
                if local + GRID_COLUMNS < sec.count {
                    index + GRID_COLUMNS
                } else if s + 1 < self.sections.len() {
                    let next = &self.sections[s + 1];
                    next.start_index + col.min(next.count.saturating_sub(1))
                } else {
                    index
                }
            }
            Direction::Up => {
                if local >= GRID_COLUMNS {
                    index - GRID_COLUMNS
                } else if s > 0 {
                    let prev = &self.sections[s - 1];
                    let last_row_start = ((prev.count - 1) / GRID_COLUMNS) * GRID_COLUMNS;
                    prev.start_index + (last_row_start + col).min(prev.count - 1)
                } else {
                    index
                }
            }
        }
    }

    // MARK: Drag-and-drop shortcut editing

    pub fn drop_onto_emoji(&mut self, db: &EmojiDatabase, source_hex: &str, target_hex: &str) -> bool {
        let (Some(src_idx), Some(tgt_idx)) = (db.index_of(source_hex), db.index_of(target_hex)) else {
            return false;
        };
        if src_idx == tgt_idx {
            return false;
        }
        let src_canon = db.all[src_idx].hexcode.clone();
        let tgt_canon = db.all[tgt_idx].hexcode.clone();

        match (self.visible_key(db, &src_canon), self.visible_key(db, &tgt_canon)) {
            (_, None) => {
                if let Some(sk) = self.visible_key(db, &src_canon) {
                    self.release_key(db, sk);
                } else {
                    return false;
                }
            }
            (None, Some(VisibleKey::Number(idx))) => self.place_number(db, idx, src_idx),
            (None, Some(VisibleKey::Letter(l))) => self.place_letter(db, l, src_idx),
            (Some(VisibleKey::Number(a)), Some(VisibleKey::Number(b))) => {
                self.numbered_slots.swap(a, b);
            }
            (Some(VisibleKey::Letter(a)), Some(VisibleKey::Letter(b))) => {
                self.swap_letters(a, b, &src_canon, &tgt_canon);
            }
            (Some(VisibleKey::Number(num_i)), Some(VisibleKey::Letter(letter))) => {
                self.swap_number_and_letter(db, num_i, letter, &src_canon, tgt_idx);
            }
            (Some(VisibleKey::Letter(letter)), Some(VisibleKey::Number(num_i))) => {
                self.swap_number_and_letter(db, num_i, letter, &tgt_canon, src_idx);
            }
        }
        self.publish_picker_slots(db);
        true
    }

    pub fn drop_on_unassigned(&mut self, db: &EmojiDatabase, source_hex: &str) -> bool {
        let Some(src_idx) = db.index_of(source_hex) else {
            return false;
        };
        let src_canon = db.all[src_idx].hexcode.clone();
        let Some(sk) = self.visible_key(db, &src_canon) else {
            return false;
        };
        self.release_key(db, sk);
        self.publish_picker_slots(db);
        true
    }

    pub fn drop_onto_empty_number(&mut self, db: &EmojiDatabase, source_hex: &str, index: usize) -> bool {
        if index >= NUMBER_SLOT_COUNT || self.numbered_slots[index].is_some() {
            return false;
        }
        let Some(src_idx) = db.index_of(source_hex) else {
            return false;
        };
        let src_canon = db.all[src_idx].hexcode.clone();
        if let Some(sk) = self.visible_key(db, &src_canon) {
            self.vacate(sk, src_idx, &src_canon);
        }
        self.place_number(db, index, src_idx);
        self.publish_picker_slots(db);
        true
    }

    pub fn drop_onto_empty_letter(&mut self, db: &EmojiDatabase, source_hex: &str, letter: char) -> bool {
        let letter = letter.to_ascii_lowercase();
        if !letter.is_ascii_lowercase() {
            return false;
        }
        let Some(src_idx) = db.index_of(source_hex) else {
            return false;
        };
        let src_canon = db.all[src_idx].hexcode.clone();
        if let Some(sk) = self.visible_key(db, &src_canon) {
            self.vacate(sk, src_idx, &src_canon);
        }
        self.place_letter(db, letter, src_idx);
        self.publish_picker_slots(db);
        true
    }

    fn visible_key(&self, db: &EmojiDatabase, canon_hex: &str) -> Option<VisibleKey> {
        let target_idx = db.index_of(canon_hex)?;
        if let Some(pos) = self.numbered_slots.iter().position(|&s| s == Some(target_idx)) {
            return Some(VisibleKey::Number(pos));
        }
        let &letter = self.letter_bindings.get(canon_hex)?;
        let owner_idx = self.letter_slot_emoji(db, letter)?;
        (owner_idx == target_idx).then_some(VisibleKey::Letter(letter))
    }

    fn release_key(&mut self, db: &EmojiDatabase, key: VisibleKey) {
        match key {
            VisibleKey::Number(idx) => {
                if let Some(e_idx) = self.numbered_slots[idx].take() {
                    self.released_hexes.insert(db.all[e_idx].hexcode.clone());
                }
            }
            VisibleKey::Letter(letter) => {
                let mut to_remove = Vec::new();
                for (hex, &l) in &self.letter_bindings {
                    if l == letter {
                        to_remove.push(hex.clone());
                    }
                }
                for hex in to_remove {
                    self.letter_bindings.remove(&hex);
                    self.released_hexes.insert(hex);
                }
                self.released_letters.insert(letter);
            }
        }
    }

    fn vacate(&mut self, key: VisibleKey, src_idx: usize, src_canon: &str) {
        match key {
            VisibleKey::Number(idx) => {
                if self.numbered_slots[idx] == Some(src_idx) {
                    self.numbered_slots[idx] = None;
                }
            }
            VisibleKey::Letter(letter) => {
                self.letter_bindings.remove(src_canon);
                self.released_letters.insert(letter);
            }
        }
    }

    fn place_number(&mut self, db: &EmojiDatabase, index: usize, emoji_idx: usize) {
        let canon = &db.all[emoji_idx].hexcode;
        if let Some(prev_idx) = self.numbered_slots[index] {
            if prev_idx != emoji_idx {
                let prev_hex = db.all[prev_idx].hexcode.clone();
                self.released_hexes.insert(prev_hex.clone());
                self.letter_bindings.remove(&prev_hex);
            }
        }
        for slot in &mut self.numbered_slots {
            if *slot == Some(emoji_idx) {
                *slot = None;
            }
        }
        self.letter_bindings.remove(canon);
        self.numbered_slots[index] = Some(emoji_idx);
        self.released_hexes.remove(canon);
    }

    fn place_letter(&mut self, db: &EmojiDatabase, letter: char, emoji_idx: usize) {
        let canon = db.all[emoji_idx].hexcode.clone();
        self.strip_letter(letter, &canon);
        for slot in &mut self.numbered_slots {
            if *slot == Some(emoji_idx) {
                *slot = None;
            }
        }
        self.letter_bindings.insert(canon.clone(), letter);
        self.released_hexes.remove(&canon);
        self.released_letters.remove(&letter);
    }

    fn swap_letters(&mut self, left: char, right: char, source_canon: &str, target_canon: &str) {
        self.strip_letter(left, target_canon);
        self.strip_letter(right, source_canon);
        self.letter_bindings.insert(source_canon.to_string(), right);
        self.letter_bindings.insert(target_canon.to_string(), left);
        self.released_hexes.remove(source_canon);
        self.released_hexes.remove(target_canon);
        self.released_letters.remove(&left);
        self.released_letters.remove(&right);
    }

    fn swap_number_and_letter(
        &mut self,
        db: &EmojiDatabase,
        num_idx: usize,
        letter: char,
        number_canon: &str,
        letter_emoji_idx: usize,
    ) {
        let letter_canon = db.all[letter_emoji_idx].hexcode.clone();
        self.strip_letter(letter, number_canon);
        self.letter_bindings.remove(&letter_canon);
        self.letter_bindings.insert(number_canon.to_string(), letter);
        self.numbered_slots[num_idx] = Some(letter_emoji_idx);
        self.released_hexes.remove(number_canon);
        self.released_hexes.remove(&letter_canon);
        self.released_letters.remove(&letter);
    }

    fn strip_letter(&mut self, letter: char, except_owner: &str) {
        let mut to_remove = Vec::new();
        for (hex, &l) in &self.letter_bindings {
            if l == letter && hex != except_owner {
                to_remove.push(hex.clone());
            }
        }
        for hex in to_remove {
            self.letter_bindings.remove(&hex);
            self.released_hexes.insert(hex);
        }
    }

    pub fn export_edits(&self, db: &EmojiDatabase) -> PickerPersistedEdits {
        let numbered_emoji = self
            .numbered_slots
            .iter()
            .map(|opt| opt.map(|i| db.all[i].hexcode.clone()).unwrap_or_default())
            .collect();
        let letter_bindings = self
            .letter_bindings
            .iter()
            .map(|(k, v)| (k.clone(), v.to_string()))
            .collect();
        let mut released_hexes: Vec<String> = self.released_hexes.iter().cloned().collect();
        released_hexes.sort();
        let mut released_letters: Vec<String> =
            self.released_letters.iter().map(|c| c.to_string()).collect();
        released_letters.sort();
        PickerPersistedEdits {
            numbered_emoji,
            letter_bindings,
            released_hexes,
            released_letters,
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum VisibleKey {
    Number(usize),
    Letter(char),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_open() -> PickerModel {
        let db = EmojiDatabase::global();
        PickerModel::open(db, &HashMap::new(), &[], &[], &HashMap::new(), &[], &[], None, true)
    }

    #[test]
    fn opens_with_10_numbers_26_letters_and_at_least_80_slots() {
        let db = EmojiDatabase::global();
        let model = empty_open();
        assert_eq!(model.picker_slots.len().max(MINIMUM_SHORTCUT_SLOTS), model.picker_slots.len());
        assert_eq!(model.picker_slots[0].shortcut, Some('1'));
        assert_eq!(model.picker_slots[9].shortcut, Some('0'));
        assert_eq!(model.picker_slots[10].shortcut, Some('a'));
        assert_eq!(model.picker_slots[35].shortcut, Some('z'));
        assert!(model.emoji_for_shortcut('1').is_some());
        assert!(model.emoji_for_shortcut('a').is_some());
        assert_eq!(model.available_modes(), vec![PickerMode::MostUsed, PickerMode::Recent, PickerMode::All]);
        assert!(db.all[model.emoji_for_shortcut('1').unwrap()].character.len() > 0);
    }

    #[test]
    fn context_suggestions_surface_suggested_tab_only_with_hits() {
        let db = EmojiDatabase::global();
        let model = PickerModel::open(
            db,
            &HashMap::new(),
            &[],
            &[],
            &HashMap::new(),
            &[],
            &[],
            Some("booking airplane flight"),
            true,
        );
        assert!(model.has_context_suggestions());
        assert_eq!(model.mode, PickerMode::Suggested);
        assert_eq!(
            model.available_modes(),
            vec![PickerMode::Suggested, PickerMode::MostUsed, PickerMode::Recent, PickerMode::All]
        );
    }

    #[test]
    fn all_seven_drag_operations_preserve_invariants() {
        let db = EmojiDatabase::global();
        let mut model = empty_open();
        let n0_before = model.numbered_slots[0].unwrap();
        let n1_before = model.numbered_slots[1].unwrap();
        let n0_hex = db.all[n0_before].hexcode.clone();
        let n1_hex = db.all[n1_before].hexcode.clone();

        // 1. number <-> number
        assert!(model.drop_onto_emoji(db, &n0_hex, &n1_hex));
        assert_eq!(model.numbered_slots[0], Some(n1_before));
        assert_eq!(model.numbered_slots[1], Some(n0_before));

        // 2. unkeyed -> number
        let unkeyed_slot = model.picker_slots.iter().find(|s| s.shortcut.is_none()).unwrap().clone();
        let unkeyed_hex = unkeyed_slot.id.clone();
        assert!(model.drop_onto_emoji(db, &unkeyed_hex, &n1_hex));
        assert_eq!(model.numbered_slots[0], db.index_of(&unkeyed_hex));
        assert!(model.released_hexes.contains(&n1_hex));

        // 3. letter <-> letter
        let a_hex = db.all[model.emoji_for_shortcut('a').unwrap()].hexcode.clone();
        let b_hex = db.all[model.emoji_for_shortcut('b').unwrap()].hexcode.clone();
        assert!(model.drop_onto_emoji(db, &a_hex, &b_hex));
        assert_eq!(model.letter_bindings.get(&a_hex).copied(), Some('b'));
        assert_eq!(model.letter_bindings.get(&b_hex).copied(), Some('a'));

        // 4. number <-> letter
        let n1_curr_hex = db.all[model.numbered_slots[1].unwrap()].hexcode.clone();
        assert!(model.drop_onto_emoji(db, &n1_curr_hex, &b_hex));
        assert_eq!(model.letter_bindings.get(&n1_curr_hex).copied(), Some('a'));
        assert_eq!(model.numbered_slots[1], db.index_of(&b_hex));

        // 5. keyed -> unassigned releases key and leaves empty slot
        assert!(model.drop_on_unassigned(db, &b_hex));
        assert_eq!(model.numbered_slots[1], None);
        assert!(model.released_hexes.contains(&b_hex));

        // 6. unkeyed -> empty number
        let another_unkeyed = model.picker_slots.iter().find(|s| s.shortcut.is_none()).unwrap().id.clone();
        assert!(model.drop_onto_empty_number(db, &another_unkeyed, 1));
        assert_eq!(model.numbered_slots[1], db.index_of(&another_unkeyed));

        // 7. release letter -> stays released across empty letter drop check
        assert!(model.drop_on_unassigned(db, &a_hex));
        assert!(model.released_letters.contains(&'b'));
        assert!(model.drop_onto_empty_letter(db, &another_unkeyed, 'b'));
        assert_eq!(model.letter_bindings.get(&another_unkeyed).copied(), Some('b'));
        assert_eq!(model.numbered_slots[1], None);
    }

    #[test]
    fn navigation_search_and_released_slots_behave_deterministically() {
        let db = EmojiDatabase::global();
        let mut model = empty_open();
        model.move_selection(Direction::Down);
        assert_eq!(model.shortcut_selected_index, SHORTCUT_COLUMNS);
        model.move_selection(Direction::Right);
        assert_eq!(model.shortcut_selected_index, SHORTCUT_COLUMNS + 1);

        model.begin_search();
        model.set_query(db, "australia".to_string());
        assert!(model.is_searching());
        assert!(!model.current.is_empty());
        assert_eq!(model.emoji_for_shortcut('1'), None);

        model.select_category(db, EmojiCategory::AnimalsNature);
        assert_eq!(model.mode, PickerMode::All);
        assert!(!model.search_input_active);
        assert!(model.emoji_for_shortcut('1').is_some());
    }
}
