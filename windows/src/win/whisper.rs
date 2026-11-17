//! whisper.cpp, kept loaded in a local server (127.0.0.1 only); whisper-cli.exe as a fallback.
//! The executables are only looked for next to PipDictee.exe or in %LOCALAPPDATA%\Pip Dictée\bin — never on
//! PATH, so a stray whisper-server.exe elsewhere can't be picked up. The server lives in a Job Object: it dies
//! with the app, even if the app is killed.
//!
//! Paths with accents: whisper.cpp reads its command line in the Windows code page but opens the model as if the
//! path were UTF-8, and aborts on anything else, so "Pip Dictée" (or a user name like "José") crashed it. The
//! tools therefore run *inside* the models folder and only ever get plain file names, never a full path.

use super::setup;
use crate::cleanup::{find_pauses, join_segments};
use crate::store::{active_model, load_settings, log, models_dir, ModelSpec, VAD_FILE};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::JobObjects::*;

pub const PORT: u16 = 18765;
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// The recording, copied next to the models for whisper-cli (see the note at the top).
const CLI_WAV: &str = "pip-dictee-take.wav";

/// "exit code 0xC0000409 (aborted)": enough to tell a crash from a missing DLL in the log, without any content.
fn exit_reason(st: ExitStatus) -> String {
    let Some(code) = st.code() else { return "no exit code".into() };
    let hint = match code as u32 {
        0xC000_0409 => " (aborted)",
        0xC000_0135 => " (a DLL is missing)",
        0xC000_001D => " (this CPU lacks an instruction it needs)",
        0xC000_0005 => " (access violation)",
        0xC000_0017 | 0xC000_009A => " (out of memory)",
        _ => "",
    };
    format!("exit code 0x{:08X}{hint}", code as u32)
}

/// How many threads whisper.cpp gets: the number of the processor's fastest cores (the performance cores on
/// Intel's hybrid chips, every core elsewhere), between 2 and 8. Efficiency cores and hyper-threads add little and
/// can slow it down. Measured once.
pub fn threads() -> usize {
    static N: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *N.get_or_init(|| {
        let n = fastest_cores().unwrap_or_else(|| std::thread::available_parallelism().map_or(4, |n| n.get() / 2));
        n.clamp(2, 8)
    })
}

/// Counts the cores in the highest efficiency class (Windows numbers them: the higher, the faster).
fn fastest_cores() -> Option<usize> {
    use windows::Win32::System::SystemInformation::{GetLogicalProcessorInformationEx, RelationProcessorCore, SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX};
    unsafe {
        let mut len = 0u32;
        let _ = GetLogicalProcessorInformationEx(RelationProcessorCore, None, &mut len);
        if len == 0 { return None; }
        let mut buf = vec![0u64; (len as usize).div_ceil(8)];   // u64: the records need 8-byte alignment
        GetLogicalProcessorInformationEx(RelationProcessorCore, Some(buf.as_mut_ptr().cast()), &mut len).ok()?;
        let base = buf.as_ptr().cast::<u8>();
        let (mut counts, mut off) = ([0usize; 256], 0usize);
        while off + std::mem::size_of::<SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>() <= len as usize {
            let info = &*base.add(off).cast::<SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>();
            if info.Relationship == RelationProcessorCore {
                counts[info.Anonymous.Processor.EfficiencyClass as usize] += 1;
            }
            if info.Size == 0 { break; }
            off += info.Size as usize;
        }
        counts.iter().rposition(|&c| c > 0).map(|i| counts[i])
    }
}

pub fn find_tool(name: &str) -> Option<PathBuf> {
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let file = format!("{name}.exe");
    [exe_dir.join("whisper").join(&file), exe_dir.join(&file), models_dir().parent()?.join("bin").join(&file)]
        .into_iter().find(|p| p.is_file())
}

pub struct Whisper {
    child: Mutex<Option<Child>>,
    ready: AtomicBool,
    stopping: AtomicBool,
    /// Bumped by every start, so a watcher left over from before a restart knows to stop.
    generation: AtomicU64,
    /// The running server is the OpenVINO build; and whether that build failed to start (then it isn't retried).
    openvino: AtomicBool,
    openvino_failed: AtomicBool,
    job: Option<HANDLE>,
    on_ready: Mutex<Option<Box<dyn Fn(bool) + Send>>>,
}
unsafe impl Send for Whisper {}
unsafe impl Sync for Whisper {}

impl Whisper {
    pub fn new() -> Arc<Whisper> {
        let job = unsafe {
            CreateJobObjectW(None, None).ok().inspect(|&j| {
                let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let _ = SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info as *const _ as *const _,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32);
            })
        };
        Arc::new(Whisper { child: Mutex::new(None), ready: AtomicBool::new(false), stopping: AtomicBool::new(false), generation: AtomicU64::new(0), openvino: AtomicBool::new(false), openvino_failed: AtomicBool::new(false), job, on_ready: Mutex::new(None) })
    }

    pub fn is_ready(&self) -> bool { self.ready.load(SeqCst) }

    /// Told when the server becomes ready or stops (the panel shows it).
    pub fn set_on_ready(&self, f: impl Fn(bool) + Send + 'static) { *self.on_ready.lock().unwrap() = Some(Box::new(f)); }
    fn set_ready(&self, r: bool) {
        if self.ready.swap(r, SeqCst) != r { if let Some(f) = self.on_ready.lock().unwrap().as_ref() { f(r); } }
    }

    /// Whether this start should use the OpenVINO build: large-v3-turbo, chosen by the speed test, files present,
    /// and it hasn't failed to load since Pip started.
    fn use_openvino(&self, model: &ModelSpec) -> bool {
        model.id == "large" && !self.openvino_failed.load(SeqCst) && load_settings().accel == "openvino" && setup::openvino_installed()
    }

    pub fn start(self: &Arc<Self>) {
        if self.child.lock().unwrap().is_some() { return; }
        self.stopping.store(false, SeqCst);
        let dir = models_dir();
        let Some(model) = active_model() else { return };
        let openvino = self.use_openvino(model);
        let bin = if openvino { Some(setup::ov_bin_dir().join("whisper-server.exe")) } else { find_tool("whisper-server") };
        let Some(bin) = bin else { return };
        let mut cmd = Command::new(bin);
        // Run inside the models folder and pass file names only: see the note at the top.
        cmd.current_dir(&dir);
        cmd.args(["-m", model.file, "--host", "127.0.0.1", "--port", &PORT.to_string(), "-l", "auto", "-t", &threads().to_string(), "-fa"]);
        if openvino { cmd.args(["-oved", "GPU"]); }
        if dir.join(VAD_FILE).is_file() { cmd.args(["--vad", "-vm", VAD_FILE]); }
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW);
        self.openvino.store(openvino, SeqCst);
        match cmd.spawn() {
            Ok(c) => {
                if let Some(j) = self.job { unsafe { let _ = AssignProcessToJobObject(j, HANDLE(c.as_raw_handle())); } }
                log(&format!("whisper-server started (pid {}, model {}, {} threads{})", c.id(), model.id, threads(),
                    if openvino { ", OpenVINO on the Intel graphics" } else { "" }));
                *self.child.lock().unwrap() = Some(c);
            }
            Err(e) => { log(&format!("whisper-server: {e}")); return; }
        }
        let (me, generation) = (self.clone(), self.generation.fetch_add(1, SeqCst) + 1);
        std::thread::spawn(move || me.watch(generation));
    }

    /// Why the server process ended, if it has.
    fn exited(&self) -> Option<String> {
        match self.child.lock().unwrap().as_mut() {
            None => Some("no process".into()),
            Some(c) => match c.try_wait() { Ok(Some(st)) => Some(exit_reason(st)), _ => None },
        }
    }

    /// Waits for the server to answer, then restarts it if it stops. A server that dies before it's ever ready is
    /// not restarted (it would only crash again): the log says why, and dictation falls back to whisper-cli.
    fn watch(self: Arc<Self>, generation: u64) {
        let gone = || self.stopping.load(SeqCst) || self.generation.load(SeqCst) != generation;
        let mut ready = false;
        for _ in 0..240 {
            if gone() { return; }
            if let Some(why) = self.exited() {
                log(&format!("whisper-server stopped while loading: {why}"));
                *self.child.lock().unwrap() = None;
                self.fall_back_from_openvino();
                return;
            }
            if answers() { ready = true; break; }
            std::thread::sleep(Duration::from_millis(500));
        }
        if ready { self.set_ready(true); log("whisper-server ready"); } else { log("whisper-server didn't answer; still waiting"); }
        loop {
            std::thread::sleep(Duration::from_secs(3));
            if gone() { return; }
            if !ready && answers() { ready = true; self.set_ready(true); log("whisper-server ready"); }
            if let Some(why) = self.exited() {
                self.set_ready(false);
                *self.child.lock().unwrap() = None;
                if !ready { log(&format!("whisper-server stopped while loading: {why}")); self.fall_back_from_openvino(); return; }
                log(&format!("whisper-server stopped ({why}); restarting"));
                self.start();
                return;
            }
        }
    }

    /// The OpenVINO build died before it was ready (a driver problem, say): use the processor until Pip restarts.
    fn fall_back_from_openvino(self: &Arc<Self>) {
        if self.openvino.load(SeqCst) && !self.openvino_failed.swap(true, SeqCst) {
            log("OpenVINO didn't start; using the processor instead");
            self.start();
        }
    }

    pub fn stop(&self) {
        self.stopping.store(true, SeqCst);
        self.set_ready(false);
        if let Some(mut c) = self.child.lock().unwrap().take() { let _ = c.kill(); let _ = c.wait(); }
    }

    /// Waits up to `limit` for a server that is starting (after a model switch, say) to be ready.
    fn wait_ready(&self, limit: Duration) -> bool {
        let until = std::time::Instant::now() + limit;
        while !self.is_ready() && std::time::Instant::now() < until {
            if self.child.lock().unwrap().is_none() { return false; }   // not starting: no point waiting
            std::thread::sleep(Duration::from_millis(200));
        }
        self.is_ready()
    }

    /// Off the UI thread. A dictation made while the server restarts (a new model) waits for it and tries again,
    /// rather than going to whisper-cli, which loads the whole model for every dictation.
    pub fn transcribe(&self, wav: &Path, lang: &str, prompt: &str) -> Option<String> {
        for attempt in 0..2 {
            if !self.wait_ready(Duration::from_secs(20)) { break; }
            if let Some(t) = via_server(wav, lang, prompt) { return Some(t); }
            if attempt == 0 { std::thread::sleep(Duration::from_millis(300)); }   // a restart may have just begun
        }
        log("whisper-server not ready; using whisper-cli");
        via_cli(wav, lang, prompt)
    }
}

/// The copy whisper-cli reads, if a crash left one behind.
pub fn remove_leftovers() { let _ = std::fs::remove_file(models_dir().join(CLI_WAV)); }

/// Whether the server is listening: any HTTP answer counts, even an error status.
fn answers() -> bool {
    matches!(ureq::get(&format!("http://127.0.0.1:{PORT}/")).timeout(Duration::from_secs(1)).call(), Ok(_) | Err(ureq::Error::Status(..)))
}

fn via_server(wav: &Path, lang: &str, prompt: &str) -> Option<String> {
    let audio = std::fs::read(wav).ok()?;
    let boundary = format!("pip-{}", chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default());
    let mut body = Vec::with_capacity(audio.len() + 1024);
    let field = |b: &mut Vec<u8>, name: &str, value: &str| {
        b.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    };
    body.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictee.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend(&audio);
    body.extend(b"\r\n");
    // verbose_json: the segments with their times, for paragraphs. split_on_word: never cut inside a word.
    field(&mut body, "response_format", "verbose_json");
    field(&mut body, "split_on_word", "true");
    field(&mut body, "temperature", "0.0");
    field(&mut body, "language", lang);
    if !prompt.is_empty() { field(&mut body, "prompt", prompt); }
    body.extend(format!("--{boundary}--\r\n").as_bytes());
    let resp = ureq::post(&format!("http://127.0.0.1:{PORT}/inference"))
        .timeout(Duration::from_secs(120))
        .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
        .send_bytes(&body)
        .map_err(|e| log(&format!("whisper-server request failed: {}", match &e {
            ureq::Error::Status(code, _) => format!("HTTP {code}"),
            ureq::Error::Transport(t) => t.kind().to_string(),
        })))
        .ok()?;
    let j: serde_json::Value = serde_json::from_str(&resp.into_string().ok()?).ok()?;
    let segments: Vec<(f32, String)> = j.get("segments").and_then(|s| s.as_array()).map(|a| {
        a.iter().filter_map(|s| Some((s.get("start").and_then(|v| v.as_f64()).unwrap_or(0.0) as f32, s.get("text")?.as_str()?.to_string()))).collect()
    }).unwrap_or_default();
    if segments.is_empty() { return j.get("text")?.as_str().map(String::from); }
    Some(join_segments(&segments, &pauses_in(wav)))
}

/// The pauses in the recording (16 kHz mono 16-bit, as audio.rs writes it), for paragraphs.
fn pauses_in(wav: &Path) -> Vec<(f32, f32)> {
    let Ok(mut r) = hound::WavReader::open(wav) else { return Vec::new() };
    let rate = r.spec().sample_rate as f32;
    let samples: Vec<f32> = r.samples::<i16>().filter_map(Result::ok).map(|s| s as f32 / 32768.0).collect();
    find_pauses(&samples, rate, 1.2)
}

fn via_cli(wav: &Path, lang: &str, prompt: &str) -> Option<String> {
    let Some(bin) = find_tool("whisper-cli") else { log("whisper-cli not found"); return None };
    let Some(model) = active_model() else { log("whisper-cli: no model"); return None };
    // Inside the models folder, with file names only (see the note at the top): the recording is copied there
    // because the temporary folder's path contains the user name, which may have accents too.
    let dir = models_dir();
    let take = dir.join(CLI_WAV);
    if let Err(e) = std::fs::copy(wav, &take) { log(&format!("whisper-cli: can't copy the recording: {e}")); return None; }
    let mut cmd = Command::new(bin);
    cmd.current_dir(&dir).args(["-m", model.file, "-f", CLI_WAV, "-l", lang, "-nt", "-np", "-sow", "-t", &threads().to_string()]);
    if !prompt.is_empty() { cmd.args(["--prompt", prompt]); }
    let out = cmd.stdin(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output();
    let _ = std::fs::remove_file(&take);
    let out = out.map_err(|e| log(&format!("whisper-cli: {e}"))).ok()?;
    if !out.status.success() { log(&format!("whisper-cli failed: {}", exit_reason(out.status))); return None; }
    // Never fail on an odd byte: lose that character, not the whole dictation.
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}
