use crate::dictation::{RefinementProvider, VoiceMode};
use crate::emoji::SkinTone;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SpritzConfig {
    pub skin_tone: SkinTone,
    pub globe_enabled: bool,
    pub replace_system_picker: bool,
    pub launch_at_login: bool,
    pub show_menu_bar_icon: bool,
    pub use_frequency_boost: bool,
    pub voice_mode: VoiceMode,
    pub refinement_provider: RefinementProvider,
    pub exclude_bundle_ids: Vec<String>,
    pub prior_fn_usage_type: Option<i32>,
}

impl Default for SpritzConfig {
    fn default() -> Self {
        Self {
            skin_tone: SkinTone::Default,
            globe_enabled: true,
            replace_system_picker: true,
            launch_at_login: true,
            show_menu_bar_icon: true,
            use_frequency_boost: true,
            voice_mode: VoiceMode::ChatGptPassthrough,
            refinement_provider: RefinementProvider::Antigravity,
            exclude_bundle_ids: Vec::new(),
            prior_fn_usage_type: None,
        }
    }
}

impl SpritzConfig {
    pub fn default_path() -> PathBuf {
        let home = std::env::var_os("HOME").unwrap_or_default();
        PathBuf::from(home)
            .join(".config")
            .join("spritz")
            .join("config.toml")
    }

    pub fn load_or_default(path: &Path) -> Self {
        match fs::read_to_string(path) {
            Ok(txt) => toml::from_str(&txt).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save_atomic(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let body = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        write_atomic_0600(path, body.as_bytes())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SpritzState {
    pub schema: u32,
    pub numbered_emoji: Vec<String>,
    pub letter_bindings: HashMap<String, String>,
    pub released_hexes: Vec<String>,
    pub released_letters: Vec<String>,
    pub recent_emoji: Vec<String>,
    pub usage_counts: HashMap<String, u64>,
    pub total_emoji_inserted: u64,
    pub first_launch_date: Option<f64>,
    pub paused_until: Option<f64>,
    pub prior_character_palette_enabled: Option<bool>,
}

impl Default for SpritzState {
    fn default() -> Self {
        Self {
            schema: 1,
            numbered_emoji: Vec::new(),
            letter_bindings: HashMap::new(),
            released_hexes: Vec::new(),
            released_letters: Vec::new(),
            recent_emoji: Vec::new(),
            usage_counts: HashMap::new(),
            total_emoji_inserted: 0,
            first_launch_date: None,
            paused_until: None,
            prior_character_palette_enabled: None,
        }
    }
}

impl SpritzState {
    pub const MAX_RECENT: usize = 64;

    pub fn default_path() -> PathBuf {
        let home = std::env::var_os("HOME").unwrap_or_default();
        PathBuf::from(home)
            .join(".local")
            .join("state")
            .join("spritz")
            .join("state.json")
    }

    pub fn load_or_default(path: &Path) -> Self {
        match fs::read_to_string(path) {
            Ok(txt) => serde_json::from_str(&txt).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save_atomic(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let body = serde_json::to_string_pretty(self)?;
        write_atomic_0600(path, body.as_bytes())
    }

    pub fn record_pick(&mut self, canon_hex: &str) {
        *self.usage_counts.entry(canon_hex.to_string()).or_insert(0) += 1;
        self.total_emoji_inserted = self.total_emoji_inserted.saturating_add(1);
        self.recent_emoji.retain(|h| h != canon_hex);
        self.recent_emoji.insert(0, canon_hex.to_string());
        if self.recent_emoji.len() > Self::MAX_RECENT {
            self.recent_emoji.truncate(Self::MAX_RECENT);
        }
    }
}

pub fn write_atomic_0600(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
        }
    }
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp_path = PathBuf::from(tmp);
    let mut f = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&tmp_path)?;
    f.write_all(bytes)?;
    f.flush()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600));
    }
    fs::rename(&tmp_path, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_and_state_roundtrip() {
        let dir = std::env::temp_dir().join(format!("spritz_cfg_test_{}", std::process::id()));
        let cfg_path = dir.join("config.toml");
        let st_path = dir.join("state.json");

        let mut cfg = SpritzConfig::default();
        cfg.skin_tone = SkinTone::Light;
        cfg.save_atomic(&cfg_path).unwrap();
        let cfg2 = SpritzConfig::load_or_default(&cfg_path);
        assert_eq!(cfg2.skin_tone, SkinTone::Light);
        assert_eq!(cfg2.voice_mode, VoiceMode::ChatGptPassthrough);

        let mut st = SpritzState::default();
        st.record_pick("1F602");
        st.record_pick("2764");
        st.record_pick("1F602");
        assert_eq!(st.total_emoji_inserted, 3);
        assert_eq!(st.usage_counts.get("1F602").copied(), Some(2));
        assert_eq!(st.recent_emoji, vec!["1F602", "2764"]);
        st.save_atomic(&st_path).unwrap();
        let st2 = SpritzState::load_or_default(&st_path);
        assert_eq!(st2.total_emoji_inserted, 3);

        let _ = fs::remove_dir_all(&dir);
    }
}
