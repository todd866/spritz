use crate::context::match_context;
use crate::db::EmojiDatabase;
use crate::emoji::SkinTone;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::OnceLock;

const LEXICON_TXT: &str = include_str!("../data/lexicon-en.txt");
const GLIDE_SAMPLES: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum EnglishVariant {
    #[default]
    Au,
    Uk,
    Us,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum AutocorrectMode {
    Off,
    #[default]
    Gentle,
    Smart,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ShiftState {
    #[default]
    Off,
    Once,
    CapsLock,
}

impl ShiftState {
    pub fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::Once,
            2 => Self::CapsLock,
            _ => Self::Off,
        }
    }

    pub fn as_i32(self) -> i32 {
        match self {
            Self::Off => 0,
            Self::Once => 1,
            Self::CapsLock => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum KeyboardLayer {
    #[default]
    Letters,
    Numbers,
    Symbols,
    Emoji,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct KeyboardConfig {
    pub number_row: bool,
    pub key_flicks: bool,
    pub glide_typing: bool,
    pub autocorrect: AutocorrectMode,
    pub english_variant: EnglishVariant,
    pub haptics: bool,
    pub auto_caps: bool,
    pub double_space_period: bool,
    pub skin_tone: SkinTone,
    pub snippets: BTreeMap<String, String>,
    pub personal_words: Vec<String>,
    pub rejected_corrections: BTreeMap<String, String>,
}

impl Default for KeyboardConfig {
    fn default() -> Self {
        let mut snippets = BTreeMap::new();
        snippets.insert("/shrug".to_string(), r#"¯\_(ツ)_/¯"#.to_string());
        snippets.insert("/check".to_string(), "✓".to_string());
        snippets.insert("/arrow".to_string(), "→".to_string());
        snippets.insert("/deg".to_string(), "°".to_string());
        snippets.insert("/tm".to_string(), "™".to_string());
        Self {
            number_row: true,
            key_flicks: true,
            glide_typing: true,
            autocorrect: AutocorrectMode::Gentle,
            english_variant: EnglishVariant::Au,
            haptics: true,
            auto_caps: true,
            double_space_period: true,
            skin_tone: SkinTone::Default,
            snippets,
            personal_words: Vec::new(),
            rejected_corrections: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CandidateKind {
    Literal,
    Correction,
    Completion,
    Prediction,
    Snippet,
    Glide,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateItem {
    pub text: String,
    pub kind: CandidateKind,
    pub auto_commit: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmojiHint {
    pub hex: String,
    pub glyph: String,
    pub label: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextEdit {
    pub delete_backward: usize,
    pub insert: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyboardOutput {
    pub edit: TextEdit,
    pub candidates: Vec<CandidateItem>,
    pub emoji_hints: Vec<EmojiHint>,
    pub undo_word: Option<String>,
    pub shift_state: ShiftState,
    pub auto_space_active: bool,
}

/// Normalized `[0..1] x [0..1]` staggered iPhone QWERTY key centers.
pub struct QwertyGeometry;

impl QwertyGeometry {
    const ROW_1: &'static str = "qwertyuiop";
    const ROW_2: &'static str = "asdfghjkl";
    const ROW_3: &'static str = "zxcvbnm";

    pub fn key_center(ch: char) -> Option<(f32, f32)> {
        let lower = ch.to_ascii_lowercase();
        if let Some(i) = Self::ROW_1.find(lower) {
            return Some(((i as f32 + 0.5) / 10.0, 0.16));
        }
        if let Some(i) = Self::ROW_2.find(lower) {
            return Some(((i as f32 + 1.0) / 10.0, 0.50));
        }
        if let Some(i) = Self::ROW_3.find(lower) {
            return Some(((i as f32 + 2.0) / 10.0, 0.84));
        }
        None
    }

    /// Distance in key-width units (1.0 ≈ distance between two neighboring keys).
    pub fn key_distance(a: char, b: char) -> f32 {
        let la = a.to_ascii_lowercase();
        let lb = b.to_ascii_lowercase();
        if la == lb {
            return 0.0;
        }
        match (Self::key_center(la), Self::key_center(lb)) {
            (Some((ax, ay)), Some((bx, by))) => {
                let dx = (ax - bx) * 10.0;
                let dy = (ay - by) * 3.0;
                dx.hypot(dy)
            }
            _ => 4.0,
        }
    }

    /// Aspect-compensated Euclidean distance between normalized `[0..1]` points.
    #[inline]
    fn norm_dist(ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
        let dx = ax - bx;
        let dy = (ay - by) * 0.45;
        dx.hypot(dy)
    }

    pub fn nearby_keys(x: f32, y: f32, radius: f32) -> Vec<(char, f32)> {
        let mut out = Vec::new();
        for ch in 'a'..='z' {
            if let Some((kx, ky)) = Self::key_center(ch) {
                let raw_d = (x - kx).hypot(y - ky);
                let adj_d = Self::norm_dist(x, y, kx, ky);
                let d = raw_d.min(adj_d);
                if d <= radius {
                    out.push((ch, adj_d));
                }
            }
        }
        out.sort_by(|a, b| a.1.total_cmp(&b.1));
        out
    }
}

pub struct Lexicon {
    pub words: Vec<&'static str>,
    pub lower_words: Vec<String>,
    pub exact: HashMap<String, u32>,
    pub by_len: [Vec<u32>; 22],
    pub by_endpoints: Vec<Vec<u32>>,
    contractions: HashMap<&'static str, &'static str>,
    au_uk_set: HashSet<&'static str>,
    us_to_au_uk: HashMap<&'static str, &'static str>,
    au_uk_to_us: HashMap<&'static str, &'static str>,
    bigrams: HashMap<&'static str, Vec<&'static str>>,
}

static GLOBAL_LEXICON: OnceLock<Lexicon> = OnceLock::new();

impl Lexicon {
    pub fn global() -> &'static Lexicon {
        GLOBAL_LEXICON.get_or_init(Self::load_embedded)
    }

    pub fn load_embedded() -> Self {
        let mut words: Vec<&'static str> = Vec::with_capacity(23_000);
        let mut lower_words: Vec<String> = Vec::with_capacity(23_000);
        let mut exact: HashMap<String, u32> = HashMap::with_capacity(23_000);
        let mut by_len: [Vec<u32>; 22] = std::array::from_fn(|_| Vec::new());
        let mut by_endpoints: Vec<Vec<u32>> = vec![Vec::new(); 26 * 26];

        for line in LEXICON_TXT.lines() {
            let w = line.trim();
            if w.is_empty() {
                continue;
            }
            let lower = w.to_ascii_lowercase();
            if exact.contains_key(&lower) {
                continue;
            }
            let idx = words.len() as u32;
            let len = lower.len();
            words.push(w);
            exact.insert(lower.clone(), idx);
            if len < by_len.len() {
                by_len[len].push(idx);
            }
            if let Some((f, l)) = alpha_endpoints(&lower) {
                let bucket = endpoint_index(f, l);
                by_endpoints[bucket].push(idx);
            }
            lower_words.push(lower);
        }

        let contractions = build_contractions();
        let (au_uk_set, us_to_au_uk, au_uk_to_us) = build_variant_maps();
        let bigrams = build_bigrams();

        Self {
            words,
            lower_words,
            exact,
            by_len,
            by_endpoints,
            contractions,
            au_uk_set,
            us_to_au_uk,
            au_uk_to_us,
            bigrams,
        }
    }

    #[inline]
    pub fn freq_prior(&self, rank: u32) -> f32 {
        1.0 / (2.5 + ((rank as f32) + 8.0).ln())
    }

    pub fn is_known_word(
        &self,
        lower: &str,
        variant: EnglishVariant,
        personal_words: &[String],
    ) -> bool {
        if self.contractions.contains_key(lower) {
            return false;
        }
        if personal_words
            .iter()
            .any(|w| w.eq_ignore_ascii_case(lower))
        {
            return true;
        }
        if variant != EnglishVariant::Us && self.au_uk_set.contains(lower) {
            return true;
        }
        self.exact.contains_key(lower)
    }

    pub fn preferred_variant_for(&self, lower: &str, variant: EnglishVariant) -> Option<&'static str> {
        match variant {
            EnglishVariant::Au | EnglishVariant::Uk => self.us_to_au_uk.get(lower).copied(),
            EnglishVariant::Us => self.au_uk_to_us.get(lower).copied(),
        }
    }

    pub fn bigram_predictions(&self, prev_word: &str) -> Vec<String> {
        let low = prev_word.to_ascii_lowercase();
        if let Some(list) = self.bigrams.get(low.as_str()) {
            list.iter().take(3).map(|s| (*s).to_string()).collect()
        } else {
            vec!["the".to_string(), "to".to_string(), "and".to_string()]
        }
    }
}

#[inline]
fn alpha_endpoints(word: &str) -> Option<(u8, u8)> {
    let bytes: Vec<u8> = word.bytes().filter(|b| b.is_ascii_lowercase()).collect();
    if bytes.is_empty() {
        return None;
    }
    Some((bytes[0] - b'a', bytes[bytes.len() - 1] - b'a'))
}

#[inline]
fn endpoint_index(first: u8, last: u8) -> usize {
    (first as usize) * 26 + (last as usize)
}

fn apply_word_casing(template: &str, replacement: &str, shift: ShiftState) -> String {
    if replacement.starts_with("I'") || replacement == "I" {
        if shift == ShiftState::CapsLock
            || (template.len() > 1 && template.chars().all(|c| c.is_ascii_uppercase()))
        {
            return replacement.to_ascii_uppercase();
        }
        return replacement.to_string();
    }
    if shift == ShiftState::CapsLock
        || (template.len() >= 2 && template.chars().all(|c| !c.is_ascii_alphabetic() || c.is_ascii_uppercase()))
    {
        return replacement.to_ascii_uppercase();
    }
    let first_upper = template
        .chars()
        .next()
        .map_or(false, |c| c.is_ascii_uppercase())
        || shift == ShiftState::Once;
    if first_upper {
        capitalize_first(replacement)
    } else {
        replacement.to_string()
    }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => {
            let mut out = String::with_capacity(s.len());
            out.extend(c.to_uppercase());
            out.push_str(chars.as_str());
            out
        }
        None => String::new(),
    }
}

/// Spatial-weighted Damerau-Levenshtein distance capped near `max_cost`.
fn spatial_damerau_distance(typed: &str, cand: &str, max_cost: f32) -> f32 {
    let a: Vec<char> = typed.chars().collect();
    let b: Vec<char> = cand.chars().collect();
    let m = a.len();
    let n = b.len();
    if m == 0 {
        return n as f32;
    }
    if n == 0 {
        return m as f32;
    }
    if m.abs_diff(n) > 2 {
        return max_cost + 1.0;
    }

    let width = n + 1;
    let mut dp = vec![max_cost + 2.0; (m + 1) * width];
    dp[0] = 0.0;
    for i in 1..=m {
        dp[i * width] = (i as f32) * 0.85;
    }
    for j in 1..=n {
        dp[j] = (j as f32) * 0.85;
    }

    for i in 1..=m {
        let mut row_min = f32::MAX;
        for j in 1..=n {
            let sub_cost = if a[i - 1] == b[j - 1] {
                0.0
            } else {
                let kd = QwertyGeometry::key_distance(a[i - 1], b[j - 1]);
                if kd <= 1.25 {
                    0.36
                } else if kd <= 1.9 {
                    0.56
                } else {
                    1.0
                }
            };
            let mut best = (dp[(i - 1) * width + j] + 0.82)
                .min(dp[i * width + (j - 1)] + 0.82)
                .min(dp[(i - 1) * width + (j - 1)] + sub_cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                best = best.min(dp[(i - 2) * width + (j - 2)] + 0.42);
            }
            dp[i * width + j] = best;
            row_min = row_min.min(best);
        }
        if row_min > max_cost + 0.9 {
            return max_cost + 1.0;
        }
    }

    dp[m * width + n]
}

fn tap_touch_penalty(tap_points: &[(f32, f32)], cand: &str) -> f32 {
    if tap_points.is_empty() {
        return 0.0;
    }
    let cchars: Vec<char> = cand.chars().filter(|c| c.is_ascii_alphabetic()).collect();
    if tap_points.len() != cchars.len() {
        return 0.0;
    }
    let mut sum = 0.0f32;
    for (&(tx, ty), &ch) in tap_points.iter().zip(cchars.iter()) {
        if let Some((kx, ky)) = QwertyGeometry::key_center(ch) {
            sum += QwertyGeometry::norm_dist(tx, ty, kx, ky);
        }
    }
    sum / (cchars.len() as f32)
}

pub fn suggest_for_word(
    word: &str,
    tap_points: &[(f32, f32)],
    config: &KeyboardConfig,
    shift: ShiftState,
) -> Vec<CandidateItem> {
    if word.is_empty() {
        return Vec::new();
    }
    let lex = Lexicon::global();
    let lower = word.to_ascii_lowercase();

    if let Some(expansion) = config.snippets.get(word).or_else(|| config.snippets.get(&lower)) {
        return vec![
            CandidateItem {
                text: word.to_string(),
                kind: CandidateKind::Literal,
                auto_commit: false,
            },
            CandidateItem {
                text: expansion.clone(),
                kind: CandidateKind::Snippet,
                auto_commit: config.autocorrect != AutocorrectMode::Off,
            },
        ];
    }

    if let Some(&contracted) = lex.contractions.get(lower.as_str()) {
        let rejected = config
            .rejected_corrections
            .get(&lower)
            .map_or(false, |r| r.eq_ignore_ascii_case(contracted));
        if !rejected {
            let formatted = apply_word_casing(word, contracted, shift);
            return vec![
                CandidateItem {
                    text: word.to_string(),
                    kind: CandidateKind::Literal,
                    auto_commit: false,
                },
                CandidateItem {
                    text: formatted,
                    kind: CandidateKind::Correction,
                    auto_commit: config.autocorrect != AutocorrectMode::Off,
                },
            ];
        }
    }

    let known = lex.is_known_word(&lower, config.english_variant, &config.personal_words);
    let mut completions: Vec<(String, u32)> = Vec::new();
    if lower.len() >= 2 && lower.chars().all(|c| c.is_ascii_alphabetic()) {
        for (i, lw) in lex.lower_words.iter().enumerate() {
            if lw.len() > lower.len() && lw.starts_with(&lower) {
                completions.push((lex.words[i].to_string(), i as u32));
                if completions.len() >= 24 {
                    break;
                }
            }
        }
        completions.sort_by_key(|c| c.1);
    }

    let mut corrections: Vec<(String, f32)> = Vec::new();
    if lower.len() >= 2 && lower.chars().all(|c| c.is_ascii_alphabetic()) {
        let max_cost = if lower.len() <= 3 { 0.88 } else { 1.45 };
        let min_len = lower.len().saturating_sub(2).max(2);
        let max_len = (lower.len() + 2).min(lex.by_len.len() - 1);

        for l in min_len..=max_len {
            for &idx in &lex.by_len[l] {
                let lw = &lex.lower_words[idx as usize];
                if lw == &lower {
                    continue;
                }
                if lex.contractions.contains_key(lw.as_str()) {
                    continue;
                }
                if let Some(rej) = config.rejected_corrections.get(&lower) {
                    if rej.eq_ignore_ascii_case(lw) {
                        continue;
                    }
                }
                let dist = spatial_damerau_distance(&lower, lw, max_cost);
                if dist <= max_cost {
                    let freq = lex.freq_prior(idx);
                    let variant_bonus = match config.english_variant {
                        EnglishVariant::Au | EnglishVariant::Uk => {
                            if lex.au_uk_set.contains(lw.as_str()) {
                                0.35
                            } else if lex.us_to_au_uk.contains_key(lw.as_str()) {
                                -0.30
                            } else {
                                0.0
                            }
                        }
                        EnglishVariant::Us => {
                            if lex.au_uk_to_us.contains_key(lw.as_str()) {
                                -0.25
                            } else {
                                0.0
                            }
                        }
                    };
                    let touch_pen = tap_touch_penalty(tap_points, lw);
                    let score = dist + touch_pen * 1.6 - freq * 0.75 - variant_bonus;
                    corrections.push((lex.words[idx as usize].to_string(), score));
                }
            }
        }
        for pw in &config.personal_words {
            let lp = pw.to_ascii_lowercase();
            if lp == lower {
                continue;
            }
            let dist = spatial_damerau_distance(&lower, &lp, max_cost);
            if dist <= max_cost {
                let touch_pen = tap_touch_penalty(tap_points, &lp);
                corrections.push((pw.clone(), dist + touch_pen * 1.4 - 0.32));
            }
        }
        corrections.sort_by(|a, b| a.1.total_cmp(&b.1));
    }

    let mut out = vec![CandidateItem {
        text: word.to_string(),
        kind: CandidateKind::Literal,
        auto_commit: false,
    }];
    let mut seen: HashSet<String> = HashSet::new();
    seen.insert(word.to_ascii_lowercase());

    if known {
        if let Some(alt_variant) = lex.preferred_variant_for(&lower, config.english_variant) {
            if seen.insert(alt_variant.to_ascii_lowercase()) {
                out.push(CandidateItem {
                    text: apply_word_casing(word, alt_variant, shift),
                    kind: CandidateKind::Completion,
                    auto_commit: false,
                });
            }
        }
        for (comp, _) in completions {
            if seen.insert(comp.to_ascii_lowercase()) {
                out.push(CandidateItem {
                    text: apply_word_casing(word, &comp, shift),
                    kind: CandidateKind::Completion,
                    auto_commit: false,
                });
                if out.len() >= 3 {
                    break;
                }
            }
        }
        if out.len() < 3 {
            for (corr, _) in corrections {
                if seen.insert(corr.to_ascii_lowercase()) {
                    out.push(CandidateItem {
                        text: apply_word_casing(word, &corr, shift),
                        kind: CandidateKind::Correction,
                        auto_commit: false,
                    });
                    if out.len() >= 3 {
                        break;
                    }
                }
            }
        }
        return out;
    }

    // Unknown word: consider corrections first, then prefix completions.
    let top_margin = corrections
        .get(1)
        .map_or(f32::MAX, |second| second.1 - corrections[0].1);
    let long_unambiguous_typo =
        lower.len() >= 6 && top_margin >= 0.20;
    let commit_threshold = match config.autocorrect {
        AutocorrectMode::Off => f32::NEG_INFINITY,
        AutocorrectMode::Gentle => {
            if long_unambiguous_typo {
                0.96
            } else {
                0.72
            }
        }
        AutocorrectMode::Smart => 1.10,
    };

    for (i, (corr, score)) in corrections.into_iter().enumerate() {
        if seen.insert(corr.to_ascii_lowercase()) {
            let auto_commit = i == 0
                && config.autocorrect != AutocorrectMode::Off
                && score <= commit_threshold;
            out.push(CandidateItem {
                text: apply_word_casing(word, &corr, shift),
                kind: CandidateKind::Correction,
                auto_commit,
            });
            if out.len() >= 3 {
                return out;
            }
        }
    }

    for (comp, _) in completions {
        if seen.insert(comp.to_ascii_lowercase()) {
            out.push(CandidateItem {
                text: apply_word_casing(word, &comp, shift),
                kind: CandidateKind::Completion,
                auto_commit: false,
            });
            if out.len() >= 3 {
                break;
            }
        }
    }

    out
}

fn resample_path(points: &[(f32, f32)], n: usize) -> Vec<(f32, f32)> {
    if points.is_empty() || n == 0 {
        return Vec::new();
    }
    if points.len() == 1 {
        return vec![points[0]; n];
    }
    let mut cum = Vec::with_capacity(points.len());
    cum.push(0.0f32);
    let mut total = 0.0f32;
    for w in points.windows(2) {
        let d = (w[1].0 - w[0].0).hypot(w[1].1 - w[0].1);
        total += d;
        cum.push(total);
    }
    if total <= 1e-6 {
        return vec![points[0]; n];
    }
    let mut out = Vec::with_capacity(n);
    let mut seg = 0usize;
    for k in 0..n {
        let target = if n == 1 {
            0.0
        } else {
            total * (k as f32) / ((n - 1) as f32)
        };
        while seg + 1 < cum.len() - 1 && cum[seg + 1] < target {
            seg += 1;
        }
        let s0 = cum[seg];
        let s1 = cum[seg + 1];
        let t = if s1 > s0 + 1e-6 {
            ((target - s0) / (s1 - s0)).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let p0 = points[seg];
        let p1 = points[seg + 1];
        out.push((p0.0 + (p1.0 - p0.0) * t, p0.1 + (p1.1 - p0.1) * t));
    }
    out
}

fn path_length_adj(points: &[(f32, f32)]) -> f32 {
    points
        .windows(2)
        .map(|w| QwertyGeometry::norm_dist(w[0].0, w[0].1, w[1].0, w[1].1))
        .sum()
}

fn word_key_points(word: &str) -> Option<Vec<(f32, f32)>> {
    let mut pts = Vec::with_capacity(word.len());
    let mut prev: Option<char> = None;
    for ch in word.chars() {
        if !ch.is_ascii_alphabetic() {
            continue;
        }
        let lc = ch.to_ascii_lowercase();
        if prev == Some(lc) {
            continue;
        }
        prev = Some(lc);
        pts.push(QwertyGeometry::key_center(lc)?);
    }
    if pts.is_empty() {
        None
    } else {
        Some(pts)
    }
}

pub fn decode_glide(
    points: &[(f32, f32)],
    prev_word: Option<&str>,
    config: &KeyboardConfig,
    shift: ShiftState,
) -> Vec<String> {
    if points.len() < 2 {
        return Vec::new();
    }
    let resampled = resample_path(points, GLIDE_SAMPLES);
    if resampled.len() < 2 {
        return Vec::new();
    }
    let user_len = path_length_adj(&resampled);
    if user_len < 0.04 {
        return Vec::new();
    }

    let start_pt = resampled[0];
    let end_pt = resampled[resampled.len() - 1];
    let start_keys = QwertyGeometry::nearby_keys(start_pt.0, start_pt.1, 0.22);
    let end_keys = QwertyGeometry::nearby_keys(end_pt.0, end_pt.1, 0.22);
    if start_keys.is_empty() || end_keys.is_empty() {
        return Vec::new();
    }

    let lex = Lexicon::global();
    let bigram_set: HashSet<&str> = prev_word
        .and_then(|p| lex.bigrams.get(p.to_ascii_lowercase().as_str()))
        .map(|v| v.iter().copied().collect())
        .unwrap_or_default();

    let mut scored: Vec<(String, f32)> = Vec::new();
    let mut seen_lower: HashSet<String> = HashSet::new();

    for &(sc, sd) in start_keys.iter().take(4) {
        let f = (sc as u8) - b'a';
        for &(ec, ed) in end_keys.iter().take(4) {
            let l = (ec as u8) - b'a';
            let endpoint_pen = (sd + ed) * 0.55;
            for &idx in &lex.by_endpoints[endpoint_index(f, l)] {
                let lw = &lex.lower_words[idx as usize];
                if lw.len() < 2 || lex.contractions.contains_key(lw.as_str()) {
                    continue;
                }
                let Some(key_pts) = word_key_points(lw) else {
                    continue;
                };
                if key_pts.len() < 2 {
                    continue;
                }
                let ideal = resample_path(&key_pts, GLIDE_SAMPLES);
                let ideal_len = path_length_adj(&ideal);

                // Mean polyline shape distance in aspect-adjusted coordinates.
                let mut sum_d = 0.0f32;
                for (up, ip) in resampled.iter().zip(ideal.iter()) {
                    sum_d += QwertyGeometry::norm_dist(up.0, up.1, ip.0, ip.1);
                }
                let mean_d = sum_d / (GLIDE_SAMPLES as f32);
                if mean_d > 0.24 {
                    continue;
                }

                // Ordered checkpoint distance: verify touch path visits each unique key in sequence.
                let mut cursor = 0usize;
                let mut missed_key_pen = 0.0f32;
                for &(kx, ky) in &key_pts {
                    let mut best_k = cursor;
                    let mut best_kd = f32::MAX;
                    for k in cursor..GLIDE_SAMPLES {
                        let d = QwertyGeometry::norm_dist(resampled[k].0, resampled[k].1, kx, ky);
                        if d < best_kd {
                            best_kd = d;
                            best_k = k;
                        }
                    }
                    cursor = best_k;
                    missed_key_pen += best_kd;
                }
                missed_key_pen /= key_pts.len() as f32;

                let len_diff = (user_len - ideal_len).abs() / user_len.max(ideal_len).max(0.08);
                let freq_bonus = lex.freq_prior(idx) * 0.14;
                let bigram_bonus = if bigram_set.contains(lw.as_str()) { 0.04 } else { 0.0 };
                let variant_bonus = match config.english_variant {
                    EnglishVariant::Au | EnglishVariant::Uk => {
                        if lex.au_uk_set.contains(lw.as_str()) {
                            0.03
                        } else if lex.us_to_au_uk.contains_key(lw.as_str()) {
                            -0.02
                        } else {
                            0.0
                        }
                    }
                    EnglishVariant::Us => 0.0,
                };

                let total_score =
                    mean_d * 0.55 + missed_key_pen * 0.50 + endpoint_pen * 0.35 + len_diff * 0.18
                        - freq_bonus
                        - bigram_bonus
                        - variant_bonus;
                let display = apply_word_casing("", lex.words[idx as usize], shift);
                if seen_lower.insert(lw.clone()) {
                    scored.push((display, total_score));
                }
            }
        }
    }

    for pw in &config.personal_words {
        let lp = pw.to_ascii_lowercase();
        if lp.len() < 2 || !seen_lower.insert(lp.clone()) {
            continue;
        }
        let Some(key_pts) = word_key_points(&lp) else {
            continue;
        };
        if key_pts.len() < 2 {
            continue;
        }
        let ideal = resample_path(&key_pts, GLIDE_SAMPLES);
        let sum_d: f32 = resampled
            .iter()
            .zip(ideal.iter())
            .map(|(u, i)| QwertyGeometry::norm_dist(u.0, u.1, i.0, i.1))
            .sum();
        let mean_d = sum_d / (GLIDE_SAMPLES as f32);
        if mean_d <= 0.22 {
            scored.push((apply_word_casing("", pw, shift), mean_d - 0.06));
        }
    }

    scored.sort_by(|a, b| a.1.total_cmp(&b.1));
    scored.truncate(3);
    scored.into_iter().map(|(w, _)| w).collect()
}

#[derive(Debug, Clone)]
struct AutoCommitUndo {
    original: String,
    committed: String,
    had_trailing_space: bool,
}

#[derive(Debug)]
pub struct KeyboardSession {
    pub config: KeyboardConfig,
    pub current_word: String,
    pub tap_points: Vec<(f32, f32)>,
    pub shift_state: ShiftState,
    last_auto_commit: Option<AutoCommitUndo>,
    last_deleted_word: Option<String>,
    pending_glide_space: bool,
    last_space_double: bool,
}

impl KeyboardSession {
    pub fn new(config: KeyboardConfig) -> Self {
        Self {
            config,
            current_word: String::new(),
            tap_points: Vec::new(),
            shift_state: ShiftState::Off,
            last_auto_commit: None,
            last_deleted_word: None,
            pending_glide_space: false,
            last_space_double: false,
        }
    }

    fn sync_current_word_from_context(&mut self, context_before: Option<&str>) {
        let tail = extract_trailing_token(context_before.unwrap_or(""));
        if tail != self.current_word {
            self.current_word = tail.to_string();
            if self.current_word.is_empty() {
                self.tap_points.clear();
            } else {
                self.tap_points.truncate(self.current_word.len());
            }
        }
    }

    fn update_auto_caps_for_context(&mut self, context_before: Option<&str>) {
        if self.shift_state == ShiftState::CapsLock {
            return;
        }
        if !self.config.auto_caps {
            return;
        }
        if should_auto_cap(context_before.unwrap_or("")) {
            self.shift_state = ShiftState::Once;
        }
    }

    fn emoji_hints_for(&self, db: &EmojiDatabase, context_before: Option<&str>, usage: &HashMap<String, u64>) -> Vec<EmojiHint> {
        let raw = context_before.unwrap_or("");
        let mut snippet = raw.to_string();
        if !self.current_word.is_empty() && !raw.ends_with(&self.current_word) {
            snippet.push_str(&self.current_word);
        }
        match_context(db, Some(&snippet), usage)
            .into_iter()
            .take(4)
            .map(|idx| {
                let em = &db.all[idx];
                EmojiHint {
                    hex: em.hexcode.clone(),
                    glyph: em.toned_glyph(self.config.skin_tone).into_owned(),
                    label: em.label.clone(),
                }
            })
            .collect()
    }

    fn next_word_candidates(&self, context_before: Option<&str>) -> Vec<CandidateItem> {
        let prev = extract_previous_word(context_before.unwrap_or(""));
        let lex = Lexicon::global();
        lex.bigram_predictions(prev.unwrap_or(""))
            .into_iter()
            .map(|w| CandidateItem {
                text: w,
                kind: CandidateKind::Prediction,
                auto_commit: false,
            })
            .collect()
    }

    pub fn tap_key(
        &mut self,
        ch: char,
        norm_x: f32,
        norm_y: f32,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_space_double = false;
        self.last_deleted_word = None;
        self.last_auto_commit = None;

        let mut edit = TextEdit::default();
        if self.pending_glide_space {
            edit.insert.push(' ');
            self.pending_glide_space = false;
        }

        self.sync_current_word_from_context(context_before);

        let effective_ch = if ch.is_ascii_alphabetic() {
            match self.shift_state {
                ShiftState::Off => ch.to_ascii_lowercase(),
                ShiftState::Once => {
                    self.shift_state = ShiftState::Off;
                    ch.to_ascii_uppercase()
                }
                ShiftState::CapsLock => ch.to_ascii_uppercase(),
            }
        } else {
            ch
        };

        edit.insert.push(effective_ch);
        if is_token_char(effective_ch) {
            self.current_word.push(effective_ch);
            if norm_x >= 0.0 && norm_y >= 0.0 {
                self.tap_points.push((norm_x, norm_y));
            }
        } else {
            self.current_word.clear();
            self.tap_points.clear();
        }

        let mut new_ctx = context_before.unwrap_or("").to_string();
        new_ctx.push_str(&edit.insert);

        let candidates = if self.current_word.is_empty() {
            self.next_word_candidates(Some(&new_ctx))
        } else {
            suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
        };
        let emoji_hints = self.emoji_hints_for(db, Some(&new_ctx), usage);

        KeyboardOutput {
            edit,
            candidates,
            emoji_hints,
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn insert_direct(
        &mut self,
        text: &str,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_space_double = false;
        self.last_deleted_word = None;
        self.last_auto_commit = None;

        let smart_punct = text
            .chars()
            .next()
            .map_or(false, |c| matches!(c, '.' | ',' | '?' | '!' | ':' | ';' | ')' | ']'));

        let mut edit = TextEdit::default();
        if self.pending_glide_space {
            if !smart_punct {
                edit.insert.push(' ');
            }
            self.pending_glide_space = false;
        }
        edit.insert.push_str(text);

        if text.chars().all(is_token_char) && !text.is_empty() {
            self.current_word.push_str(text);
        } else {
            self.current_word.clear();
            self.tap_points.clear();
        }

        let mut new_ctx = context_before.unwrap_or("").to_string();
        new_ctx.push_str(&edit.insert);
        self.update_auto_caps_for_context(Some(&new_ctx));

        KeyboardOutput {
            edit,
            candidates: if self.current_word.is_empty() {
                self.next_word_candidates(Some(&new_ctx))
            } else {
                suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
            },
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn tap_space(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_deleted_word = None;
        self.sync_current_word_from_context(context_before);

        if self.pending_glide_space {
            self.pending_glide_space = false;
            return self.insert_direct(" ", context_before, db, usage);
        }

        let raw_ctx = context_before.unwrap_or("");
        // Double-space period shortcut: "<word> " + space -> "<word>. "
        if self.current_word.is_empty()
            && self.config.double_space_period
            && raw_ctx.ends_with(' ')
            && raw_ctx
                .trim_end_matches(' ')
                .chars()
                .last()
                .map_or(false, |c| c.is_alphanumeric())
            && !raw_ctx.ends_with("  ")
            && !self.last_space_double
        {
            self.last_space_double = true;
            let edit = TextEdit {
                delete_backward: 1,
                insert: ". ".to_string(),
            };
            let mut new_ctx = raw_ctx[..raw_ctx.len() - 1].to_string();
            new_ctx.push_str(". ");
            self.update_auto_caps_for_context(Some(&new_ctx));
            return KeyboardOutput {
                edit,
                candidates: self.next_word_candidates(Some(&new_ctx)),
                emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
                undo_word: None,
                shift_state: self.shift_state,
                auto_space_active: false,
            };
        }

        self.last_space_double = false;
        let mut edit = TextEdit::default();

        if !self.current_word.is_empty() {
            let sugg = suggest_for_word(
                &self.current_word,
                &self.tap_points,
                &self.config,
                self.shift_state,
            );
            if let Some(best) = sugg.iter().find(|c| c.auto_commit) {
                let orig = self.current_word.clone();
                let committed = best.text.clone();
                edit.delete_backward = orig.chars().count();
                edit.insert = format!("{committed} ");
                self.last_auto_commit = Some(AutoCommitUndo {
                    original: orig,
                    committed: committed.clone(),
                    had_trailing_space: true,
                });
            } else {
                edit.insert.push(' ');
                self.last_auto_commit = None;
            }
        } else {
            edit.insert.push(' ');
            self.last_auto_commit = None;
        }

        self.current_word.clear();
        self.tap_points.clear();

        let mut new_ctx = apply_edit_preview(raw_ctx, &edit);
        self.update_auto_caps_for_context(Some(&new_ctx));
        if new_ctx.is_empty() {
            new_ctx.push(' ');
        }

        KeyboardOutput {
            edit,
            candidates: self.next_word_candidates(Some(&new_ctx)),
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn tap_return(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_deleted_word = None;
        self.last_auto_commit = None;
        self.pending_glide_space = false;
        self.last_space_double = false;
        self.current_word.clear();
        self.tap_points.clear();
        let mut new_ctx = context_before.unwrap_or("").to_string();
        new_ctx.push('\n');
        self.update_auto_caps_for_context(Some(&new_ctx));

        KeyboardOutput {
            edit: TextEdit {
                delete_backward: 0,
                insert: "\n".to_string(),
            },
            candidates: self.next_word_candidates(Some(&new_ctx)),
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn tap_backspace(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_space_double = false;

        if self.pending_glide_space {
            // Undo whole pending glide word on immediate Backspace if tracked, else delete 1.
            self.pending_glide_space = false;
        }

        if let Some(undo) = self.last_auto_commit.take() {
            let raw = context_before.unwrap_or("");
            let expected_suffix = if undo.had_trailing_space {
                format!("{} ", undo.committed)
            } else {
                undo.committed.clone()
            };
            if raw.ends_with(&expected_suffix) {
                self.config
                    .rejected_corrections
                    .insert(undo.original.to_ascii_lowercase(), undo.committed.to_ascii_lowercase());
                let restored = if undo.had_trailing_space {
                    format!("{} ", undo.original)
                } else {
                    undo.original.clone()
                };
                let edit = TextEdit {
                    delete_backward: expected_suffix.chars().count(),
                    insert: restored,
                };
                self.current_word = if undo.had_trailing_space {
                    String::new()
                } else {
                    undo.original
                };
                let new_ctx = apply_edit_preview(raw, &edit);
                let cands = if self.current_word.is_empty() {
                    self.next_word_candidates(Some(&new_ctx))
                } else {
                    suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
                };
                return KeyboardOutput {
                    edit,
                    candidates: cands,
                    emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
                    undo_word: None,
                    shift_state: self.shift_state,
                    auto_space_active: false,
                };
            }
        }

        let raw = context_before.unwrap_or("");
        let edit = TextEdit {
            delete_backward: usize::from(!raw.is_empty()),
            insert: String::new(),
        };
        let new_ctx = apply_edit_preview(raw, &edit);
        self.current_word = extract_trailing_token(&new_ctx).to_string();
        if self.current_word.is_empty() {
            self.tap_points.clear();
            self.update_auto_caps_for_context(Some(&new_ctx));
        } else {
            self.tap_points.truncate(self.current_word.len());
        }

        let candidates = if self.current_word.is_empty() {
            self.next_word_candidates(Some(&new_ctx))
        } else {
            suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
        };

        KeyboardOutput {
            edit,
            candidates,
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn swipe_delete_word(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_auto_commit = None;
        self.pending_glide_space = false;
        self.last_space_double = false;

        let raw = context_before.unwrap_or("");
        if raw.is_empty() {
            return KeyboardOutput {
                edit: TextEdit::default(),
                candidates: self.next_word_candidates(Some(raw)),
                emoji_hints: self.emoji_hints_for(db, Some(raw), usage),
                undo_word: None,
                shift_state: self.shift_state,
                auto_space_active: false,
            };
        }

        let chars: Vec<char> = raw.chars().collect();
        let mut idx = chars.len();
        while idx > 0 && chars[idx - 1].is_whitespace() && chars[idx - 1] != '\n' {
            idx -= 1;
        }
        if idx < chars.len() && chars[idx] == '\n' {
            idx -= 1;
        } else {
            while idx > 0 && !chars[idx - 1].is_whitespace() {
                idx -= 1;
            }
        }
        let deleted: String = chars[idx..].iter().collect();
        let delete_count = chars.len() - idx;
        self.last_deleted_word = if deleted.is_empty() {
            None
        } else {
            Some(deleted.clone())
        };
        self.current_word.clear();
        self.tap_points.clear();

        let new_ctx: String = chars[..idx].iter().collect();
        self.update_auto_caps_for_context(Some(&new_ctx));

        KeyboardOutput {
            edit: TextEdit {
                delete_backward: delete_count,
                insert: String::new(),
            },
            candidates: self.next_word_candidates(Some(&new_ctx)),
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: self.last_deleted_word.clone(),
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn undo_last_delete(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        let Some(restored) = self.last_deleted_word.take() else {
            return self.sync_context(context_before, db, usage);
        };
        let mut new_ctx = context_before.unwrap_or("").to_string();
        new_ctx.push_str(&restored);
        self.current_word = extract_trailing_token(&new_ctx).to_string();
        KeyboardOutput {
            edit: TextEdit {
                delete_backward: 0,
                insert: restored,
            },
            candidates: if self.current_word.is_empty() {
                self.next_word_candidates(Some(&new_ctx))
            } else {
                suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
            },
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn finish_glide(
        &mut self,
        points: &[(f32, f32)],
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_deleted_word = None;
        self.last_auto_commit = None;
        self.last_space_double = false;

        let raw = context_before.unwrap_or("");
        let prev = extract_previous_word(raw);
        let decoded = decode_glide(points, prev, &self.config, self.shift_state);
        let Some(top) = decoded.first().cloned() else {
            return self.sync_context(context_before, db, usage);
        };

        let mut prefix = String::new();
        if self.pending_glide_space {
            prefix.push(' ');
        } else if raw
            .chars()
            .last()
            .map_or(false, |c| c.is_alphanumeric() || matches!(c, '.' | ',' | '?' | '!' | ')' | ']'))
        {
            prefix.push(' ');
        }

        let insert = format!("{prefix}{top}");
        self.pending_glide_space = true;
        self.current_word = top.clone();
        self.tap_points.clear();
        if self.shift_state == ShiftState::Once {
            self.shift_state = ShiftState::Off;
        }

        let mut new_ctx = raw.to_string();
        new_ctx.push_str(&insert);

        let candidates: Vec<CandidateItem> = decoded
            .into_iter()
            .enumerate()
            .map(|(i, w)| CandidateItem {
                text: w,
                kind: CandidateKind::Glide,
                auto_commit: i == 0,
            })
            .collect();

        KeyboardOutput {
            edit: TextEdit {
                delete_backward: 0,
                insert,
            },
            candidates,
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: true,
        }
    }

    pub fn accept_candidate(
        &mut self,
        candidate_text: &str,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.last_deleted_word = None;
        self.last_auto_commit = None;
        self.last_space_double = false;
        self.sync_current_word_from_context(context_before);

        let raw = context_before.unwrap_or("");
        let delete_backward = if self.current_word.is_empty() {
            0
        } else {
            self.current_word.chars().count()
        };

        let mut prefix = String::new();
        if delete_backward == 0 && self.pending_glide_space {
            prefix.push(' ');
        } else if delete_backward == 0
            && raw
                .chars()
                .last()
                .map_or(false, |c| c.is_alphanumeric() || matches!(c, '.' | ',' | '?'))
        {
            prefix.push(' ');
        }
        self.pending_glide_space = false;

        let edit = TextEdit {
            delete_backward,
            insert: format!("{prefix}{candidate_text} "),
        };
        if self.shift_state == ShiftState::Once {
            self.shift_state = ShiftState::Off;
        }
        self.current_word.clear();
        self.tap_points.clear();

        let new_ctx = apply_edit_preview(raw, &edit);
        self.update_auto_caps_for_context(Some(&new_ctx));

        KeyboardOutput {
            edit,
            candidates: self.next_word_candidates(Some(&new_ctx)),
            emoji_hints: self.emoji_hints_for(db, Some(&new_ctx), usage),
            undo_word: None,
            shift_state: self.shift_state,
            auto_space_active: false,
        }
    }

    pub fn sync_context(
        &mut self,
        context_before: Option<&str>,
        db: &EmojiDatabase,
        usage: &HashMap<String, u64>,
    ) -> KeyboardOutput {
        self.sync_current_word_from_context(context_before);
        if self.current_word.is_empty() {
            if self.shift_state == ShiftState::Once && !should_auto_cap(context_before.unwrap_or("")) {
                self.shift_state = ShiftState::Off;
            }
            self.update_auto_caps_for_context(context_before);
        } else if self.shift_state == ShiftState::Once {
            self.shift_state = ShiftState::Off;
        }
        let candidates = if self.current_word.is_empty() {
            self.next_word_candidates(context_before)
        } else {
            suggest_for_word(&self.current_word, &self.tap_points, &self.config, self.shift_state)
        };
        KeyboardOutput {
            edit: TextEdit::default(),
            candidates,
            emoji_hints: self.emoji_hints_for(db, context_before, usage),
            undo_word: self.last_deleted_word.clone(),
            shift_state: self.shift_state,
            auto_space_active: self.pending_glide_space,
        }
    }
}

#[inline]
fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '\'' || c == '/'
}

fn extract_trailing_token(context: &str) -> &str {
    let mut start = context.len();
    for (i, ch) in context.char_indices().rev() {
        if is_token_char(ch) {
            start = i;
        } else {
            break;
        }
    }
    &context[start..]
}

fn extract_previous_word(context: &str) -> Option<&str> {
    let trimmed = context.trim_end();
    if trimmed.is_empty() {
        return None;
    }
    let token = extract_trailing_token(trimmed);
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

fn should_auto_cap(context: &str) -> bool {
    let trimmed = context.trim_end_matches(' ');
    if trimmed.is_empty() {
        return true;
    }
    if trimmed.ends_with('\n') {
        return true;
    }
    matches!(trimmed.chars().last(), Some('.' | '!' | '?')) && context.ends_with(' ')
}

fn apply_edit_preview(context: &str, edit: &TextEdit) -> String {
    let mut chars: Vec<char> = context.chars().collect();
    let keep = chars.len().saturating_sub(edit.delete_backward);
    chars.truncate(keep);
    let mut out: String = chars.into_iter().collect();
    out.push_str(&edit.insert);
    out
}

fn build_contractions() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("dont", "don't"),
        ("cant", "can't"),
        ("wont", "won't"),
        ("didnt", "didn't"),
        ("doesnt", "doesn't"),
        ("isnt", "isn't"),
        ("arent", "aren't"),
        ("wasnt", "wasn't"),
        ("werent", "weren't"),
        ("havent", "haven't"),
        ("hasnt", "hasn't"),
        ("hadnt", "hadn't"),
        ("wouldnt", "wouldn't"),
        ("couldnt", "couldn't"),
        ("shouldnt", "shouldn't"),
        ("im", "I'm"),
        ("ive", "I've"),
        ("youre", "you're"),
        ("youve", "you've"),
        ("youll", "you'll"),
        ("youd", "you'd"),
        ("weve", "we've"),
        ("theyre", "they're"),
        ("theyve", "they've"),
        ("theyll", "they'll"),
        ("theyd", "they'd"),
        ("hes", "he's"),
        ("shes", "she's"),
        ("thats", "that's"),
        ("theres", "there's"),
        ("heres", "here's"),
        ("whats", "what's"),
        ("whos", "who's"),
    ])
}

fn build_variant_maps() -> (
    HashSet<&'static str>,
    HashMap<&'static str, &'static str>,
    HashMap<&'static str, &'static str>,
) {
    let pairs: &[(&'static str, &'static str)] = &[
        ("colour", "color"),
        ("colours", "colors"),
        ("coloured", "colored"),
        ("colouring", "coloring"),
        ("behaviour", "behavior"),
        ("behaviours", "behaviors"),
        ("behavioural", "behavioral"),
        ("organise", "organize"),
        ("organised", "organized"),
        ("organising", "organizing"),
        ("organisation", "organization"),
        ("centre", "center"),
        ("centres", "centers"),
        ("programme", "program"),
        ("programmes", "programs"),
        ("favour", "favor"),
        ("favours", "favors"),
        ("favourite", "favorite"),
        ("favourites", "favorites"),
        ("honour", "honor"),
        ("honours", "honors"),
        ("neighbour", "neighbor"),
        ("neighbours", "neighbors"),
        ("travelling", "traveling"),
        ("travelled", "traveled"),
        ("cancelled", "canceled"),
        ("cancelling", "canceling"),
        ("licence", "license"),
        ("practise", "practice"),
        ("defence", "defense"),
        ("offence", "offense"),
        ("grey", "gray"),
        ("tyre", "tire"),
        ("tyres", "tires"),
        ("kerb", "curb"),
        ("aluminium", "aluminum"),
        ("realise", "realize"),
        ("realised", "realized"),
        ("realising", "realizing"),
        ("recognise", "recognize"),
        ("recognised", "recognized"),
        ("recognising", "recognizing"),
        ("analyse", "analyze"),
        ("analysed", "analyzed"),
        ("analysing", "analyzing"),
        ("apologise", "apologize"),
        ("apologised", "apologized"),
        ("customise", "customize"),
        ("customised", "customized"),
        ("optimise", "optimize"),
        ("optimised", "optimized"),
        ("prioritise", "prioritize"),
        ("manoeuvre", "maneuver"),
        ("sceptical", "skeptical"),
        ("judgement", "judgment"),
        ("fulfil", "fulfill"),
        ("enrol", "enroll"),
        ("skilful", "skillful"),
        ("kilometre", "kilometer"),
        ("kilometres", "kilometers"),
        ("litre", "liter"),
        ("litres", "liters"),
        ("metre", "meter"),
        ("metres", "meters"),
        ("dyspnoea", "dyspnea"),
        ("oedema", "edema"),
        ("anaesthesia", "anesthesia"),
        ("anaesthetic", "anesthetic"),
        ("paediatric", "pediatric"),
        ("haemoglobin", "hemoglobin"),
        ("haemorrhage", "hemorrhage"),
        ("haematology", "hematology"),
        ("haematuria", "hematuria"),
        ("haemoptysis", "hemoptysis"),
        ("oesophagus", "esophagus"),
        ("diarrhoea", "diarrhea"),
        ("foetus", "fetus"),
        ("gynaecology", "gynecology"),
        ("orthopaedic", "orthopedic"),
        ("leukaemia", "leukemia"),
        ("anaemia", "anemia"),
        ("ischaemia", "ischemia"),
        ("ischaemic", "ischemic"),
        ("hyperglycaemia", "hyperglycemia"),
        ("hypoglycaemia", "hypoglycemia"),
        ("hyponatraemia", "hyponatremia"),
        ("hyperkalaemia", "hyperkalemia"),
        ("melaena", "melena"),
    ];
    let mut au_set = HashSet::with_capacity(pairs.len());
    let mut us_to_au = HashMap::with_capacity(pairs.len());
    let mut au_to_us = HashMap::with_capacity(pairs.len());
    for &(au, us) in pairs {
        au_set.insert(au);
        us_to_au.insert(us, au);
        au_to_us.insert(au, us);
    }
    (au_set, us_to_au, au_to_us)
}

fn build_bigrams() -> HashMap<&'static str, Vec<&'static str>> {
    HashMap::from([
        ("", vec!["Hey", "I", "Thanks"]),
        ("i", vec!["think", "have", "can"]),
        ("i'm", vec!["on", "heading", "good"]),
        ("i've", vec!["been", "got", "done"]),
        ("i'll", vec!["be", "check", "send"]),
        ("you", vec!["can", "have", "want"]),
        ("you're", vec!["welcome", "right", "good"]),
        ("we", vec!["can", "should", "need"]),
        ("it", vec!["is", "was", "looks"]),
        ("it's", vec!["a", "not", "good"]),
        ("that", vec!["is", "looks", "sounds"]),
        ("that's", vec!["awesome", "good", "fine"]),
        ("thank", vec!["you", "so", "goodness"]),
        ("thanks", vec!["for", "mate", "heaps"]),
        ("see", vec!["you", "what", "if"]),
        ("sounds", vec!["good", "great", "like"]),
        ("looks", vec!["good", "great", "like"]),
        ("on", vec!["my", "the", "a"]),
        ("my", vec!["way", "phone", "side"]),
        ("let", vec!["me", "us", "you"]),
        ("me", vec!["know", "when", "if"]),
        ("no", vec!["worries", "problem", "way"]),
        ("all", vec!["good", "good!", "set"]),
        ("be", vec!["there", "ready", "able"]),
        ("going", vec!["to", "out", "home"]),
        ("want", vec!["to", "some", "anything"]),
        ("need", vec!["to", "any", "some"]),
        ("have", vec!["a", "to", "some"]),
        ("looking", vec!["forward", "at", "for"]),
        ("forward", vec!["to", "it", "from"]),
        ("happy", vec!["birthday", "to", "with"]),
        ("good", vec!["morning", "luck", "idea"]),
        ("how", vec!["are", "did", "was"]),
        ("are", vec!["you", "we", "they"]),
        ("what", vec!["are", "do", "time"]),
        ("can", vec!["you", "we", "I"]),
        ("will", vec!["be", "do", "check"]),
        ("for", vec!["sure", "the", "today"]),
        ("at", vec!["the", "home", "work"]),
        ("in", vec!["the", "a", "Perth"]),
        ("this", vec!["morning", "afternoon", "arvo"]),
        ("mild", vec!["dyspnoea", "oedema", "pain"]),
        ("chest", vec!["pain", "xray", "clear"]),
        ("shortness", vec!["of", "after", "with"]),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> &'static EmojiDatabase {
        EmojiDatabase::global()
    }

    fn path_for(word: &str) -> Vec<(f32, f32)> {
        let mut pts = Vec::new();
        let mut prev: Option<char> = None;
        let raw_keys: Vec<(f32, f32)> = word
            .chars()
            .filter_map(|c| {
                let lc = c.to_ascii_lowercase();
                if prev == Some(lc) {
                    return None;
                }
                prev = Some(lc);
                QwertyGeometry::key_center(lc)
            })
            .collect();
        for w in raw_keys.windows(2) {
            for step in 0..5 {
                let t = step as f32 / 5.0;
                pts.push((w[0].0 + (w[1].0 - w[0].0) * t, w[0].1 + (w[1].1 - w[0].1) * t));
            }
        }
        if let Some(&last) = raw_keys.last() {
            pts.push(last);
        }
        pts
    }

    #[test]
    fn spatial_autocorrect_fixes_common_typos() {
        let cfg = KeyboardConfig::default();
        for (typo, want) in [
            ("teh", "the"),
            ("becuase", "because"),
            ("definately", "definitely"),
        ] {
            let cands = suggest_for_word(typo, &[], &cfg, ShiftState::Off);
            assert!(
                cands.iter().any(|c| c.text.eq_ignore_ascii_case(want)),
                "expected {want} for {typo}, got {cands:?}"
            );
            assert!(
                cands.iter().any(|c| c.auto_commit && c.text.eq_ignore_ascii_case(want)),
                "expected auto_commit for {typo} -> {want}, got {cands:?}"
            );
        }
    }

    #[test]
    fn contractions_expand_automatically() {
        let cfg = KeyboardConfig::default();
        let cands = suggest_for_word("dont", &[], &cfg, ShiftState::Off);
        assert_eq!(cands[1].text, "don't");
        assert!(cands[1].auto_commit);

        let cands_im = suggest_for_word("im", &[], &cfg, ShiftState::Off);
        assert_eq!(cands_im[1].text, "I'm");
        assert!(cands_im[1].auto_commit);
    }

    #[test]
    fn au_uk_spellings_and_medical_terms_are_never_corrupted_to_us() {
        let cfg = KeyboardConfig::default(); // Australian default
        for word in ["colour", "behaviour", "dyspnoea", "oedema"] {
            let cands = suggest_for_word(word, &[], &cfg, ShiftState::Off);
            assert!(!cands.iter().any(|c| c.auto_commit), "{word} should never auto-commit: {cands:?}");
            assert_eq!(cands[0].text, word);
        }
        let colur = suggest_for_word("colur", &[], &cfg, ShiftState::Off);
        assert_eq!(colur[1].text, "colour", "AU mode should rank colour first for colur: {colur:?}");
    }

    #[test]
    fn one_tap_backspace_undoes_autocommit_and_learns_rejection() {
        let cfg = KeyboardConfig::default();
        let mut sess = KeyboardSession::new(cfg);
        let usage = HashMap::new();

        let sp = sess.tap_space(Some("teh"), db(), &usage);
        assert_eq!(sp.edit.delete_backward, 3);
        assert_eq!(sp.edit.insert, "the ");

        let bk = sess.tap_backspace(Some("the "), db(), &usage);
        assert_eq!(bk.edit.delete_backward, 4);
        assert_eq!(bk.edit.insert, "teh ");
        assert_eq!(sess.config.rejected_corrections.get("teh").map(String::as_str), Some("the"));

        // Subsequent typing of "teh" must not auto-commit "the" again.
        let again = suggest_for_word("teh", &[], &sess.config, ShiftState::Off);
        assert!(!again.iter().any(|c| c.auto_commit && c.text == "the"));
    }

    #[test]
    fn glide_decoder_recognizes_common_and_domain_words() {
        let cfg = KeyboardConfig::default();
        let test_words = [
            "hello", "world", "spritz", "keyboard", "thanks", "tomorrow",
            "coffee", "great", "quick", "message", "please", "morning",
        ];
        for word in test_words {
            let pts = path_for(word);
            let out = decode_glide(&pts, None, &cfg, ShiftState::Off);
            assert!(
                out.iter().any(|w| w.eq_ignore_ascii_case(word)),
                "glide failed to return {word} in top 3: {out:?}"
            );
        }
    }

    #[test]
    fn snippets_double_space_period_and_smart_punctuation_work() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();

        let shrug = sess.tap_space(Some("ok /shrug"), db(), &usage);
        assert_eq!(shrug.edit.delete_backward, 6);
        assert_eq!(shrug.edit.insert, "¯\\_(ツ)_/¯ ");

        let period = sess.tap_space(Some("Hello "), db(), &usage);
        assert_eq!(period.edit.delete_backward, 1);
        assert_eq!(period.edit.insert, ". ");
        assert_eq!(period.shift_state, ShiftState::Once);

        // Glide followed by punctuation must NOT insert an orphaned leading space before comma.
        let pts = path_for("hello");
        let glide = sess.finish_glide(&pts, Some(""), db(), &usage);
        assert!(!glide.edit.insert.is_empty());
        let comma = sess.insert_direct(",", Some(&glide.edit.insert), db(), &usage);
        assert_eq!(comma.edit.insert, ",");
    }

    #[test]
    fn swipe_delete_word_and_undo_restore() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();

        let del = sess.swipe_delete_word(Some("Hello world "), db(), &usage);
        assert_eq!(del.edit.delete_backward, 6);
        assert_eq!(del.undo_word.as_deref(), Some("world "));

        let undo = sess.undo_last_delete(Some("Hello "), db(), &usage);
        assert_eq!(undo.edit.insert, "world ");
    }

    #[test]
    fn bigrams_and_context_emoji_hints_populate() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();

        let out = sess.sync_context(Some("Thank "), db(), &usage);
        assert!(out.candidates.iter().any(|c| c.text == "you"));

        let emoji_out = sess.sync_context(Some("grabbing coffee soon"), db(), &usage);
        assert!(
            emoji_out.emoji_hints.iter().any(|h| h.glyph.contains('☕')),
            "expected coffee emoji hint, got {:?}",
            emoji_out.emoji_hints
        );
    }

    #[test]
    fn personal_words_protect_and_suggest() {
        let mut cfg = KeyboardConfig::default();
        cfg.personal_words.push("Tachyon".to_string());
        let cands = suggest_for_word("Tachyon", &[], &cfg, ShiftState::Off);
        assert!(!cands.iter().any(|c| c.auto_commit));

        let near = suggest_for_word("Tachyn", &[], &cfg, ShiftState::Off);
        assert!(near.iter().any(|c| c.text == "Tachyon"));
    }

    #[test]
    fn autocorrect_off_never_commits_typos() {
        let mut cfg = KeyboardConfig::default();
        cfg.autocorrect = AutocorrectMode::Off;
        let cands = suggest_for_word("teh", &[], &cfg, ShiftState::Off);
        assert!(!cands.iter().any(|c| c.auto_commit));
    }

    #[test]
    fn us_variant_prefers_us_spelling_and_protects_us_words() {
        let mut cfg = KeyboardConfig::default();
        cfg.english_variant = EnglishVariant::Us;
        let exact = suggest_for_word("color", &[], &cfg, ShiftState::Off);
        assert!(!exact.iter().any(|c| c.auto_commit));
        assert_eq!(exact[0].text, "color");
    }

    #[test]
    fn shift_and_caps_lock_preserve_casing_on_corrections() {
        let cfg = KeyboardConfig::default();
        let cap = suggest_for_word("Teh", &[], &cfg, ShiftState::Off);
        assert_eq!(cap[1].text, "The");

        let caps = suggest_for_word("TEH", &[], &cfg, ShiftState::CapsLock);
        assert_eq!(caps[1].text, "THE");
    }

    #[test]
    fn tap_key_consumes_single_shift_and_triggers_autocaps() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();
        let synced = sess.sync_context(Some(""), db(), &usage);
        assert_eq!(synced.shift_state, ShiftState::Once);

        let first = sess.tap_key('h', 0.60, 0.50, Some(""), db(), &usage);
        assert_eq!(first.edit.insert, "H");
        assert_eq!(first.shift_state, ShiftState::Off);
    }

    #[test]
    fn glide_tolerates_small_finger_jitter() {
        let cfg = KeyboardConfig::default();
        let mut pts = path_for("coffee");
        for (i, p) in pts.iter_mut().enumerate() {
            let j = if i % 2 == 0 { 0.018 } else { -0.015 };
            p.0 = (p.0 + j).clamp(0.02, 0.98);
            p.1 = (p.1 + j * 0.5).clamp(0.05, 0.95);
        }
        let out = decode_glide(&pts, None, &cfg, ShiftState::Off);
        assert!(out.iter().any(|w| w == "coffee"), "jittered glide failed: {out:?}");
    }

    #[test]
    fn accept_candidate_replaces_active_word_and_adds_space() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();
        let out = sess.accept_candidate("tomorrow", Some("see you tomor"), db(), &usage);
        assert_eq!(out.edit.delete_backward, 5);
        assert_eq!(out.edit.insert, "tomorrow ");
    }

    #[test]
    fn touch_coordinates_disambiguate_tied_adjacent_typos() {
        let cfg = KeyboardConfig::default();
        // Tap points closer to 'the' than 'thy'
        let pts = vec![
            QwertyGeometry::key_center('t').unwrap(),
            QwertyGeometry::key_center('h').unwrap(),
            QwertyGeometry::key_center('e').unwrap(),
        ];
        let out = suggest_for_word("thw", &pts, &cfg, ShiftState::Off);
        assert_eq!(out[1].text, "the");
    }

    #[test]
    fn sync_context_resets_single_shift_mid_sentence() {
        let mut sess = KeyboardSession::new(KeyboardConfig::default());
        let usage = HashMap::new();

        let empty = sess.sync_context(Some(""), db(), &usage);
        assert_eq!(empty.shift_state, ShiftState::Once);

        let mid = sess.sync_context(Some("on my way teh"), db(), &usage);
        assert_eq!(mid.shift_state, ShiftState::Off);
        assert_eq!(mid.candidates[1].text, "the");
    }
}
