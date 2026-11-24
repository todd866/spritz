use crate::emoji::{canonical_hex, strip_fe0f, Emoji, EmojiCategory};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

const EMOJIBASE_JSON: &str = include_str!("../data/emojibase-en.json");

#[derive(Deserialize)]
struct RawRecord {
    h: String,
    e: String,
    n: String,
    #[serde(default)]
    s: Vec<String>,
    #[serde(default)]
    t: Vec<String>,
    g: i32,
    o: i32,
    #[serde(default)]
    sk: Option<[String; 5]>,
}

#[derive(Debug, Clone)]
pub struct CategorySection {
    pub category: EmojiCategory,
    pub indices: Vec<usize>,
}

#[derive(Debug)]
pub struct EmojiDatabase {
    pub all: Vec<Emoji>,
    by_hex: HashMap<String, usize>,
    by_hex_no_fe0f: HashMap<String, usize>,
    pub context_words: Vec<HashSet<String>>,
    pub sections: Vec<CategorySection>,
}

static GLOBAL_DB: OnceLock<EmojiDatabase> = OnceLock::new();

impl EmojiDatabase {
    pub fn global() -> &'static EmojiDatabase {
        GLOBAL_DB.get_or_init(Self::load_embedded)
    }

    pub fn load_embedded() -> Self {
        Self::from_json_str(EMOJIBASE_JSON).expect("embedded emojibase-en.json must be valid")
    }

    pub fn from_json_str(json: &str) -> Result<Self, serde_json::Error> {
        let records: Vec<RawRecord> = serde_json::from_str(json)?;
        let mut emojis: Vec<Emoji> = records
            .into_iter()
            .filter_map(|r| {
                let hex = canonical_hex(&r.h)?;
                Some(Emoji {
                    hexcode: hex,
                    character: r.e,
                    label: r.n,
                    shortcodes: r.s,
                    tags: r.t,
                    group: r.g,
                    order: r.o,
                    skins: r.sk,
                })
            })
            .collect();

        emojis.sort_by(|a, b| a.order.cmp(&b.order).then_with(|| a.hexcode.cmp(&b.hexcode)));

        let mut by_hex = HashMap::with_capacity(emojis.len());
        let mut by_hex_no_fe0f = HashMap::with_capacity(emojis.len());
        let mut context_words = Vec::with_capacity(emojis.len());

        for (idx, emoji) in emojis.iter().enumerate() {
            by_hex.insert(emoji.hexcode.clone(), idx);
            if let Some(stripped) = strip_fe0f(&emoji.hexcode) {
                by_hex_no_fe0f.entry(stripped).or_insert(idx);
            }
            context_words.push(build_context_words(emoji));
        }

        let mut sections = Vec::with_capacity(EmojiCategory::ALL.len());
        for category in EmojiCategory::ALL {
            let indices: Vec<usize> = emojis
                .iter()
                .enumerate()
                .filter_map(|(idx, e)| category.matches_group(e.group).then_some(idx))
                .collect();
            if !indices.is_empty() {
                sections.push(CategorySection { category, indices });
            }
        }

        Ok(Self {
            all: emojis,
            by_hex,
            by_hex_no_fe0f,
            context_words,
            sections,
        })
    }

    /// Resolves canonical or FE0F-variant hexcodes cleanly.
    pub fn index_of(&self, hex: &str) -> Option<usize> {
        let canon = canonical_hex(hex)?;
        if let Some(&idx) = self.by_hex.get(&canon) {
            return Some(idx);
        }
        let stripped = strip_fe0f(&canon)?;
        self.by_hex_no_fe0f.get(&stripped).copied()
    }

    pub fn get(&self, hex: &str) -> Option<&Emoji> {
        self.index_of(hex).map(|i| &self.all[i])
    }

    pub fn canonical_hex_for(&self, hex: &str) -> Option<&str> {
        self.get(hex).map(|e| e.hexcode.as_str())
    }
}

pub fn tokenize_words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

fn build_context_words(emoji: &Emoji) -> HashSet<String> {
    let mut out = HashSet::new();
    for w in tokenize_words(&emoji.label) {
        if w.len() > 1 {
            out.insert(w);
        }
    }
    for sc in &emoji.shortcodes {
        for w in tokenize_words(sc) {
            if w.len() > 1 {
                out.insert(w);
            }
        }
    }
    for tag in &emoji.tags {
        for w in tokenize_words(tag) {
            if w.len() > 1 {
                out.insert(w);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emoji::SkinTone;

    #[test]
    fn embedded_database_loads_and_resolves_fe0f_variants() {
        let db = EmojiDatabase::global();
        assert!(db.all.len() > 1800);
        assert_eq!(db.get("1F602").map(|e| e.character.as_str()), Some("😂"));
        // Both FE0F and stripped forms resolve to the same catalog entry.
        assert_eq!(db.index_of("2764"), db.index_of("2764-FE0F"));
        assert_eq!(db.index_of("2708"), db.index_of("2708-FE0F"));
        let shrug = db.get("1F937-200D-2642-FE0F").expect("man shrugging");
        assert_eq!(shrug.toned_glyph(SkinTone::Light).as_ref(), "🤷🏻‍♂️");
        let pirate = db.get("1F3F4-200D-2620").expect("pirate flag via stripped FE0F");
        assert_eq!(pirate.character, "🏴‍☠️");
    }
}
