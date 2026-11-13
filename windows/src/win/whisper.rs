//! whisper.cpp, kept loaded in a local server (127.0.0.1 only); whisper-cli.exe as a fallback.
//! The executables are only looked for next to PipDictee.exe or in %LOCALAPPDATA%\Pip Dictée\bin — never on
//! PATH, so a stray whisper-server.exe elsewhere can't be picked up. The server lives in a Job Object: it dies
//! with the app, even if the app is killed.

use crate::store::{log, model_path, models_dir, VAD_FILE};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::JobObjects::*;

pub const PORT: u16 = 18765;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

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
        let (Some(bin), true) = (find_tool("whisper-server"), model_path().is_file()) else { return };
        let mut cmd = Command::new(bin);
        cmd.arg("-m").arg(model_path()).args(["--host", "127.0.0.1", "--port", &PORT.to_string(), "-l", "auto", "-t", "8", "-fa"]);
        let vad = models_dir().join(VAD_FILE);
        if vad.is_file() { cmd.arg("--vad").arg("-vm").arg(vad); }
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

    /// Waits for the server to answer, then restarts it if it stops.
    fn watch(self: Arc<Self>) {
        for _ in 0..240 {
            if ureq::get(&format!("http://127.0.0.1:{PORT}/")).timeout(Duration::from_secs(1)).call().is_ok() {
                self.set_ready(true); log("whisper-server ready"); break;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        loop {
            std::thread::sleep(Duration::from_secs(3));
            if self.stopping.load(SeqCst) { return; }
            let exited = self.child.lock().unwrap().as_mut().map_or(true, |c| matches!(c.try_wait(), Ok(Some(_))));
            if exited {
                self.set_ready(false);
                log("whisper-server stopped; restarting");
                *self.child.lock().unwrap() = None;
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
        if self.is_ready() { if let Some(t) = via_server(wav, lang, prompt) { return Some(t); } }
        via_cli(wav, lang, prompt)
    }
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
    field(&mut body, "response_format", "json");
    field(&mut body, "temperature", "0.0");
    field(&mut body, "language", lang);
    if !prompt.is_empty() { field(&mut body, "prompt", prompt); }
    body.extend(format!("--{boundary}--\r\n").as_bytes());
    let resp = ureq::post(&format!("http://127.0.0.1:{PORT}/inference"))
        .timeout(Duration::from_secs(120))
        .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
        .send_bytes(&body).ok()?;
    let j: serde_json::Value = serde_json::from_str(&resp.into_string().ok()?).ok()?;
    j.get("text")?.as_str().map(String::from)
}

fn via_cli(wav: &Path, lang: &str, prompt: &str) -> Option<String> {
    let bin = find_tool("whisper-cli")?;
    let mut cmd = Command::new(bin);
    cmd.arg("-m").arg(model_path()).arg("-f").arg(wav).args(["-l", lang, "-nt", "-np", "-t", "8"]);
    if !prompt.is_empty() { cmd.args(["--prompt", prompt]); }
    let out = cmd.stdin(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output().ok()?;
    String::from_utf8(out.stdout).ok()
}
