use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum TelemetryMetric {
    FnTap,
    FnHold,
    FnCancelled,
    TapLost,
    PickerOpen,
    PickerCancel,
    InsertionAttempt,
    ClipboardFallback,
    SecureInputFallback,
    NativeBaselineFailed,
    NativeDiffMismatch,
    NativeCaptureTimeout,
    NativeTranscriptCaptured,
    RefinementStart,
    RefinementReady,
    RefinementFailure,
    RefinementCancel,
    RefinementChosen,
    RefinementCopy,
    RefinementCycle,
}

impl TelemetryMetric {
    pub fn key(self) -> &'static str {
        match self {
            Self::FnTap => "fnTap",
            Self::FnHold => "fnHold",
            Self::FnCancelled => "fnCancelled",
            Self::TapLost => "tapLost",
            Self::PickerOpen => "pickerOpen",
            Self::PickerCancel => "pickerCancel",
            Self::InsertionAttempt => "insertionAttempt",
            Self::ClipboardFallback => "clipboardFallback",
            Self::SecureInputFallback => "secureInputFallback",
            Self::NativeBaselineFailed => "nativeBaselineFailed",
            Self::NativeDiffMismatch => "nativeDiffMismatch",
            Self::NativeCaptureTimeout => "nativeCaptureTimeout",
            Self::NativeTranscriptCaptured => "nativeTranscriptCaptured",
            Self::RefinementStart => "refinementStart",
            Self::RefinementReady => "refinementReady",
            Self::RefinementFailure => "refinementFailure",
            Self::RefinementCancel => "refinementCancel",
            Self::RefinementChosen => "refinementChosen",
            Self::RefinementCopy => "refinementCopy",
            Self::RefinementCycle => "refinementCycle",
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricBucket {
    #[serde(default)]
    pub count: u64,
    #[serde(default)]
    pub timed_count: u64,
    #[serde(default)]
    pub total_ms: f64,
    #[serde(default)]
    pub max_ms: f64,
}

impl MetricBucket {
    pub fn record(&mut self, duration_ms: Option<f64>) {
        self.count += 1;
        if let Some(ms) = duration_ms {
            if ms.is_finite() && ms >= 0.0 {
                self.timed_count += 1;
                self.total_ms += ms;
                if ms > self.max_ms {
                    self.max_ms = ms;
                }
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryStore {
    #[serde(default = "default_schema")]
    pub schema: u32,
    #[serde(default)]
    pub days: BTreeMap<String, BTreeMap<String, MetricBucket>>,
}

fn default_schema() -> u32 {
    1
}

impl Default for TelemetryStore {
    fn default() -> Self {
        Self {
            schema: 1,
            days: BTreeMap::new(),
        }
    }
}

impl TelemetryStore {
    pub const RETENTION_DAYS: i64 = 90;

    pub fn utc_day_now() -> i64 {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        (secs / 86_400) as i64
    }

    pub fn load_or_default(path: &Path) -> Self {
        match fs::read_to_string(path) {
            Ok(txt) => serde_json::from_str(&txt).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn record_at_day(
        &mut self,
        day: i64,
        metric: TelemetryMetric,
        duration_ms: Option<f64>,
    ) {
        self.prune(day);
        let day_key = day.to_string();
        let entry = self
            .days
            .entry(day_key)
            .or_default()
            .entry(metric.key().to_string())
            .or_default();
        entry.record(duration_ms);
    }

    pub fn prune(&mut self, current_day: i64) {
        let cutoff = current_day - (Self::RETENTION_DAYS - 1);
        self.days
            .retain(|k, _| k.parse::<i64>().map_or(false, |d| d >= cutoff));
    }

    pub fn save_atomic(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_string_pretty(self)?;
        let tmp = tmp_sibling(path);
        let mut f = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp)?;
        f.write_all(data.as_bytes())?;
        f.flush()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
        }
        fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn format_report(&self) -> String {
        if self.days.is_empty() {
            return "No local operational telemetry recorded yet.\n".to_string();
        }
        let mut totals: BTreeMap<String, MetricBucket> = BTreeMap::new();
        for metrics in self.days.values() {
            for (name, bucket) in metrics {
                let agg = totals.entry(name.clone()).or_default();
                agg.count += bucket.count;
                agg.timed_count += bucket.timed_count;
                agg.total_ms += bucket.total_ms;
                if bucket.max_ms > agg.max_ms {
                    agg.max_ms = bucket.max_ms;
                }
            }
        }
        let mut out = format!(
            "Spritz local operational telemetry ({} UTC day buckets, 90-day retention)\n",
            self.days.len()
        );
        for (name, b) in totals {
            if b.timed_count > 0 {
                let avg = b.total_ms / b.timed_count as f64;
                out.push_str(&format!(
                    "  {name}: count={} avg={avg:.1}ms max={:.1}ms\n",
                    b.count, b.max_ms
                ));
            } else {
                out.push_str(&format!("  {name}: count={}\n", b.count));
            }
        }
        out
    }
}

pub fn default_telemetry_path() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Spritz")
        .join("telemetry.json")
}

fn tmp_sibling(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".tmp");
    PathBuf::from(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telemetry_prunes_beyond_90_days_and_formats_report() {
        let mut store = TelemetryStore::default();
        store.record_at_day(100, TelemetryMetric::PickerOpen, None);
        store.record_at_day(200, TelemetryMetric::RefinementReady, Some(420.5));
        assert!(!store.days.contains_key("100"));
        assert!(store.days.contains_key("200"));
        let report = store.format_report();
        assert!(report.contains("refinementReady: count=1 avg=420.5ms max=420.5ms"));
    }
}
