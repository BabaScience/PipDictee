//! First-launch downloads: whisper.cpp (the engine), the Whisper model and the voice-detection model.
//! Every file is pinned by SHA-256 (same values as scripts/setup-windows.ps1), downloaded over HTTPS only with
//! Windows' own TLS (schannel), written to a ".part" file, and moved into place only once its hash matches.
//! Archives are unpacked by file name only (no folders), so a crafted path can't escape the target folder.
//!
//! Which Whisper model: a speed test. Pip times the model it has (or downloads the smallest one to time), predicts
//! from that how long each model would take on this PC, and keeps the most accurate one that stays quick. So a PC
//! with a good GPU gets large-v3-turbo and a laptop running on its processor alone gets a smaller model, without a
//! list of hardware to keep up to date.

use super::whisper::{find_tool, threads, CREATE_NO_WINDOW};
use crate::store::{self, log, models_dir, ModelSpec, MODELS, VAD_FILE};
use sha2::{Digest, Sha256};
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage { Engine, Model, Vad, SpeedTest }
impl Stage {
    pub fn key(self) -> &'static str {
        match self { Stage::Engine => "engine", Stage::Model => "model", Stage::Vad => "vad", Stage::SpeedTest => "speedTest" }
    }
}

struct Item { stage: Stage, url: &'static str, sha256: &'static str, bytes: u64 }
impl Item {
    fn model(m: &ModelSpec) -> Item { Item { stage: Stage::Model, url: m.url, sha256: m.sha256, bytes: m.bytes } }
}

const ENGINE: Item = Item {
    stage: Stage::Engine,
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-bin-x64.zip",
    sha256: "74f973345cb52ef5ba3ec9e7e7af8e48cc8c71722d1528603b80588a11f82e3e",
    bytes: 4_078_768,
};
const VAD: Item = Item {
    stage: Stage::Vad,
    url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin",
    sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
    bytes: 885_098,
};

/// The OpenVINO downloads, built by scripts/build-openvino-windows.ps1 (whisper.cpp publishes no OpenVINO build).
macro_rules! openvino_url { ($file:literal) => { concat!("https://huggingface.co/BambaBa/whisper-openvino/resolve/main/", $file) } }
const OV_ENGINE: Item = Item { stage: Stage::Engine, url: openvino_url!("whisper-openvino-x64.zip"),
    sha256: "bd58c927183d3754168d651c3978eeedb2bf9b0239e7c8a8c56bbde29a810f42", bytes: 30_357_363 };
/// In the order of store::OV_ENCODER.
const OV_FILES: [Item; 2] = [
    Item { stage: Stage::Model, url: openvino_url!("ggml-large-v3-turbo-encoder-openvino.xml"),
        sha256: "a8ff1bb731854ff269c58b868b92914e53a100de329fb3ed524a1e0a90c59fa7", bytes: 1_399_144 },
    Item { stage: Stage::Model, url: openvino_url!("ggml-large-v3-turbo-encoder-openvino.bin"),
        sha256: "f979a103cf3a3270b2009f2ac8f97a9321a09b647eaf1676810ddcaf0258dd84", bytes: 1_273_938_132 },
];

/// Where whisper-server.exe and its DLLs go (one of the places whisper.rs looks).
pub fn bin_dir() -> PathBuf { models_dir().parent().map(Path::to_path_buf).unwrap_or_else(models_dir).join("bin") }
/// The OpenVINO build of the same tools: its whisper.dll differs, so it has a folder of its own.
pub fn ov_bin_dir() -> PathBuf { models_dir().parent().map(Path::to_path_buf).unwrap_or_else(models_dir).join("bin-openvino") }

pub fn engine_installed() -> bool { bin_dir().join("whisper-server.exe").is_file() }
pub fn openvino_installed() -> bool {
    ov_bin_dir().join("whisper-server.exe").is_file() && store::OV_ENCODER.iter().all(|f| models_dir().join(f).is_file())
}

/// Whether the PC has Intel graphics, the only GPUs OpenVINO drives. Software adapters (Microsoft Basic Render
/// Driver) don't count.
pub fn intel_gpu() -> bool {
    use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE};
    unsafe {
        let Ok(factory) = CreateDXGIFactory1::<IDXGIFactory1>() else { return false };
        (0..16).map_while(|i| factory.EnumAdapters1(i).ok()).any(|a| {
            a.GetDesc1().is_ok_and(|d| d.VendorId == 0x8086 && d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 == 0)
        })
    }
}

/// How long a model may take for 30 s of speech, in milliseconds, to be chosen (base has no limit). A dictation
/// of a few seconds takes about this long too, since Whisper always works on 30 s windows.
const BUDGET_MS: &[(&str, f64)] = &[("large", 2500.0), ("small", 6000.0)];

/// What setup ended with: the model to use, its predicted time for 30 s of speech on the processor (0: unknown),
/// whether a speed test chose it (then it's also the recommended model), and how large-v3-turbo should run.
pub struct Choice { pub model: &'static ModelSpec, pub ms: u64, pub tested: bool, pub accel: Accel }

/// The OpenVINO decision for large-v3-turbo, to save in the settings (`accel`, `accel_ms`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Accel {
    /// Nothing decided this time (not large-v3-turbo, no Intel graphics, or the download failed): keep the settings.
    Unchanged,
    /// Tried: the processor is as fast, or OpenVINO didn't work here.
    Cpu,
    /// Faster on the Intel graphics: this many milliseconds for 30 s of speech.
    OpenVino(u64),
}

/// What setup is asked to do, besides installing what's missing.
#[derive(Clone, Copy)]
pub enum Goal {
    /// First setup: test the speed and pick a model, unless one is already in use.
    Setup,
    /// "Test speed again" in the settings.
    Retest,
    /// The user picked this model in the settings: download it if needed, no test.
    Switch(&'static ModelSpec),
}

/// The predicted time of `m`, scaled from the last speed test's prediction for the model in use.
fn predicted_ms(m: &ModelSpec) -> u64 {
    let s = store::load_settings();
    match (s.model_ms, store::model_by_id(&s.model)) {
        (ms, Some(cur)) if ms > 0 => (ms as f64 / cur.cost * m.cost) as u64,
        _ => 0,
    }
}

/// Downloads whatever is missing and picks the model (see `Goal`). `progress(stage, done, total)` is called
/// often; `cancel` stops it cleanly.
pub fn run(cancel: Arc<AtomicBool>, goal: Goal, progress: impl Fn(Stage, u64, u64)) -> Result<Choice, String> {
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
    if !models_dir().join(VAD_FILE).is_file() {
        // Optional: dictation works without it, so a failure here isn't fatal.
        if let Err(e) = fetch(&agent, &VAD, &models_dir().join(VAD_FILE), &cancel, &progress) { log(&format!("voice detection model: {e}")); }
    }
    let mut choice = pick(&agent, goal, &cancel, &progress)?;
    if choice.model.id == "large" { choice.accel = accelerate(&agent, goal, choice.ms, &cancel, &progress)?; }
    Ok(choice)
}

/// Which model to use (see `Goal`), downloading it if needed.
fn pick(agent: &ureq::Agent, goal: Goal, cancel: &AtomicBool, progress: &impl Fn(Stage, u64, u64)) -> Result<Choice, String> {
    match goal {
        Goal::Switch(m) => {
            if !store::model_installed(m) { fetch(agent, &Item::model(m), &models_dir().join(m.file), cancel, progress)?; }
            log(&format!("model chosen in the settings: {}", m.id));
            return Ok(Choice { model: m, ms: predicted_ms(m), tested: false, accel: Accel::Unchanged });
        }
        // Already set up: keep the model in use. Installs from before the speed test keep large-v3-turbo until
        // someone asks for a test in the settings.
        Goal::Setup => if let Some(m) = store::active_model() {
            return Ok(Choice { model: m, ms: store::load_settings().model_ms, tested: false, accel: Accel::Unchanged });
        },
        Goal::Retest => {}
    }

    // Time the cheapest model on disk, or download the smallest one (82 MB) to time.
    let probe = match MODELS.iter().rev().find(|m| store::model_installed(m)) {
        Some(m) => m,
        None => {
            let m = MODELS.last().expect("models");
            fetch(&agent, &Item::model(m), &models_dir().join(m.file), &cancel, &progress)?;
            m
        }
    };
    // A small model's time over-predicts a big one's on a GPU (fixed costs weigh more), so each step up is
    // confirmed by timing the bigger model itself: at most base → small → large.
    let mut tested = probe;
    let mut choice: Option<Choice> = None;
    for _ in 0..MODELS.len() {
        if cancel.load(Relaxed) { return Err("cancelled".into()); }
        progress(Stage::SpeedTest, 0, 1);
        let ms = match speed_test(tested) {
            Ok(ms) => ms,
            Err(e) => { log(&format!("speed test failed with {}: {e}", tested.id)); break; }
        };
        let model = choose(ms as f64 / tested.cost);
        let predicted = (ms as f64 / tested.cost * model.cost) as u64;
        log(&format!("speed test: {} takes {ms} ms for 30 s of speech; best fit {} (about {predicted} ms)", tested.id, model.id));
        choice = Some(Choice { model, ms: predicted, tested: true, accel: Accel::Unchanged });
        if model.id == tested.id || model.cost < tested.cost { break; }   // confirmed, or a step down: no need to time it
        if !store::model_installed(model) {
            fetch(&agent, &Item::model(model), &models_dir().join(model.file), &cancel, &progress)?;
        }
        tested = model;
    }
    let choice = choice.unwrap_or_else(|| {
        // Couldn't measure: the middle model is acceptable almost everywhere.
        log("speed test: no result; choosing small");
        Choice { model: store::model_by_id("small").expect("small"), ms: 0, tested: false, accel: Accel::Unchanged }
    });
    progress(Stage::SpeedTest, 1, 1);
    if !store::model_installed(choice.model) {
        fetch(&agent, &Item::model(choice.model), &models_dir().join(choice.model.file), &cancel, &progress)?;
    }
    log(&format!("model chosen: {}", choice.model.id));
    Ok(choice)
}

/// The most accurate model that fits its budget, given the measured milliseconds per unit of `cost`.
fn choose(ms_per_cost: f64) -> &'static ModelSpec {
    MODELS.iter()
        .find(|m| BUDGET_MS.iter().any(|(id, budget)| *id == m.id && ms_per_cost * m.cost <= *budget))
        .unwrap_or(MODELS.last().expect("models"))
}

/// Decides how large-v3-turbo runs on this PC. With Intel graphics, Pip downloads the OpenVINO build and encoder
/// (once), times them, and uses them only if they beat the processor's `cpu_ms`. A decision stands until "Test
/// speed again"; a failed download decides nothing, so the next time tries again.
fn accelerate(agent: &ureq::Agent, goal: Goal, cpu_ms: u64, cancel: &AtomicBool, progress: &impl Fn(Stage, u64, u64)) -> Result<Accel, String> {
    let s = store::load_settings();
    let retest = matches!(goal, Goal::Retest);
    if !retest && s.accel == "openvino" && openvino_installed() { return Ok(Accel::OpenVino(s.accel_ms)); }
    if !retest && s.accel == "cpu" { return Ok(Accel::Unchanged); }
    if !intel_gpu() { return Ok(Accel::Unchanged); }
    if !openvino_installed() {
        let got = (|| {
            fs::create_dir_all(ov_bin_dir()).map_err(|e| e.to_string())?;
            let zip = std::env::temp_dir().join("pip-dictee-whisper-openvino.zip");
            fetch(agent, &OV_ENGINE, &zip, cancel, progress)?;
            let r = unpack(&zip, &ov_bin_dir());
            let _ = fs::remove_file(&zip);
            r?;
            for (item, file) in OV_FILES.iter().zip(store::OV_ENCODER) { fetch(agent, item, &models_dir().join(file), cancel, progress)?; }
            Ok::<(), String>(())
        })();
        match got {
            Err(e) if e == "cancelled" => return Err(e),
            Err(e) => { log(&format!("OpenVINO download: {e}")); return Ok(Accel::Unchanged); }
            Ok(()) if !openvino_installed() => { log("OpenVINO: whisper-server.exe was not in the archive"); return Ok(Accel::Unchanged); }
            Ok(()) => {}
        }
    }
    progress(Stage::SpeedTest, 0, 1);
    let accel = match ov_speed_test() {
        Ok(ms) if cpu_ms == 0 || ms < cpu_ms => { log(&format!("OpenVINO (Intel graphics): {ms} ms for 30 s of speech, processor about {cpu_ms} ms; using OpenVINO")); Accel::OpenVino(ms) }
        Ok(ms) => { log(&format!("OpenVINO (Intel graphics): {ms} ms, processor about {cpu_ms} ms; keeping the processor")); Accel::Cpu }
        Err(e) => { log(&format!("OpenVINO speed test failed: {e}")); Accel::Cpu }
    };
    progress(Stage::SpeedTest, 1, 1);
    Ok(accel)
}

/// The OpenVINO encoder's time on the Intel graphics for 30 s of audio. whisper-bench can't use OpenVINO, so
/// whisper-cli transcribes a second of silence and reports its timings. The first run also compiles the encoder
/// for this GPU (cached next to it), which is why the engine starts faster afterwards.
fn ov_speed_test() -> Result<u64, String> {
    const WAV: &str = "pip-dictee-speedtest.wav";
    let large = store::model_by_id("large").ok_or("no large model")?;
    let spec = hound::WavSpec { channels: 1, sample_rate: 16_000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(models_dir().join(WAV), spec).map_err(|e| e.to_string())?;
    for _ in 0..16_000 { w.write_sample(0i16).map_err(|e| e.to_string())?; }
    w.finalize().map_err(|e| e.to_string())?;
    let out = Command::new(ov_bin_dir().join("whisper-cli.exe")).current_dir(models_dir())
        .args(["-m", large.file, "-f", WAV, "-l", "en", "-nt", "-t", &threads().to_string(), "-oved", "GPU"])
        .stdin(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output();
    let _ = fs::remove_file(models_dir().join(WAV));
    let out = out.map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stderr).into_owned();
    if !text.contains("OpenVINO model loaded") { return Err(format!("the encoder didn't load (exit {:?})", out.status.code())); }
    parse_encode_ms(&text).ok_or_else(|| format!("no timing in whisper-cli's output (exit {:?})", out.status.code()))
}

/// Milliseconds the model's encoder takes for 30 s of audio on this PC, as whisper-bench measures it: the
/// expensive part of every dictation. Runs inside the models folder with a file name only (see whisper.rs).
fn speed_test(m: &ModelSpec) -> Result<u64, String> {
    let bin = find_tool("whisper-bench").ok_or("whisper-bench.exe not found")?;
    let out = Command::new(bin).current_dir(models_dir())
        .args(["-m", m.file, "-t", &threads().to_string(), "-w", "0"])
        .stdin(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stderr).into_owned() + &String::from_utf8_lossy(&out.stdout);
    parse_encode_ms(&text).ok_or_else(|| format!("no timing in whisper-bench's output (exit {:?})", out.status.code()))
}

/// "whisper_print_timings:   encode time =   788.03 ms /     1 runs (   788.03 ms per run)" → 788
fn parse_encode_ms(text: &str) -> Option<u64> {
    let line = text.lines().find(|l| l.contains("encode time"))?;
    let v: f64 = line.split('=').nth(1)?.split_whitespace().next()?.parse().ok()?;
    Some(v.round() as u64)
}

/// Deletes the models other than `keep`. The server must not be using them: Windows can't delete an open file.
pub fn remove_other_models(keep: &ModelSpec) {
    for m in MODELS.iter().filter(|m| m.id != keep.id) {
        let path = models_dir().join(m.file);
        if !path.is_file() { continue; }
        match fs::remove_file(&path) {
            Ok(()) => log(&format!("removed the unused model {}", m.file)),
            Err(e) => log(&format!("couldn't remove {}: {e}", m.file)),
        }
    }
    // The OpenVINO files only serve large-v3-turbo.
    if keep.id != "large" && (models_dir().join(store::OV_ENCODER[1]).is_file() || ov_bin_dir().is_dir()) {
        for f in store::OV_ENCODER { let _ = fs::remove_file(models_dir().join(f)); }
        let _ = fs::remove_dir_all(models_dir().join(store::OV_CACHE));
        let _ = fs::remove_dir_all(ov_bin_dir());
        log("removed the OpenVINO files");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_whisper_bench() {
        let out = "whisper_print_timings:   encode time =   788.03 ms /     1 runs (   788.03 ms per run)\n";
        assert_eq!(parse_encode_ms(out), Some(788));
        assert_eq!(parse_encode_ms("nothing here"), None);
    }

    #[test]
    fn chooses_by_speed() {
        // A laptop CPU (this test's numbers came from one): base 790 ms, so small ≈ 4.7 s and large ≈ 30 s.
        assert_eq!(choose(790.0).id, "small");
        // A GPU: large ≈ 1.1 s.
        assert_eq!(choose(30.0).id, "large");
        // A slow, old CPU: small would take 12 s.
        assert_eq!(choose(2000.0).id, "base");
    }
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
