use crate::cf::{epoch_secs, monotonic_uptime_secs};
use spritz_core::config::write_atomic_0600;
use spritz_core::touchbar::{TouchBarEnvelope, TouchBarSignature};
use std::path::PathBuf;

pub fn state_path() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join(".local")
        .join("state")
        .join("spritz")
        .join("touchbar-state.json")
}

#[derive(Default)]
pub struct TouchBarWriter {
    last_sig_json: Option<Vec<u8>>,
    last_written_at: f64,
}

impl TouchBarWriter {
    /// Writes `~/.local/state/spritz/touchbar-state.json` atomically (`0600`)
    /// with 4.5s signature deduplication. Returns serialized envelope JSON when written
    /// so Swift can post the `DistributedNotificationCenter` notification.
    pub fn write_if_changed(&mut self, sig: &TouchBarSignature, force: bool) -> Option<String> {
        let sig_bytes = serde_json::to_vec(sig).ok()?;
        let now = monotonic_uptime_secs();
        if !force
            && self.last_sig_json.as_ref() == Some(&sig_bytes)
            && (now - self.last_written_at) < 4.5
        {
            return None;
        }
        let env = TouchBarEnvelope {
            sig: sig.clone(),
            t: epoch_secs(),
        };
        let payload = serde_json::to_string(&env).ok()?;
        if write_atomic_0600(&state_path(), payload.as_bytes()).is_ok() {
            self.last_sig_json = Some(sig_bytes);
            self.last_written_at = now;
            Some(payload)
        } else {
            None
        }
    }
}
