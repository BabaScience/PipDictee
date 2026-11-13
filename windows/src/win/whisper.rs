//! whisper.cpp, kept loaded in a local server (127.0.0.1 only); whisper-cli.exe as a fallback.
//! The executables are only looked for next to PipDictee.exe or in %LOCALAPPDATA%\Pip Dictée\bin — never on
//! PATH, so a stray whisper-server.exe elsewhere can't be picked up. The server lives in a Job Object: it dies
//! with the app, even if the app is killed.
//!
//! Paths with accents: whisper.cpp reads its command line in the Windows code page but opens the model as if the
//! path were UTF-8, and aborts on anything else, so "Pip Dictée" (or a user name like "José") crashed it. The
//! tools therefore run *inside* the models folder and only ever get plain file names, never a full path.

use crate::store::{log, models_dir, MODEL_FILE, VAD_FILE};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::JobObjects::*;

pub const PORT: u16 = 18765;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
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
        Arc::new(Whisper { child: Mutex::new(None), ready: AtomicBool::new(false), stopping: AtomicBool::new(false), job, on_ready: Mutex::new(None) })
    }

    pub fn is_ready(&self) -> bool { self.ready.load(SeqCst) }

    /// Told when the server becomes ready or stops (the panel shows it).
    pub fn set_on_ready(&self, f: impl Fn(bool) + Send + 'static) { *self.on_ready.lock().unwrap() = Some(Box::new(f)); }
    fn set_ready(&self, r: bool) {
        if self.ready.swap(r, SeqCst) != r { if let Some(f) = self.on_ready.lock().unwrap().as_ref() { f(r); } }
    }

    pub fn start(self: &Arc<Self>) {
        if self.child.lock().unwrap().is_some() { return; }
        self.stopping.store(false, SeqCst);
        let dir = models_dir();
        let (Some(bin), true) = (find_tool("whisper-server"), dir.join(MODEL_FILE).is_file()) else { return };
        let mut cmd = Command::new(bin);
        // Run inside the models folder and pass file names only: see the note at the top.
        cmd.current_dir(&dir);
        cmd.args(["-m", MODEL_FILE, "--host", "127.0.0.1", "--port", &PORT.to_string(), "-l", "auto", "-t", "8", "-fa"]);
        if dir.join(VAD_FILE).is_file() { cmd.args(["--vad", "-vm", VAD_FILE]); }
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW);
        match cmd.spawn() {
            Ok(c) => {
                if let Some(j) = self.job { unsafe { let _ = AssignProcessToJobObject(j, HANDLE(c.as_raw_handle())); } }
                log(&format!("whisper-server started (pid {})", c.id()));
                *self.child.lock().unwrap() = Some(c);
            }
            Err(e) => { log(&format!("whisper-server: {e}")); return; }
        }
        let me = self.clone();
        std::thread::spawn(move || me.watch());
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
    fn watch(self: Arc<Self>) {
        let mut ready = false;
        for _ in 0..240 {
            if self.stopping.load(SeqCst) { return; }
            if let Some(why) = self.exited() {
                log(&format!("whisper-server stopped while loading: {why}"));
                *self.child.lock().unwrap() = None;
                return;
            }
            // Any HTTP answer, even an error status, means it's listening.
            match ureq::get(&format!("http://127.0.0.1:{PORT}/")).timeout(Duration::from_secs(1)).call() {
                Ok(_) | Err(ureq::Error::Status(..)) => { ready = true; break; }
                Err(_) => std::thread::sleep(Duration::from_millis(500)),
            }
        }
        if ready { self.set_ready(true); log("whisper-server ready"); } else { log("whisper-server didn't answer; still waiting"); }
        loop {
            std::thread::sleep(Duration::from_secs(3));
            if self.stopping.load(SeqCst) { return; }
            if !ready {
                if ureq::get(&format!("http://127.0.0.1:{PORT}/")).timeout(Duration::from_secs(1)).call()
                    .map_or_else(|e| matches!(e, ureq::Error::Status(..)), |_| true) {
                    ready = true; self.set_ready(true); log("whisper-server ready");
                }
            }
            if let Some(why) = self.exited() {
                self.set_ready(false);
                *self.child.lock().unwrap() = None;
                if !ready { log(&format!("whisper-server stopped while loading: {why}")); return; }
                log(&format!("whisper-server stopped ({why}); restarting"));
                self.start();
                return;
            }
        }
    }

    pub fn stop(&self) {
        self.stopping.store(true, SeqCst);
        if let Some(mut c) = self.child.lock().unwrap().take() { let _ = c.kill(); let _ = c.wait(); }
    }

    /// Off the UI thread.
    pub fn transcribe(&self, wav: &Path, lang: &str, prompt: &str) -> Option<String> {
        if self.is_ready() {
            if let Some(t) = via_server(wav, lang, prompt) { return Some(t); }
        } else {
            log("whisper-server not ready; using whisper-cli");
        }
        via_cli(wav, lang, prompt)
    }
}

/// The copy whisper-cli reads, if a crash left one behind.
pub fn remove_leftovers() { let _ = std::fs::remove_file(models_dir().join(CLI_WAV)); }

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
    field(&mut body, "response_format", "json");
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
    j.get("text")?.as_str().map(String::from)
}

fn via_cli(wav: &Path, lang: &str, prompt: &str) -> Option<String> {
    let Some(bin) = find_tool("whisper-cli") else { log("whisper-cli not found"); return None };
    // Inside the models folder, with file names only (see the note at the top): the recording is copied there
    // because the temporary folder's path contains the user name, which may have accents too.
    let dir = models_dir();
    let take = dir.join(CLI_WAV);
    if let Err(e) = std::fs::copy(wav, &take) { log(&format!("whisper-cli: can't copy the recording: {e}")); return None; }
    let mut cmd = Command::new(bin);
    cmd.current_dir(&dir).args(["-m", MODEL_FILE, "-f", CLI_WAV, "-l", lang, "-nt", "-np", "-t", "8"]);
    if !prompt.is_empty() { cmd.args(["--prompt", prompt]); }
    let out = cmd.stdin(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output();
    let _ = std::fs::remove_file(&take);
    let out = out.map_err(|e| log(&format!("whisper-cli: {e}"))).ok()?;
    if !out.status.success() { log(&format!("whisper-cli failed: {}", exit_reason(out.status))); return None; }
    // Never fail on an odd byte: lose that character, not the whole dictation.
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}
