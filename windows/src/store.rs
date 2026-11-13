//! Files on disk. Same formats as the macOS app (dictionary.json, history.json), so a dictionary can be
//! copied from one machine to the other.
//!   Windows: %APPDATA%\Pip Dictée\        (dictionary, history, settings, log — per-user, private ACL)
//!            %LOCALAPPDATA%\Pip Dictée\models\   (the Whisper model, not roamed)

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

pub const MODEL_FILE: &str = "ggml-large-v3-turbo.bin";
pub const VAD_FILE: &str = "ggml-silero-v5.1.2.bin";

pub fn data_dir() -> PathBuf { dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Pip Dictée") }
pub fn models_dir() -> PathBuf { dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("Pip Dictée").join("models") }
pub fn model_path() -> PathBuf { models_dir().join(MODEL_FILE) }
pub fn dictionary_path() -> PathBuf { data_dir().join("dictionary.json") }
pub fn history_path() -> PathBuf { data_dir().join("history.json") }
pub fn settings_path() -> PathBuf { data_dir().join("settings.json") }
pub fn log_path() -> PathBuf { data_dir().join("pip-dictee.log") }

/// Writes through a temporary file, so a crash never leaves half a file.
fn write_atomic(path: &PathBuf, data: &[u8]) {
    let _ = fs::create_dir_all(data_dir());
    let tmp = path.with_extension("tmp");
    if fs::write(&tmp, data).is_ok() && fs::rename(&tmp, path).is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

/// Never logs what was said: only events, timings and lengths.
pub fn log(s: &str) {
    let _ = fs::create_dir_all(data_dir());
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(log_path()) {
        let _ = writeln!(f, "{} {}", Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true), s);
    }
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct Dictionary {
    #[serde(default, alias = "mots")] pub words: Vec<String>,
    #[serde(default, alias = "remplacements")] pub replacements: BTreeMap<String, String>,
    #[serde(default)] pub snippets: BTreeMap<String, String>,
}

pub fn load_dictionary() -> Dictionary {
    fs::read(dictionary_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}
/// Saves the dictionary as edited in the settings window. Empty entries are dropped.
pub fn save_dictionary(d: &Dictionary) {
    let mut d = d.clone();
    d.words.retain(|w| !w.trim().is_empty());
    d.replacements.retain(|k, v| !k.trim().is_empty() && !v.trim().is_empty());
    d.snippets.retain(|k, v| !k.trim().is_empty() && !v.trim().is_empty());
    write_atomic(&dictionary_path(), &serde_json::to_vec_pretty(&d).unwrap());
}
pub fn ensure_dictionary() {
    if !dictionary_path().exists() {
        let d = Dictionary { words: ["Pip", "Claude", "TypeScript", "JavaScript", "Node.js", "YouTube"].map(String::from).to_vec(), ..Default::default() };
        write_atomic(&dictionary_path(), &serde_json::to_vec_pretty(&d).unwrap());
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Entry {
    pub text: String,
    #[serde(with = "iso8601")] pub at: DateTime<Utc>,
    pub app: Option<String>,
}
mod iso8601 {
    use super::*;
    use serde::{Deserializer, Serializer};
    pub fn serialize<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> { s.serialize_str(&d.to_rfc3339_opts(SecondsFormat::Secs, true)) }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let s = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&s).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

pub fn load_history() -> Vec<Entry> {
    fs::read(history_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}
pub fn save_history(h: &[Entry], keep: bool) {
    if !keep { let _ = fs::remove_file(history_path()); return; }
    let h: Vec<_> = h.iter().take(200).cloned().collect();
    write_atomic(&history_path(), &serde_json::to_vec_pretty(&h).unwrap());
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Trigger { CtrlWin, RightCtrl }

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Settings {
    pub lang: String,
    pub trigger: Trigger,
    pub auto_paste: bool,
    pub sounds: bool,
    pub remove_fillers: bool,
    pub keep_history: bool,
    /// "system" or a language code from shared/i18n.
    pub ui_language: String,
    pub onboarding_done: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Settings { lang: "auto".into(), trigger: Trigger::CtrlWin, auto_paste: true, sounds: true, remove_fillers: true, keep_history: true,
                   ui_language: "system".into(), onboarding_done: false }
    }
}
pub fn load_settings() -> Settings {
    fs::read(settings_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}
pub fn save_settings(s: &Settings) { write_atomic(&settings_path(), &serde_json::to_vec_pretty(s).unwrap()); }

pub const LANGUAGES: &[(&str, &str)] = &[
    ("auto", "Automatic (detect language)"), ("fr", "Français"), ("en", "English"), ("it", "Italiano"), ("de", "Deutsch"), ("es", "Español"), ("pt", "Português"),
];
