use crate::context::usage_for;
use crate::db::EmojiDatabase;
use std::collections::HashMap;

pub fn stem_token(word: &str) -> Vec<String> {
    let lower = word.to_ascii_lowercase();
    let mut forms = vec![lower.clone()];
    if lower.len() > 5 && lower.ends_with("ing") {
        let base = &lower[..lower.len() - 3];
        forms.push(base.to_string());
        forms.push(format!("{base}e"));
    } else if lower.len() > 4 && lower.ends_with("ied") {
        forms.push(format!("{}y", &lower[..lower.len() - 3]));
    } else if lower.len() > 4 && lower.ends_with("ed") {
        forms.push(lower[..lower.len() - 2].to_string());
        forms.push(lower[..lower.len() - 1].to_string());
    } else if lower.len() > 4 && lower.ends_with("es") {
        forms.push(lower[..lower.len() - 2].to_string());
    } else if lower.len() > 3 && lower.ends_with('s') && !lower.ends_with("ss") {
        forms.push(lower[..lower.len() - 1].to_string());
    }
    forms.sort();
    forms.dedup();
    forms
}

/// Computes a fzy-inspired subsequence match score in `[0.0, +inf)` or `None`.
pub fn fzy_score(needle: &str, haystack: &str) -> Option<f64> {
    let n: Vec<char> = needle.chars().flat_map(|c| c.to_lowercase()).collect();
    let h: Vec<char> = haystack.chars().flat_map(|c| c.to_lowercase()).collect();
    if n.is_empty() {
        return Some(0.0);
    }
    if n.len() > h.len() {
        return None;
    }
    if n.len() == h.len() {
        return (n == h).then_some(1000.0);
    }

    // Subsequence DP greedy-with-gap-penalties is simple, deterministic, and
    // allocates zero matrices per query term.
    let m = n.len();
    let k = h.len();
    let mut match_positions = Vec::with_capacity(m);
    let mut hi = 0usize;
    for &nc in &n {
        let mut found = None;
        while hi < k {
            if h[hi] == nc {
                found = Some(hi);
                hi += 1;
                break;
            }
            hi += 1;
        }
        match_positions.push(found?);
    }

    // Tighten preceding characters against the earliest complete match while
    // keeping the final match position anchored so prefix hits stay tight.
    if m > 1 {
        let mut next_limit = match_positions[m - 1];
        for idx in (0..m - 1).rev() {
            let target = n[idx];
            let mut pos = match_positions[idx];
            while pos + 1 < next_limit {
                pos += 1;
                if h[pos] == target {
                    match_positions[idx] = pos;
                }
            }
            next_limit = match_positions[idx];
        }
    }

    let mut score = 0.0_f64;
    let mut prev: Option<usize> = None;
    for &pos in &match_positions {
        score += 1.0;
        if pos == 0 {
            score += 4.0;
        } else {
            let ch_prev = h[pos - 1];
            if matches!(ch_prev, '_' | '-' | ' ' | ':') {
                score += 3.5;
            }
        }
        if let Some(p) = prev {
            if pos == p + 1 {
                score += 3.0;
            } else {
                score -= (pos - p - 1) as f64 * 0.25;
            }
        }
        prev = Some(pos);
    }
    if match_positions[0] == 0 {
        score += 5.0;
    }
    // Slight preference for shorter exact targets.
    score -= (k - m) as f64 * 0.05;
    Some(score)
}

pub fn search_emojis(
    db: &EmojiDatabase,
    query: &str,
    usage: &HashMap<String, u64>,
    frequency_boost: bool,
    limit: usize,
) -> Vec<usize> {
    let trimmed = query.trim().to_ascii_lowercase();
    if trimmed.is_empty() || limit == 0 {
        return Vec::new();
    }
    let normalized_underscore = trimmed.replace(' ', "_");
    let query_tokens: Vec<Vec<String>> = trimmed
        .split_whitespace()
        .map(stem_token)
        .collect();

    let mut results: Vec<(usize, f64)> = db
        .all
        .iter()
        .enumerate()
        .filter_map(|(idx, emoji)| {
            let mut best: Option<f64> = None;
            let update_best = |best: &mut Option<f64>, score: Option<f64>, weight: f64| {
                if let Some(s) = score {
                    let weighted = s * weight;
                    if best.map_or(true, |b| weighted > b) {
                        *best = Some(weighted);
                    }
                }
            };

            for (sc_i, sc) in emoji.shortcodes.iter().enumerate() {
                let weight = if sc_i == 0 { 1.35 } else { 1.15 };
                if sc == &normalized_underscore || sc == &trimmed {
                    update_best(&mut best, Some(1200.0), weight);
                } else {
                    update_best(&mut best, fzy_score(&normalized_underscore, sc), weight);
                    if normalized_underscore != trimmed {
                        update_best(&mut best, fzy_score(&trimmed, sc), weight);
                    }
                }
            }
            if emoji.label.to_ascii_lowercase() == trimmed {
                update_best(&mut best, Some(1150.0), 1.1);
            } else {
                update_best(&mut best, fzy_score(&trimmed, &emoji.label), 1.0);
            }
            for tag in &emoji.tags {
                if tag == &trimmed {
                    update_best(&mut best, Some(900.0), 0.9);
                } else {
                    update_best(&mut best, fzy_score(&trimmed, tag), 0.8);
                }
            }

            // Stemmed fallback when direct subsequence fails (e.g. "laughing" -> "laugh", "hearts" -> "heart").
            if best.is_none() || query_tokens.len() == 1 {
                for variants in &query_tokens {
                    for v in variants {
                        for sc in &emoji.shortcodes {
                            if sc.contains(v) {
                                update_best(&mut best, Some(if sc == v { 950.0 } else { 12.0 }), 1.05);
                            }
                        }
                        if emoji.label.to_ascii_lowercase().contains(v) {
                            update_best(&mut best, Some(10.0), 0.95);
                        }
                        for tag in &emoji.tags {
                            if tag == v {
                                update_best(&mut best, Some(800.0), 0.85);
                            }
                        }
                    }
                }
            }

            let mut total = best?;
            if frequency_boost {
                let count = usage_for(usage, &emoji.hexcode);
                if count > 0 {
                    total += (1.0 + count as f64).ln() * 6.0;
                }
            }
            Some((idx, total))
        })
        .collect();

    results.sort_by(|a, b| {
        b.1.total_cmp(&a.1)
            .then_with(|| db.all[a.0].order.cmp(&db.all[b.0].order))
    });
    results.truncate(limit);
    results.into_iter().map(|(i, _)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_search_finds_exact_and_stemmed_queries() {
        let db = EmojiDatabase::global();
        let usage = HashMap::new();
        let laugh = search_emojis(db, "laughing", &usage, true, 20);
        assert!(!laugh.is_empty());
        assert!(laugh[..10.min(laugh.len())].iter().any(|&i| db.all[i].character == "😆" || db.all[i].character == "😂"));

        let aus = search_emojis(db, "australia", &usage, true, 10);
        assert!(aus.iter().any(|&i| db.all[i].hexcode == "1F1E6-1F1FA"));

        let rofl = search_emojis(db, "rofl", &usage, true, 10);
        assert_eq!(db.all[rofl[0]].character, "🤣");
    }

    #[test]
    fn fzy_prefix_ranks_above_later_substring() {
        let s_prefix = fzy_score("face", "face_with_tears").unwrap();
        let s_later = fzy_score("face", "smiling_face_with_tears").unwrap();
        assert!(s_prefix > s_later, "{s_prefix} <= {s_later}");
    }

    #[test]
    fn usage_boost_promotes_preferred_match() {
        let db = EmojiDatabase::global();
        let mut usage = HashMap::new();
        usage.insert("1F602".to_string(), 500);
        let res = search_emojis(db, "joy", &usage, true, 10);
        assert_eq!(db.all[res[0]].hexcode, "1F602");
    }
}
