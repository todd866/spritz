use crate::db::{tokenize_words, EmojiDatabase};
use crate::emoji::strip_fe0f;
use std::collections::{HashMap, HashSet};

const STOP_WORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "have", "your", "you", "are", "was",
    "but", "not", "just", "like", "can", "will", "would", "about", "into", "then", "than",
    "what", "when", "where", "how", "why", "its", "it",
];

/// Local keyword matching against shortcodes, label words, and tags.
/// Surrounding text stays strictly in-process.
pub fn match_context(
    db: &EmojiDatabase,
    text: Option<&str>,
    usage: &HashMap<String, u64>,
) -> Vec<usize> {
    let Some(text) = text else {
        return Vec::new();
    };
    if text.trim().is_empty() {
        return Vec::new();
    }
    let stop: HashSet<&str> = STOP_WORDS.iter().copied().collect();
    let words: HashSet<String> = tokenize_words(text)
        .into_iter()
        .filter(|w| w.len() > 1 && !stop.contains(w.as_str()))
        .collect();
    if words.is_empty() {
        return Vec::new();
    }

    let mut scored: Vec<(usize, usize, u64)> = db
        .all
        .iter()
        .enumerate()
        .filter_map(|(idx, emoji)| {
            let fields = &db.context_words[idx];
            let score = words.iter().filter(|w| fields.contains(*w)).count();
            if score == 0 {
                return None;
            }
            let count = usage_for(usage, &emoji.hexcode);
            Some((idx, score, count))
        })
        .collect();

    scored.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| b.2.cmp(&a.2))
            .then_with(|| db.all[a.0].hexcode.cmp(&db.all[b.0].hexcode))
    });
    scored.truncate(8);
    scored.into_iter().map(|(idx, _, _)| idx).collect()
}

pub fn usage_for(usage: &HashMap<String, u64>, hexcode: &str) -> u64 {
    if let Some(&v) = usage.get(hexcode) {
        return v;
    }
    if let Some(stripped) = strip_fe0f(hexcode) {
        if let Some(&v) = usage.get(&stripped) {
            return v;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_matcher_ranks_exact_keyword_hits() {
        let db = EmojiDatabase::global();
        let usage = HashMap::new();
        let hits = match_context(db, Some("booking a flight to sydney tomorrow"), &usage);
        assert!(!hits.is_empty());
        assert!(hits.iter().any(|&i| db.all[i].hexcode == "2708" || db.all[i].shortcodes.iter().any(|s| s.contains("airplane"))));
        assert!(match_context(db, Some("the and for with"), &usage).is_empty());
        assert!(match_context(db, None, &usage).is_empty());
    }
}
