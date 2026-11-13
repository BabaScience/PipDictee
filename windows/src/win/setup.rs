//! First-launch downloads: whisper.cpp (the engine), the Whisper model and the voice-detection model.
//! Every file is pinned by SHA-256 (same values as scripts/setup-windows.ps1), downloaded over HTTPS only with
//! Windows' own TLS (schannel), written to a ".part" file, and moved into place only once its hash matches.
//! Archives are unpacked by file name only (no folders), so a crafted path can't escape the target folder.

use crate::store::{log, models_dir, MODEL_FILE, VAD_FILE};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage { Engine, Model, Vad }
impl Stage {
    pub fn key(self) -> &'static str { match self { Stage::Engine => "engine", Stage::Model => "model", Stage::Vad => "vad" } }
}

struct Item { stage: Stage, url: &'static str, sha256: &'static str, bytes: u64 }

const ENGINE: Item = Item {
    stage: Stage::Engine,
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-bin-x64.zip",
    sha256: "74f973345cb52ef5ba3ec9e7e7af8e48cc8c71722d1528603b80588a11f82e3e",
    bytes: 4_078_768,
};
const MODEL: Item = Item {
    stage: Stage::Model,
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    bytes: 1_624_555_275,
};
const VAD: Item = Item {
    stage: Stage::Vad,
    url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin",
    sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
    bytes: 885_098,
};

/// Where whisper-server.exe and its DLLs go (one of the places whisper.rs looks).
pub fn bin_dir() -> PathBuf { models_dir().parent().map(Path::to_path_buf).unwrap_or_else(models_dir).join("bin") }

pub fn engine_installed() -> bool { bin_dir().join("whisper-server.exe").is_file() }
pub fn model_installed() -> bool { models_dir().join(MODEL_FILE).is_file() }

/// Downloads whatever is missing. `progress(stage, done, total)` is called often; `cancel` stops it cleanly.
pub fn run(cancel: Arc<AtomicBool>, progress: impl Fn(Stage, u64, u64)) -> Result<(), String> {
    let tls = native_tls::TlsConnector::new().map_err(|e| e.to_string())?;
    let agent = ureq::AgentBuilder::new()
        .tls_connector(Arc::new(tls))
        .https_only(true)
        .timeout_connect(Duration::from_secs(20))
        .timeout_read(Duration::from_secs(60))
        .build();
    fs::create_dir_all(models_dir()).map_err(|e| e.to_string())?;
    fs::create_dir_all(bin_dir()).map_err(|e| e.to_string())?;

    if !engine_installed() {
        let zip = std::env::temp_dir().join("pip-dictee-whisper.zip");
        fetch(&agent, &ENGINE, &zip, &cancel, &progress)?;
        let r = unpack(&zip, &bin_dir());
        let _ = fs::remove_file(&zip);
        r?;
        if !engine_installed() { return Err("whisper-server.exe was not in the archive".into()); }
    }
    if !model_installed() { fetch(&agent, &MODEL, &models_dir().join(MODEL_FILE), &cancel, &progress)?; }
    if !models_dir().join(VAD_FILE).is_file() {
        // Optional: dictation works without it, so a failure here isn't fatal.
        if let Err(e) = fetch(&agent, &VAD, &models_dir().join(VAD_FILE), &cancel, &progress) { log(&format!("voice detection model: {e}")); }
    }
    Ok(())
}

fn fetch(agent: &ureq::Agent, item: &Item, dest: &Path, cancel: &AtomicBool, progress: &impl Fn(Stage, u64, u64)) -> Result<(), String> {
    let part = dest.with_extension("part");
    let resp = agent.get(item.url).call().map_err(|e| e.to_string())?;
    let total = resp.header("Content-Length").and_then(|v| v.parse().ok()).unwrap_or(item.bytes);
    let mut reader = resp.into_reader();
    let mut file = File::create(&part).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let (mut done, mut last) = (0u64, 0u64);
    progress(item.stage, 0, total);
    loop {
        if cancel.load(Relaxed) {
            drop(file); let _ = fs::remove_file(&part);
            return Err("cancelled".into());
        }
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 { break; }
        hasher.update(&buf[..n]);
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if done - last > 2 << 20 { progress(item.stage, done, total); last = done; }
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);
    let got: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if got != item.sha256 {
        let _ = fs::remove_file(&part);
        log(&format!("checksum mismatch for {}", item.url));
        return Err(crate::i18n::t("The download didn't match its checksum, so it was deleted."));
    }
    let _ = fs::remove_file(dest);
    fs::rename(&part, dest).map_err(|e| e.to_string())?;
    progress(item.stage, total, total);
    log(&format!("downloaded and verified: {}", dest.file_name().unwrap_or_default().to_string_lossy()));
    Ok(())
}

/// Copies the .exe and .dll files of the archive into `to`, by file name only.
fn unpack(zip_path: &Path, to: &Path) -> Result<(), String> {
    let mut zip = zip::ZipArchive::new(File::open(zip_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
        if entry.is_dir() { continue; }
        let Ok(raw) = entry.name().map(|n| n.to_string()) else { continue };
        // Both separators: archives made on Windows may use backslashes.
        let Some(name) = raw.rsplit(['/', '\\']).next().filter(|n| !n.is_empty() && *n != "..").map(str::to_string) else { continue };
        let lower = name.to_lowercase();
        if !(lower.ends_with(".exe") || lower.ends_with(".dll")) { continue; }
        let mut out = File::create(to.join(&name)).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// "1.0 GB", "350 MB", in the interface language's decimal style.
pub fn size(bytes: u64) -> String {
    let comma = matches!(crate::i18n::current().as_str(), "fr" | "de" | "it" | "es" | "pt");
    let s = if bytes >= 1 << 30 { format!("{:.1} GB", bytes as f64 / (1u64 << 30) as f64) } else { format!("{} MB", bytes >> 20) };
    if comma { s.replace('.', ",") } else { s }
}
