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

pub const VAD_FILE: &str = "ggml-silero-v5.1.2.bin";

/// A Whisper model Pip can use. `cost` is how much work its encoder does compared with `base` (measured on a
/// laptop CPU with whisper-bench: base 0.8 s, small 4.6 s, large-v3-turbo about 30 s), so one speed test with any
/// model predicts the others.
pub struct ModelSpec {
    pub id: &'static str,
    pub file: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
    pub cost: f64,
}

/// Most accurate first. The quantized (q8_0) small and base models are nearly as accurate as the full ones and
/// faster on a CPU; large-v3-turbo stays full precision, since the computers fast enough for it have a GPU.
pub const MODELS: &[ModelSpec] = &[
    ModelSpec { id: "large", file: "ggml-large-v3-turbo.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", bytes: 1_624_555_275, cost: 38.0 },
    ModelSpec { id: "small", file: "ggml-small-q8_0.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin",
        sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f", bytes: 264_464_607, cost: 6.0 },
    ModelSpec { id: "base", file: "ggml-base-q8_0.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin",
        sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9", bytes: 81_768_585, cost: 1.0 },
];

pub fn model_by_id(id: &str) -> Option<&'static ModelSpec> { MODELS.iter().find(|m| m.id == id) }
pub fn model_installed(m: &ModelSpec) -> bool { models_dir().join(m.file).is_file() }

/// The model in use: the one the speed test chose if it's on disk, otherwise the most accurate one on disk (so
/// installs from before the speed test keep large-v3-turbo). None until a model is downloaded.
pub fn active_model() -> Option<&'static ModelSpec> {
    model_by_id(&load_settings().model).filter(|m| model_installed(m))
        .or_else(|| MODELS.iter().find(|m| model_installed(m)))
}

/// large-v3-turbo's encoder converted for OpenVINO (Intel graphics); whisper.cpp finds it next to the model by
/// this name, and keeps its compiled form for the GPU in the "-cache" folder beside it.
pub const OV_ENCODER: [&str; 2] = ["ggml-large-v3-turbo-encoder-openvino.xml", "ggml-large-v3-turbo-encoder-openvino.bin"];
pub const OV_CACHE: &str = "ggml-large-v3-turbo-encoder-openvino-cache";

pub fn data_dir() -> PathBuf { dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Pip Dictée") }
pub fn models_dir() -> PathBuf { dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("Pip Dictée").join("models") }
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
    /// The model the speed test chose ("large", "small", "base"); empty before the first test.
    pub model: String,
    /// The speed test's prediction for the model in use, in milliseconds per 30 s of speech (0: not tested).
    pub model_ms: u64,
    /// The model the last speed test chose, which the settings mark as recommended; the user may pick another.
    pub recommended: String,
    /// How large-v3-turbo runs: "openvino" (Intel graphics, timed faster than the processor), "cpu" (tried, and
    /// OpenVINO wasn't faster or failed), or empty (not tried yet).
    pub accel: String,
    /// OpenVINO's time for 30 s of speech with large-v3-turbo, in milliseconds (0: unknown).
    pub accel_ms: u64,
}
impl Default for Settings {
    fn default() -> Self {
        Settings { lang: default_dictation_language(), trigger: Trigger::CtrlWin, auto_paste: true, sounds: true, remove_fillers: true,
                   keep_history: true, ui_language: "system".into(), onboarding_done: false, model: String::new(), model_ms: 0,
                   recommended: String::new(), accel: String::new(), accel_ms: 0 }
    }
}

/// Windows' display language when Pip knows it, else "auto". Detecting the language costs Whisper a second pass
/// over the audio, which makes every dictation about twice as slow.
fn default_dictation_language() -> String {
    let sys = crate::i18n::system_language();
    if LANGUAGES.iter().any(|(c, _)| *c == sys) { sys } else { "auto".into() }
}
pub fn load_settings() -> Settings {
    fs::read(settings_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}
pub fn save_settings(s: &Settings) { write_atomic(&settings_path(), &serde_json::to_vec_pretty(s).unwrap()); }

pub const LANGUAGES: &[(&str, &str)] = &[
    ("auto", "Automatic (detect language)"), ("fr", "Français"), ("en", "English"), ("it", "Italiano"), ("de", "Deutsch"), ("es", "Español"), ("pt", "Português"),
];
