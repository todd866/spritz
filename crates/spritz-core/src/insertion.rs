use unicode_segmentation::UnicodeSegmentation;

/// Splits `text` into chunks whose UTF-16 length never exceeds `max_utf16_units`,
/// keeping extended grapheme clusters intact unless a single grapheme itself
/// exceeds `max_utf16_units` (in which case it splits on scalar boundaries).
pub fn unicode_chunks(text: &str, max_utf16_units: usize) -> Vec<String> {
    if text.is_empty() || max_utf16_units == 0 {
        return Vec::new();
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut current_len = 0usize;

    let flush = |chunks: &mut Vec<String>, buf: &mut String, len: &mut usize| {
        if !buf.is_empty() {
            chunks.push(std::mem::take(buf));
            *len = 0;
        }
    };

    for grapheme in text.graphemes(true) {
        let g_len: usize = grapheme.encode_utf16().count();
        if g_len > max_utf16_units {
            flush(&mut chunks, &mut current, &mut current_len);
            for ch in grapheme.chars() {
                let c_len = ch.len_utf16();
                if current_len + c_len > max_utf16_units && !current.is_empty() {
                    flush(&mut chunks, &mut current, &mut current_len);
                }
                current.push(ch);
                current_len += c_len;
            }
            continue;
        }
        if current_len + g_len > max_utf16_units && !current.is_empty() {
            flush(&mut chunks, &mut current, &mut current_len);
        }
        current.push_str(grapheme);
        current_len += g_len;
    }
    flush(&mut chunks, &mut current, &mut current_len);
    chunks
}

/// Privacy-safe typing indicator (count + timestamp only; no keystroke text).
#[derive(Debug, Clone, Copy, Default)]
pub struct RecentTypingState {
    pub pid: Option<i32>,
    pub count: u32,
    pub last_at_secs: Option<f64>,
}

impl RecentTypingState {
    pub const GRACE_SECS: f64 = 30.0;

    pub fn record(&mut self, pid: i32, now_secs: f64) {
        if self.pid == Some(pid) {
            self.count = self.count.saturating_add(1);
        } else {
            self.pid = Some(pid);
            self.count = 1;
        }
        self.last_at_secs = Some(now_secs);
    }

    pub fn clear(&mut self) {
        self.pid = None;
        self.count = 0;
        self.last_at_secs = None;
    }

    pub fn is_recent(&self, pid: Option<i32>, now_secs: f64) -> bool {
        let (Some(target), Some(recorded), Some(last)) = (pid, self.pid, self.last_at_secs) else {
            return false;
        };
        target == recorded && self.count > 0 && now_secs >= last && (now_secs - last) <= Self::GRACE_SECS
    }
}

/// Determines whether browser/panel pick inserts directly or falls back to clipboard.
pub struct BrowserPickPolicy;

impl BrowserPickPolicy {
    pub fn should_copy_to_clipboard(
        have_info: bool,
        editable: bool,
        secure: bool,
        recent_typing_matches_pid: bool,
    ) -> bool {
        if secure {
            return true;
        }
        if have_info {
            return !editable && !recent_typing_matches_pid;
        }
        // Unclassified apps (e.g. Electron without AX exposure) accept synthetic events.
        false
    }
}

/// Recognizes a single contiguous insertion or selection-replacement at the pre-dictation caret
/// using UTF-16 code unit indices (matching macOS `NSRange` / `CFRange` AX values).
pub struct DictatedInsertion;

impl DictatedInsertion {
    pub const MAX_UTF8_BYTES: usize = 24_000;

    pub fn extract(
        before: &str,
        sel_loc_utf16: usize,
        sel_len_utf16: usize,
        after: &str,
        caret_loc_utf16: usize,
        caret_len_utf16: usize,
    ) -> Option<String> {
        if caret_len_utf16 != 0 {
            return None;
        }
        let orig_u16: Vec<u16> = before.encode_utf16().collect();
        if sel_loc_utf16 > orig_u16.len() || sel_len_utf16 > orig_u16.len() - sel_loc_utf16 {
            return None;
        }
        let prefix = &orig_u16[..sel_loc_utf16];
        let suffix = &orig_u16[sel_loc_utf16 + sel_len_utf16..];

        let after_u16: Vec<u16> = after.encode_utf16().collect();
        if after_u16.len() <= prefix.len() + suffix.len() {
            return None;
        }
        if !after_u16.starts_with(prefix) || !after_u16.ends_with(suffix) {
            return None;
        }
        if caret_loc_utf16 != after_u16.len() - suffix.len() {
            return None;
        }

        let middle_u16 = &after_u16[prefix.len()..after_u16.len() - suffix.len()];
        let inserted = String::from_utf16(middle_u16).ok()?;
        if inserted.trim().is_empty() || inserted.len() > Self::MAX_UTF8_BYTES {
            return None;
        }
        Some(inserted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_chunks_keep_zwj_and_flags_whole() {
        let s = "hello 👨‍👩‍👧‍👦🇦🇺😂 world";
        let chunks = unicode_chunks(s, 8);
        assert!(chunks.iter().all(|c| c.encode_utf16().count() <= 8));
        assert_eq!(chunks.concat(), s);

        let emoji_stream = "😂😅😘🤷🏻‍♂️🤓😎🙄🎉❤️🇦🇺";
        let e_chunks = unicode_chunks(emoji_stream, 20);
        assert!(e_chunks.len() >= 2);
        assert!(e_chunks.iter().all(|c| c.encode_utf16().count() <= 20));
        assert_eq!(e_chunks.concat(), emoji_stream);
    }

    #[test]
    fn browser_pick_policy_respects_recent_typing_and_secure() {
        assert!(!BrowserPickPolicy::should_copy_to_clipboard(true, true, false, false));
        assert!(!BrowserPickPolicy::should_copy_to_clipboard(true, false, false, true));
        assert!(BrowserPickPolicy::should_copy_to_clipboard(true, false, false, false));
        assert!(BrowserPickPolicy::should_copy_to_clipboard(true, true, true, true));
        assert!(!BrowserPickPolicy::should_copy_to_clipboard(false, false, false, false));
    }

    #[test]
    fn dictated_insertion_extracts_with_utf16_surrogates() {
        // "Hi 😂 there" -> prefix "Hi 😂 " is 6 UTF-16 units (😂 is 2 UTF-16 units).
        let before = "Hi 😂 there";
        let after = "Hi 😂 my friend there";
        let extracted = DictatedInsertion::extract(before, 6, 0, after, 16, 0);
        assert_eq!(extracted.as_deref(), Some("my friend "));
        assert_eq!(DictatedInsertion::extract(before, 6, 0, "edited 😂 my friend there", 19, 0), None);
    }
}
