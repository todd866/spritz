use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QuickEmojiEntry {
    pub glyph: String,
    pub hex: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TouchBarLoginReceipt {
    pub status: i32,
    pub error: String,
    pub t: u64,
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub process: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TouchBarRequestResult {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub status: String,
    pub t: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_to_visible_ms: Option<f64>,
}

/// Signature payload written atomically to `~/.local/state/spritz/touchbar-state.json`.
/// Never includes focused text, selection contents, or clipboard data.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TouchBarSignature {
    pub schema: u32,
    pub pid: i32,
    #[serde(rename = "instanceID")]
    pub instance_id: String,
    #[serde(rename = "frontPID")]
    pub front_pid: i32,
    pub front_bundle: String,
    pub focus_generation: u64,
    pub accessibility: bool,
    pub input_monitoring: bool,
    pub known: bool,
    pub editable: bool,
    pub secure: bool,
    pub selection_known: bool,
    pub has_selection: bool,
    pub picker_visible: bool,
    pub active: bool,
    pub quick_emoji: Vec<QuickEmojiEntry>,
    pub login_status: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub login: Option<TouchBarLoginReceipt>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_request: Option<TouchBarRequestResult>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TouchBarEnvelope {
    #[serde(flatten)]
    pub sig: TouchBarSignature,
    pub t: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TouchBarIncomingRequest {
    pub command: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub issued_at: f64,
    #[serde(rename = "expectedPID")]
    pub expected_pid: Option<i32>,
    pub focus_generation: Option<u64>,
    #[serde(rename = "instanceID")]
    pub instance_id: Option<String>,
    pub hex: Option<String>,
}

pub struct TouchBarRequestPolicy;

impl TouchBarRequestPolicy {
    pub const MAX_HANDLED_IDS: usize = 64;

    pub fn is_text_role(role: Option<&str>) -> bool {
        matches!(
            role,
            Some("AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField")
        )
    }

    pub fn valid_age(issued_at: f64, now_epoch_secs: f64) -> bool {
        if !issued_at.is_finite() || !now_epoch_secs.is_finite() {
            return false;
        }
        let age = now_epoch_secs - issued_at;
        (-0.25..=2.0).contains(&age)
    }
}

#[derive(Debug, Default)]
pub struct HandledRequestRing {
    ids: VecDeque<String>,
}

impl HandledRequestRing {
    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|x| x == id)
    }

    pub fn record(&mut self, id: String) {
        if id.is_empty() || self.contains(&id) {
            return;
        }
        if self.ids.len() >= TouchBarRequestPolicy::MAX_HANDLED_IDS {
            self.ids.pop_front();
        }
        self.ids.push_back(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn touchbar_policy_and_serialization() {
        assert!(TouchBarRequestPolicy::is_text_role(Some("AXTextField")));
        assert!(!TouchBarRequestPolicy::is_text_role(Some("AXSecureTextField")));
        assert!(TouchBarRequestPolicy::valid_age(100.0, 100.5));
        assert!(TouchBarRequestPolicy::valid_age(100.2, 100.0));
        assert!(!TouchBarRequestPolicy::valid_age(100.0, 102.5));
        assert!(!TouchBarRequestPolicy::valid_age(f64::NAN, 100.0));

        let mut ring = HandledRequestRing::default();
        for i in 0..70 {
            ring.record(format!("id-{i}"));
        }
        assert!(!ring.contains("id-0"));
        assert!(ring.contains("id-69"));

        let env = TouchBarEnvelope {
            sig: TouchBarSignature {
                schema: 1,
                pid: 42,
                instance_id: "inst".to_string(),
                front_pid: 99,
                front_bundle: "com.google.Chrome".to_string(),
                focus_generation: 7,
                accessibility: true,
                input_monitoring: true,
                known: true,
                editable: true,
                secure: false,
                selection_known: false,
                has_selection: false,
                picker_visible: false,
                active: true,
                quick_emoji: vec![QuickEmojiEntry {
                    glyph: "😂".to_string(),
                    hex: "1F602".to_string(),
                    label: "face with tears of joy".to_string(),
                }],
                login_status: 1,
                login: None,
                last_request: None,
            },
            t: 1795509821.5,
        };
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(v["schema"], 1);
        assert_eq!(v["frontPID"], 99);
        assert_eq!(v["instanceID"], "inst");
        assert_eq!(v["quickEmoji"][0]["hex"], "1F602");
    }
}
