use serde::{Deserialize, Serialize};
use std::borrow::Cow;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SkinTone {
    #[default]
    Default,
    Light,
    MediumLight,
    Medium,
    MediumDark,
    Dark,
}

impl SkinTone {
    pub const ALL: [SkinTone; 6] = [
        SkinTone::Default,
        SkinTone::Light,
        SkinTone::MediumLight,
        SkinTone::Medium,
        SkinTone::MediumDark,
        SkinTone::Dark,
    ];

    pub fn from_str_lossy(raw: &str) -> Self {
        match raw {
            "light" | "Light" => Self::Light,
            "mediumLight" | "medium-light" | "Medium-light" => Self::MediumLight,
            "medium" | "Medium" => Self::Medium,
            "mediumDark" | "medium-dark" | "Medium-dark" => Self::MediumDark,
            "dark" | "Dark" => Self::Dark,
            _ => Self::Default,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Light => "light",
            Self::MediumLight => "mediumLight",
            Self::Medium => "medium",
            Self::MediumDark => "mediumDark",
            Self::Dark => "dark",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Default => "Default",
            Self::Light => "Light",
            Self::MediumLight => "Medium-light",
            Self::Medium => "Medium",
            Self::MediumDark => "Medium-dark",
            Self::Dark => "Dark",
        }
    }

    pub fn modifier_char(self) -> Option<char> {
        match self {
            Self::Default => None,
            Self::Light => Some('\u{1F3FB}'),
            Self::MediumLight => Some('\u{1F3FC}'),
            Self::Medium => Some('\u{1F3FD}'),
            Self::MediumDark => Some('\u{1F3FE}'),
            Self::Dark => Some('\u{1F3FF}'),
        }
    }

    pub fn tone_index(self) -> Option<usize> {
        match self {
            Self::Default => None,
            Self::Light => Some(0),
            Self::MediumLight => Some(1),
            Self::Medium => Some(2),
            Self::MediumDark => Some(3),
            Self::Dark => Some(4),
        }
    }

    pub fn swatch_emoji(self) -> String {
        match self.modifier_char() {
            Some(m) => format!("\u{1F596}{m}"),
            None => "\u{1F596}".to_string(),
        }
    }
}

/// Inserts a skin-tone modifier after the first scalar (replacing `\u{FE0F}` at
/// position 1 if present) per UTS #51 for ZWJ/single-scalar base emojis.
pub fn apply_skin_tone_fallback(character: &str, tone: SkinTone) -> String {
    let Some(modifier) = tone.modifier_char() else {
        return character.to_string();
    };
    let mut chars = character.chars();
    let Some(first) = chars.next() else {
        return character.to_string();
    };
    let mut out = String::with_capacity(character.len() + 4);
    out.push(first);
    out.push(modifier);
    let rest: Vec<char> = chars.collect();
    if let Some((&second, tail)) = rest.split_first() {
        if second != '\u{FE0F}' {
            out.push(second);
        }
        for &c in tail {
            out.push(c);
        }
    }
    out
}

/// Uppercase `-`-joined hexcode validation.
pub fn canonical_hex(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    for seg in value.split('-') {
        if seg.is_empty() || !seg.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        parts.push(seg.to_ascii_uppercase());
    }
    Some(parts.join("-"))
}

/// Canonical uppercase hex with `-FE0F` presentation selectors stripped.
pub fn strip_fe0f(value: &str) -> Option<String> {
    let canon = canonical_hex(value)?;
    let filtered: Vec<&str> = canon.split('-').filter(|&seg| seg != "FE0F").collect();
    if filtered.is_empty() {
        Some(canon)
    } else {
        Some(filtered.join("-"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EmojiCategory {
    SmileysPeople,
    AnimalsNature,
    FoodDrink,
    TravelPlaces,
    Activities,
    Objects,
    Symbols,
    Flags,
}

impl EmojiCategory {
    pub const ALL: [EmojiCategory; 8] = [
        Self::SmileysPeople,
        Self::AnimalsNature,
        Self::FoodDrink,
        Self::TravelPlaces,
        Self::Activities,
        Self::Objects,
        Self::Symbols,
        Self::Flags,
    ];

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "smileysPeople" => Some(Self::SmileysPeople),
            "animalsNature" => Some(Self::AnimalsNature),
            "foodDrink" => Some(Self::FoodDrink),
            "travelPlaces" => Some(Self::TravelPlaces),
            "activities" => Some(Self::Activities),
            "objects" => Some(Self::Objects),
            "symbols" => Some(Self::Symbols),
            "flags" => Some(Self::Flags),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::SmileysPeople => "smileysPeople",
            Self::AnimalsNature => "animalsNature",
            Self::FoodDrink => "foodDrink",
            Self::TravelPlaces => "travelPlaces",
            Self::Activities => "activities",
            Self::Objects => "objects",
            Self::Symbols => "symbols",
            Self::Flags => "flags",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::SmileysPeople => "Smileys & People",
            Self::AnimalsNature => "Animals & Nature",
            Self::FoodDrink => "Food & Drink",
            Self::TravelPlaces => "Travel & Places",
            Self::Activities => "Activities",
            Self::Objects => "Objects",
            Self::Symbols => "Symbols",
            Self::Flags => "Flags",
        }
    }

    pub fn tab_symbol(self) -> &'static str {
        match self {
            Self::SmileysPeople => "face.smiling",
            Self::AnimalsNature => "leaf",
            Self::FoodDrink => "fork.knife",
            Self::TravelPlaces => "airplane",
            Self::Activities => "basketball",
            Self::Objects => "lightbulb",
            Self::Symbols => "number",
            Self::Flags => "flag",
        }
    }

    pub fn matches_group(self, group: i32) -> bool {
        match self {
            Self::SmileysPeople => group == 0 || group == 1,
            Self::AnimalsNature => group == 3,
            Self::FoodDrink => group == 4,
            Self::TravelPlaces => group == 5,
            Self::Activities => group == 6,
            Self::Objects => group == 7,
            Self::Symbols => group == 8,
            Self::Flags => group == 9,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Emoji {
    pub hexcode: String,
    pub character: String,
    pub label: String,
    pub shortcodes: Vec<String>,
    pub tags: Vec<String>,
    pub group: i32,
    pub order: i32,
    pub skins: Option<[String; 5]>,
}

impl Emoji {
    pub fn primary_shortcode(&self) -> &str {
        self.shortcodes
            .first()
            .map(String::as_str)
            .unwrap_or(&self.label)
    }

    /// Returns the Unicode glyph for `tone`, using precomputed CLDR skins when
    /// available and leaving non-toneable emojis unchanged.
    pub fn toned_glyph(&self, tone: SkinTone) -> Cow<'_, str> {
        let Some(idx) = tone.tone_index() else {
            return Cow::Borrowed(&self.character);
        };
        if let Some(skins) = &self.skins {
            Cow::Borrowed(&skins[idx])
        } else {
            Cow::Borrowed(&self.character)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_and_fe0f_normalization() {
        assert_eq!(canonical_hex("1f937-200d-2642-fe0f").as_deref(), Some("1F937-200D-2642-FE0F"));
        assert_eq!(canonical_hex("not hex!"), None);
        assert_eq!(strip_fe0f("2764-fe0f").as_deref(), Some("2764"));
        assert_eq!(strip_fe0f("1f3f4-200d-2620-fe0f").as_deref(), Some("1F3F4-200D-2620"));
    }

    #[test]
    fn skin_tone_zwj_fallback() {
        assert_eq!(apply_skin_tone_fallback("👋", SkinTone::Dark), "👋🏿");
        assert_eq!(apply_skin_tone_fallback("👍️", SkinTone::Light), "👍🏻");
        assert_eq!(apply_skin_tone_fallback("🧔‍♀️", SkinTone::Dark), "🧔🏿‍♀️");
        assert_eq!(apply_skin_tone_fallback("😀", SkinTone::Default), "😀");
    }
}
