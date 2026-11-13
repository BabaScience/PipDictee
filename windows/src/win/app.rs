//! The tray app, with the same interface as the macOS app (design/ui): the floating pill, a panel that opens from
//! the tray icon, the settings window and the first-launch setup. Each window shows windows/ui/ui.html in WebView2
//! and talks to this file through a small JSON message bridge.
//!
//! Threads:
//!   main        — event loop (tao), tray icon, WebView2 windows, keyboard hook (it needs this thread's messages)
//!   controller  — the dictation state machine: owns the recorder, receives `Event`s, sends `UiEvent`s
//!   short-lived — one per transcription, and one for the setup downloads

use super::audio::{self, Recorder};
use super::hook::{self, Mode};
use super::whisper::{find_tool, Whisper};
use super::{autostart, output, setup};
use crate::cleanup::clean;
use crate::i18n::{self, t, tf};
use crate::store::{self, log, Dictionary, Entry, Settings, Trigger, LANGUAGES};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tao::dpi::{LogicalSize, PhysicalPosition};
use tao::event::{Event as TaoEvent, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy, EventLoopWindowTarget};
use tao::platform::windows::WindowBuilderExtWindows;
use tao::window::{Window, WindowBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};
use tray_icon::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use windows::core::w;
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, POINT};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
use wry::{NewWindowResponse, WebView, WebViewBuilder};

const UI_HTML: &str = include_str!("../../ui/ui.html");
const SOURCE_URL: &str = "https://github.com/BabaScience/PipDictee";

/// What the controller thread is told (from the keyboard hook, the windows, and its own transcriptions).
pub enum Event { Combo(bool), Space, Escape, OtherKey, Toggle, Transcribed(String), Quit }

/// What the main thread is told (from the controller, the windows, the tray, the downloads).
pub enum UiEvent {
    Pill(Option<Value>, Option<u64>),
    Mode(Mode),
    HistoryChanged,
    WhisperReady(bool),
    Ipc(View, String),
    Tray(TrayIconEvent),
    Menu(MenuId),
    Download(Value),
    DownloadDone(Result<(), String>),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum View { Pill, Panel, Settings, Setup }
impl View {
    fn name(self) -> &'static str {
        match self { View::Pill => "pill", View::Panel => "panel", View::Settings => "settings", View::Setup => "setup" }
    }
}

/// Settings and history, read by the windows and written by the controller.
struct Shared { settings: Mutex<Settings>, history: Mutex<Vec<Entry>> }

fn mode_name(m: Mode) -> &'static str {
    match m { Mode::Idle => "idle", Mode::Holding => "holding", Mode::HandsFree => "handsFree", Mode::Working => "working" }
}
fn has_whisper() -> bool { find_tool("whisper-server").is_some() || find_tool("whisper-cli").is_some() }
fn has_model() -> bool { store::model_path().is_file() }
fn is_live(pill: &Option<Value>) -> bool {
    pill.as_ref().and_then(|s| s["kind"].as_str()).map_or(false, |k| k == "listening" || k == "handsFree")
}

// MARK: - Icons (rendered from the macOS app's Pip by scripts/make-windows-assets.sh)

fn decode_png(bytes: &[u8]) -> (Vec<u8>, u32, u32) {
    let mut d = png::Decoder::new(std::io::Cursor::new(bytes));
    d.set_transformations(png::Transformations::EXPAND);
    let mut r = d.read_info().expect("png");
    let mut buf = vec![0; r.output_buffer_size().expect("png size")];
    let info = r.next_frame(&mut buf).expect("png frame");
    buf.truncate(info.buffer_size());
    (buf, info.width, info.height)
}
fn tray_icon_for(m: Mode, needs_setup: bool) -> tray_icon::Icon {
    let bytes: &[u8] = match (m, needs_setup) {
        (Mode::Holding | Mode::HandsFree, _) => include_bytes!("../../assets/tray-listening.png"),
        (Mode::Working, _) => include_bytes!("../../assets/tray-thinking.png"),
        (_, true) => include_bytes!("../../assets/tray-needs-you.png"),
        _ => include_bytes!("../../assets/tray-ready.png"),
    };
    let (rgba, w, h) = decode_png(bytes);
    tray_icon::Icon::from_rgba(rgba, w, h).expect("tray icon")
}
fn window_icon() -> tao::window::Icon {
    let (rgba, w, h) = decode_png(include_bytes!("../../assets/icon-64.png"));
    tao::window::Icon::from_rgba(rgba, w, h).expect("window icon")
}

/// The work area (screen minus taskbar) of the monitor under the mouse, in physical pixels.
fn work_area_at_cursor() -> (i32, i32, i32, i32) {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(mon, &mut mi);
        let r = mi.rcWork;
        (r.left, r.top, r.right, r.bottom)
    }
}

// MARK: - Startup

pub fn run() {
    // One instance only (a second would fight over the shortcut and the port).
    unsafe {
        let _ = CreateMutexW(None, true, w!("Local\\PipDictee.SingleInstance"));
        if GetLastError() == ERROR_ALREADY_EXISTS { return; }
    }
    store::ensure_dictionary();
    audio::remove_leftovers();
    let settings = store::load_settings();
    i18n::set_language(&settings.ui_language);
    hook::set_trigger(settings.trigger);
    let shared = Arc::new(Shared { history: Mutex::new(store::load_history()), settings: Mutex::new(settings) });

    let event_loop = EventLoopBuilder::<UiEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let whisper = Whisper::new();
    {
        let p = Mutex::new(proxy.clone());
        whisper.set_on_ready(move |ready| { let _ = p.lock().unwrap().send_event(UiEvent::WhisperReady(ready)); });
    }
    whisper.start();

    let (tx, rx) = channel();
    let _hook = match hook::install(tx.clone()) {
        Ok(h) => { log("keyboard hook installed"); h }
        Err(e) => { log(&format!("keyboard hook: {e}")); return; }
    };
    {
        let (s, w, p, me) = (shared.clone(), whisper.clone(), proxy.clone(), tx.clone());
        std::thread::spawn(move || Controller { shared: s, whisper: w, ui: p, me, recorder: None, started: Instant::now() }.run(rx));
    }
    // Tray and menu events arrive on tray-icon's own channels: forward them into the event loop.
    {
        let p = Mutex::new(proxy.clone());
        TrayIconEvent::set_event_handler(Some(move |e| { let _ = p.lock().unwrap().send_event(UiEvent::Tray(e)); }));
        let p = Mutex::new(proxy.clone());
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| { let _ = p.lock().unwrap().send_event(UiEvent::Menu(e.id)); }));
    }

    let menu = Menu::new();
    let menu_settings = MenuItem::new(t("Settings…"), true, None);
    let menu_quit = MenuItem::new(t("Quit Pip Dictée"), true, None);
    let _ = menu.append_items(&[&menu_settings, &PredefinedMenuItem::separator(), &menu_quit]);
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)   // left click opens the panel, right click this small menu
        .with_icon(tray_icon_for(Mode::Idle, !has_whisper() || !has_model()))
        .with_tooltip(tooltip(&shared.settings.lock().unwrap(), Mode::Idle))
        .build()
        .expect("tray icon");

    let mut ui = Ui {
        proxy, shared, whisper, tx, views: HashMap::new(), tray, menu_settings, menu_quit,
        mode: Mode::Idle, whisper_ready: false, pill: None, pill_hide_at: None, levels: VecDeque::from(vec![0.0; 12]),
        tab: "general".into(), panel_hidden_at: Instant::now() - Duration::from_secs(5),
        step: 0, mic: None, mic_started: Instant::now(), loud_ticks: 0, heard: false, quiet: false, mic_name: None, advance_at: None,
        download: json!({ "state": "idle" }), cancel: Arc::new(AtomicBool::new(false)),
    };
    log("started");

    event_loop.run(move |event, target, control_flow| {
        match event {
            TaoEvent::NewEvents(StartCause::Init) => {
                ui.create(target, View::Pill);
                ui.create(target, View::Panel);
                let done = ui.shared.settings.lock().unwrap().onboarding_done;
                if !done || !has_whisper() || !has_model() { ui.open(target, View::Setup); }
            }
            TaoEvent::UserEvent(e) => ui.handle(target, e, control_flow),
            TaoEvent::WindowEvent { window_id, event, .. } => {
                let Some(view) = ui.views.iter().find(|(_, w)| w.window.id() == window_id).map(|(v, _)| *v) else { return };
                match event {
                    WindowEvent::CloseRequested if matches!(view, View::Settings | View::Setup) => {
                        if view == View::Setup { ui.stop_mic(); }
                        ui.views.remove(&view);
                    }
                    WindowEvent::Focused(false) if view == View::Panel => ui.hide_panel(),
                    _ => {}
                }
            }
            TaoEvent::MainEventsCleared => ui.tick(),
            _ => {}
        }
        if *control_flow != ControlFlow::Exit { *control_flow = ui.next_wake(); }
    });
}

fn tooltip(s: &Settings, m: Mode) -> String {
    let k = if s.trigger == Trigger::CtrlWin { "Ctrl + Win".to_string() } else { t("Right Ctrl") };
    match m {
        Mode::Idle => tf("Pip Dictée — hold %@ and talk", &[&k]),
        Mode::Holding | Mode::HandsFree => t("Pip Dictée — listening… (Esc cancels)"),
        Mode::Working => t("Pip Dictée — transcribing…"),
    }
}

// MARK: - Windows and their state

struct Win { window: Window, webview: WebView, ready: bool }

struct Ui {
    proxy: EventLoopProxy<UiEvent>,
    shared: Arc<Shared>,
    whisper: Arc<Whisper>,
    tx: Sender<Event>,
    views: HashMap<View, Win>,
    tray: TrayIcon,
    menu_settings: MenuItem,
    menu_quit: MenuItem,
    mode: Mode,
    whisper_ready: bool,
    pill: Option<Value>,
    pill_hide_at: Option<Instant>,
    levels: VecDeque<f32>,
    tab: String,
    panel_hidden_at: Instant,
    // first-launch setup
    step: u32,
    mic: Option<Recorder>,
    mic_started: Instant,
    loud_ticks: u32,
    heard: bool,
    quiet: bool,
    mic_name: Option<String>,
    advance_at: Option<Instant>,
    download: Value,
    cancel: Arc<AtomicBool>,
}

impl Ui {
    fn create(&mut self, target: &EventLoopWindowTarget<UiEvent>, view: View) {
        if self.views.contains_key(&view) { return; }
        let floating = matches!(view, View::Pill | View::Panel);
        let mut b = WindowBuilder::new().with_visible(false).with_window_icon(Some(window_icon()));
        b = match view {
            View::Pill => b.with_inner_size(LogicalSize::new(460.0, 90.0)).with_focusable(false).with_focused(false),
            View::Panel => b.with_inner_size(LogicalSize::new(376.0, 716.0)),
            View::Settings => b.with_title(t("Pip Dictée Settings")).with_inner_size(LogicalSize::new(880.0, 640.0))
                .with_min_inner_size(LogicalSize::new(720.0, 520.0)),
            View::Setup => b.with_title(t("Welcome to Pip Dictée")).with_inner_size(LogicalSize::new(440.0, 680.0))
                .with_resizable(false).with_maximizable(false),
        };
        if floating {
            b = b.with_decorations(false).with_transparent(true).with_always_on_top(true).with_skip_taskbar(true)
                .with_resizable(false).with_undecorated_shadow(false);
        }
        let window = b.build(target).expect("window");
        let proxy = Mutex::new(self.proxy.clone());
        let webview = WebViewBuilder::new()
            .with_html(UI_HTML)
            .with_initialization_script(format!("window.PIP_VIEW = {:?};", view.name()))
            .with_transparent(floating)
            .with_ipc_handler(move |req: wry::http::Request<String>| {
                let _ = proxy.lock().unwrap().send_event(UiEvent::Ipc(view, req.into_body()));
            })
            // The page never navigates anywhere: links open in the browser through the bridge, after checks.
            .with_navigation_handler(|url| !(url.starts_with("http") || url.starts_with("file:")))
            .with_new_window_req_handler(|_, _| NewWindowResponse::Deny)
            .with_devtools(cfg!(debug_assertions))
            .with_hotkeys_zoom(false)
            .build(&window)
            .expect("webview");
        if view == View::Pill { let _ = window.set_ignore_cursor_events(true); }
        self.views.insert(view, Win { window, webview, ready: false });
    }

    fn open(&mut self, target: &EventLoopWindowTarget<UiEvent>, view: View) {
        self.create(target, view);
        if let Some(w) = self.views.get(&view) {
            w.window.set_visible(true);
            w.window.set_focus();
        }
        if view == View::Setup { self.set_step(0); }
        self.push(view);
    }

    /// The state a window needs, as JSON. Strings are sent too, so a language change applies at once.
    fn state(&self, view: View) -> Value {
        let s = self.shared.settings.lock().unwrap().clone();
        let history = self.shared.history.lock().unwrap();
        let mut v = json!({
            "strings": i18n::table(), "locale": i18n::current(), "settings": s, "trigger": s.trigger,
            "mode": mode_name(self.mode), "whisperReady": self.whisper_ready, "hasWhisper": has_whisper(), "hasModel": has_model(),
            "version": env!("CARGO_PKG_VERSION"),
        });
        match view {
            View::Pill => { v["pill"] = self.pill.clone().unwrap_or(Value::Null); v["levels"] = json!(self.levels); }
            View::Panel => v["history"] = json!(history.iter().take(3).collect::<Vec<_>>()),
            View::Settings => {
                v["history"] = json!(*history);
                v["dictionary"] = json!(store::load_dictionary());
                v["tab"] = json!(self.tab);
                v["openAtLogin"] = json!(autostart::enabled());
            }
            View::Setup => {
                v["step"] = json!(self.step);
                v["history"] = json!(history.iter().take(1).collect::<Vec<_>>());
                v["mic"] = json!({ "heard": self.heard, "quiet": self.quiet, "name": self.mic_name, "levels": self.levels });
                v["download"] = self.download.clone();
            }
        }
        v
    }

    fn push(&self, view: View) {
        if let Some(w) = self.views.get(&view) {
            if w.ready { let _ = w.webview.evaluate_script(&format!("pip.update({})", self.state(view))); }
        }
    }
    fn push_all(&self) { for v in [View::Pill, View::Panel, View::Settings, View::Setup] { self.push(v); } }

    fn refresh_tray(&self) {
        let _ = self.tray.set_icon(Some(tray_icon_for(self.mode, !has_whisper() || !has_model())));
        let _ = self.tray.set_tooltip(Some(tooltip(&self.shared.settings.lock().unwrap(), self.mode)));
    }

    // MARK: pill

    fn show_pill(&mut self, state: Option<Value>, hide_after: Option<u64>) {
        let needs_click = state.as_ref().and_then(|s| s["kind"].as_str()) == Some("needsYou");
        self.pill = state;
        self.pill_hide_at = hide_after.map(|ms| Instant::now() + Duration::from_millis(ms));
        if !is_live(&self.pill) { self.levels.iter_mut().for_each(|l| *l = 0.0); }
        if let Some(w) = self.views.get(&View::Pill) {
            if self.pill.is_some() {
                let (l, _, r, b) = work_area_at_cursor();
                let scale = w.window.scale_factor();
                let (pw, ph) = ((460.0 * scale) as i32, (90.0 * scale) as i32);
                w.window.set_outer_position(PhysicalPosition::new((l + r) / 2 - pw / 2, b - ph - (10.0 * scale) as i32));
                let _ = w.window.set_ignore_cursor_events(!needs_click);
                w.window.set_visible(true);
            } else {
                w.window.set_visible(false);
            }
        }
        self.push(View::Pill);
    }

    // MARK: panel

    fn toggle_panel(&mut self, rect: tray_icon::Rect) {
        let Some(w) = self.views.get(&View::Panel) else { return };
        // A click on the tray icon while the panel is open first takes its focus away (which hides it): don't reopen.
        if w.window.is_visible() || self.panel_hidden_at.elapsed() < Duration::from_millis(300) { self.hide_panel(); return; }
        let scale = w.window.scale_factor();
        let (pw, ph) = ((376.0 * scale) as i32, (716.0 * scale) as i32);
        let (l, top, r, b) = work_area_at_cursor();
        let cx = rect.position.x as i32 + rect.size.width as i32 / 2;
        let x = (cx - pw / 2).clamp(l, (r - pw).max(l));
        let y = if (rect.position.y as i32) > (top + b) / 2 { b - ph } else { top };
        w.window.set_outer_position(PhysicalPosition::new(x, y));
        w.window.set_visible(true);
        w.window.set_focus();
        self.push(View::Panel);
    }
    fn hide_panel(&mut self) {
        if let Some(w) = self.views.get(&View::Panel) {
            if w.window.is_visible() { w.window.set_visible(false); self.panel_hidden_at = Instant::now(); }
        }
    }

    // MARK: setup

    fn set_step(&mut self, step: u32) {
        self.step = step.min(3);
        self.advance_at = None;
        if self.step == 1 { self.start_mic(); } else { self.stop_mic(); }
        if self.step == 2 && has_whisper() && has_model() { self.download = json!({ "state": "done" }); }
        self.push(View::Setup);
    }
    fn start_mic(&mut self) {
        self.stop_mic();
        audio::reset_level();
        self.heard = false; self.quiet = false; self.loud_ticks = 0;
        self.mic_name = audio::input_name();
        self.mic_started = Instant::now();
        match Recorder::start() {
            Ok(r) => self.mic = Some(r),
            Err(e) => { log(&format!("mic check: {e}")); self.quiet = true; }
        }
    }
    fn stop_mic(&mut self) { self.mic = None; }   // dropping the stream releases the microphone

    // MARK: timers (pill waveform, pill auto-hide, mic check)

    fn next_wake(&self) -> ControlFlow {
        if is_live(&self.pill) || self.mic.is_some() { return ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(60)); }
        match (self.pill_hide_at, self.advance_at) {
            (Some(a), Some(b)) => ControlFlow::WaitUntil(a.min(b)),
            (Some(a), None) | (None, Some(a)) => ControlFlow::WaitUntil(a),
            (None, None) => ControlFlow::Wait,
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();
        if self.pill_hide_at.map_or(false, |t| now >= t) { self.show_pill(None, None); }
        if self.advance_at.map_or(false, |t| now >= t) { self.set_step(2); return; }
        let live = is_live(&self.pill);
        if !(live || self.mic.is_some()) { return; }
        let (level, peak_db) = audio::level();
        self.levels.pop_front();
        self.levels.push_back(level);
        if live {
            if let Some(w) = self.views.get(&View::Pill) {
                let _ = w.webview.evaluate_script(&format!("pip.update({{levels: {}}})", json!(self.levels)));
            }
        }
        if self.mic.is_some() {
            // Voice, not noise: the peak stays above -32 dBFS for about 0.2 s (same rule as the macOS app).
            if !self.heard {
                self.loud_ticks = if peak_db > -32.0 { self.loud_ticks + 1 } else { 0 };
                if self.loud_ticks >= 3 {
                    self.heard = true;
                    self.advance_at = Some(now + Duration::from_millis(1200));
                    log("mic check: voice heard");
                } else if self.mic_started.elapsed() > Duration::from_secs(6) {
                    self.quiet = true;
                }
            }
            self.push(View::Setup);
        }
    }

    // MARK: events

    fn handle(&mut self, target: &EventLoopWindowTarget<UiEvent>, e: UiEvent, control_flow: &mut ControlFlow) {
        match e {
            UiEvent::Pill(state, hide) => self.show_pill(state, hide),
            UiEvent::Mode(m) => { self.mode = m; self.refresh_tray(); self.push(View::Panel); }
            UiEvent::HistoryChanged => { self.push(View::Panel); self.push(View::Settings); self.push(View::Setup); }
            UiEvent::WhisperReady(r) => { self.whisper_ready = r; self.push(View::Panel); }
            UiEvent::Tray(TrayIconEvent::Click { rect, button: MouseButton::Left, button_state: MouseButtonState::Up, .. }) => self.toggle_panel(rect),
            UiEvent::Tray(_) => {}
            UiEvent::Menu(id) => {
                if id == *self.menu_quit.id() { self.quit(control_flow); }
                else if id == *self.menu_settings.id() { self.tab = "general".into(); self.open(target, View::Settings); }
            }
            UiEvent::Download(v) => { self.download = v; self.push(View::Setup); }
            UiEvent::DownloadDone(r) => {
                self.download = match r {
                    Ok(()) => { self.whisper.start(); json!({ "state": "done" }) }
                    Err(e) if e == "cancelled" => json!({ "state": "idle" }),
                    Err(e) => json!({ "state": "failed", "error": e }),
                };
                self.refresh_tray();
                self.push_all();
            }
            UiEvent::Ipc(view, msg) => self.ipc(target, view, &msg, control_flow),
        }
    }

    /// Messages from the windows. Everything is checked: the page is ours, but its input comes from the user.
    fn ipc(&mut self, target: &EventLoopWindowTarget<UiEvent>, view: View, msg: &str, control_flow: &mut ControlFlow) {
        let Ok(m) = serde_json::from_str::<Value>(msg) else { return };
        match m["cmd"].as_str().unwrap_or("") {
            "ready" => {
                if let Some(w) = self.views.get_mut(&view) { w.ready = true; }
                self.push(view);
            }
            "set" => self.set(m["key"].as_str().unwrap_or(""), &m["value"]),
            "toggle" => { self.hide_panel(); let _ = self.tx.send(Event::Toggle); }
            "copy" => if let Some(text) = m["text"].as_str() { output::set_clipboard(text); },
            "settings" => {
                self.hide_panel();
                if let Some(tab) = m["tab"].as_str().filter(|t| ["general", "dictionary", "history", "privacy", "about"].contains(t)) {
                    self.tab = tab.into();
                }
                self.open(target, View::Settings);
            }
            "setup" => { self.hide_panel(); self.show_pill(None, None); self.open(target, View::Setup); }
            "quit" => self.quit(control_flow),
            "clearHistory" => {
                self.shared.history.lock().unwrap().clear();
                store::save_history(&[], false);
                self.push_all();
            }
            "dictionary" => {
                if let Ok(d) = serde_json::from_value::<Dictionary>(m["dictionary"].clone()) {
                    store::save_dictionary(&d);
                    self.push(View::Settings);
                }
            }
            "open" => {
                let what = match m["what"].as_str().unwrap_or("") {
                    "micPrivacy" => "ms-settings:privacy-microphone".to_string(),
                    "dataFolder" => store::data_dir().display().to_string(),
                    "source" => SOURCE_URL.to_string(),
                    "issues" => format!("{SOURCE_URL}/issues"),
                    _ => return,   // only these four: the page can't make the app open anything else
                };
                let _ = std::process::Command::new("explorer.exe").arg(what).spawn();
            }
            "step" => if view == View::Setup { self.set_step(m["step"].as_u64().unwrap_or(0) as u32) },
            "download" => self.start_download(),
            "cancelDownload" => self.cancel.store(true, Relaxed),
            "setupDone" => {
                {
                    let mut s = self.shared.settings.lock().unwrap();
                    s.onboarding_done = true;
                    store::save_settings(&s);
                }
                self.stop_mic();
                self.views.remove(&View::Setup);
            }
            _ => {}
        }
    }

    fn start_download(&mut self) {
        if matches!(self.download["state"].as_str(), Some("downloading" | "verifying")) { return; }
        self.cancel.store(false, Relaxed);
        self.download = json!({ "state": "downloading", "stage": "engine", "progress": 0.0 });
        self.push(View::Setup);
        let (cancel, p) = (self.cancel.clone(), Mutex::new(self.proxy.clone()));
        std::thread::spawn(move || {
            let r = setup::run(cancel, |stage, done, total| {
                let state = if total > 0 && done >= total { "verifying" } else { "downloading" };
                let _ = p.lock().unwrap().send_event(UiEvent::Download(json!({
                    "state": state, "stage": stage.key(), "progress": done as f64 / total.max(1) as f64,
                    "done": setup::size(done), "total": setup::size(total),
                })));
            });
            let _ = p.lock().unwrap().send_event(UiEvent::DownloadDone(r));
        });
    }

    /// A setting changed in a window. Each value is checked before it's stored.
    fn set(&mut self, key: &str, value: &Value) {
        let mut language_changed = false;
        {
            let mut s = self.shared.settings.lock().unwrap();
            match (key, value) {
                ("lang", Value::String(v)) if LANGUAGES.iter().any(|(c, _)| c == v) => s.lang = v.clone(),
                ("trigger", Value::String(v)) => {
                    s.trigger = if v == "RightCtrl" { Trigger::RightCtrl } else { Trigger::CtrlWin };
                    hook::set_trigger(s.trigger);
                }
                ("auto_paste", Value::Bool(b)) => s.auto_paste = *b,
                ("remove_fillers", Value::Bool(b)) => s.remove_fillers = *b,
                ("sounds", Value::Bool(b)) => s.sounds = *b,
                ("keep_history", Value::Bool(b)) => {
                    s.keep_history = *b;
                    if !b { self.shared.history.lock().unwrap().clear(); store::save_history(&[], false); }
                }
                ("ui_language", Value::String(v)) if v == "system" || v == "en" || i18n::FILES.iter().any(|(c, _)| c == v) => {
                    s.ui_language = v.clone();
                    i18n::set_language(v);
                    language_changed = true;
                }
                ("open_at_login", Value::Bool(b)) => { if let Err(e) = autostart::set(*b) { log(&format!("open at sign-in: {e}")); } }
                _ => return,
            }
            store::save_settings(&s);
        }
        if language_changed {
            self.menu_settings.set_text(t("Settings…"));
            self.menu_quit.set_text(t("Quit Pip Dictée"));
            if let Some(w) = self.views.get(&View::Settings) { w.window.set_title(&t("Pip Dictée Settings")); }
            if let Some(w) = self.views.get(&View::Setup) { w.window.set_title(&t("Welcome to Pip Dictée")); }
        }
        self.refresh_tray();
        self.push_all();
    }

    fn quit(&mut self, control_flow: &mut ControlFlow) {
        let _ = self.tx.send(Event::Quit);
        self.stop_mic();
        self.whisper.stop();
        log("quit");
        *control_flow = ControlFlow::Exit;
    }
}

// MARK: - Controller (the dictation state machine)

struct Controller {
    shared: Arc<Shared>,
    whisper: Arc<Whisper>,
    ui: EventLoopProxy<UiEvent>,
    /// Its own channel, for the transcription thread to hand the text back.
    me: Sender<Event>,
    recorder: Option<Recorder>,
    started: Instant,
}

impl Controller {
    fn run(mut self, rx: Receiver<Event>) {
        for e in rx {
            let m = hook::mode();
            match e {
                Event::Combo(true) => match m { Mode::Idle => self.start(false), Mode::HandsFree => self.finish(), _ => {} },
                Event::Combo(false) if m == Mode::Holding => {
                    if self.started.elapsed() < Duration::from_millis(350) { self.cancel(false) } else { self.finish() }
                }
                Event::Combo(false) => {}
                Event::Space => match m {
                    Mode::Holding => { self.set_mode(Mode::HandsFree); self.pill("handsFree", None, None); }
                    Mode::Idle => self.start(true),
                    _ => {}
                },
                Event::Escape => self.cancel(true),
                Event::OtherKey => if m == Mode::Holding { self.cancel(false) },
                Event::Toggle => match m { Mode::Idle => self.start(true), Mode::Holding | Mode::HandsFree => self.finish(), _ => {} },
                Event::Transcribed(text) => self.deliver(text),
                Event::Quit => { self.recorder = None; return; }
            }
        }
    }

    fn set_mode(&self, m: Mode) { hook::set_mode(m); let _ = self.ui.send_event(UiEvent::Mode(m)); }
    fn pill(&self, kind: &str, extra: Option<Value>, hide_after: Option<u64>) {
        let mut v = json!({ "kind": kind });
        if let (Some(Value::Object(e)), Some(o)) = (extra, v.as_object_mut()) { o.extend(e); }
        let _ = self.ui.send_event(UiEvent::Pill(Some(v), hide_after));
    }
    fn hide_pill(&self) { let _ = self.ui.send_event(UiEvent::Pill(None, None)); }
    fn sounds(&self) -> bool { self.shared.settings.lock().unwrap().sounds }

    fn start(&mut self, hands_free: bool) {
        if !has_whisper() || !has_model() {
            let msg = if has_whisper() { t("The voice model is missing") } else { t("Install whisper.cpp") };
            self.pill("needsYou", Some(json!({ "message": msg })), Some(5000));
            return;
        }
        match Recorder::start() {
            Ok(r) => {
                self.recorder = Some(r);
                self.started = Instant::now();
                if self.sounds() { output::beep(true); }
                self.set_mode(if hands_free { Mode::HandsFree } else { Mode::Holding });
                self.pill(if hands_free { "handsFree" } else { "listening" }, None, None);
            }
            Err(e) => {
                log(&format!("microphone unavailable: {e}"));
                self.pill("oops", Some(json!({ "message": t("The microphone isn't available") })), Some(2000));
            }
        }
    }

    fn cancel(&mut self, show: bool) {
        self.recorder = None; // dropping the stream releases the microphone
        self.set_mode(Mode::Idle);
        if show { self.pill("cancelled", None, Some(1000)); } else { self.hide_pill(); }
    }

    fn finish(&mut self) {
        let Some(r) = self.recorder.take() else { return };
        let take = r.finish();
        if self.sounds() { output::beep(false); }
        if take.peak_db < -42.0 || take.seconds < 0.3 {
            self.set_mode(Mode::Idle);
            self.pill("oops", Some(json!({ "message": t("I didn't hear anything") })), Some(1600));
            return;
        }
        let wav = audio::temp_wav();
        if let Err(e) = audio::write_wav(&wav, &take.samples) { log(&format!("wav: {e}")); self.set_mode(Mode::Idle); self.hide_pill(); return; }
        self.set_mode(Mode::Working);
        self.pill("thinking", None, None);
        let s = self.shared.settings.lock().unwrap().clone();
        let (whisper, me) = (self.whisper.clone(), self.me.clone());
        std::thread::spawn(move || {
            let t0 = Instant::now();
            let dict = store::load_dictionary();
            let prompt = dict.words.iter().take(60).cloned().collect::<Vec<_>>().join(", ");
            let raw = whisper.transcribe(&wav, &s.lang, &prompt).unwrap_or_default();
            let _ = std::fs::remove_file(&wav);
            let text = clean(&raw, &dict, s.remove_fillers);
            log(&format!("transcribed in {:.2} s: {} chars", t0.elapsed().as_secs_f64(), text.chars().count()));
            let _ = me.send(Event::Transcribed(text));
        });
    }

    fn deliver(&mut self, text: String) {
        self.set_mode(Mode::Idle);
        if text.is_empty() {
            self.pill("oops", Some(json!({ "message": t("I didn't catch that") })), Some(1600));
            return;
        }
        {
            let keep = self.shared.settings.lock().unwrap().keep_history;
            let mut h = self.shared.history.lock().unwrap();
            h.insert(0, Entry { text: text.clone(), at: chrono::Utc::now(), app: None });
            h.truncate(200);
            store::save_history(&h, keep);
        }
        let _ = self.ui.send_event(UiEvent::HistoryChanged);
        if !output::set_clipboard(&text) { log("clipboard unavailable"); self.hide_pill(); return; }
        if self.shared.settings.lock().unwrap().auto_paste {
            hook::wait_modifiers_released(Duration::from_secs(2));
            std::thread::sleep(Duration::from_millis(40));
            output::paste();
            self.pill("typed", Some(json!({ "words": text.split_whitespace().count() })), Some(1100));
        } else {
            self.pill("copied", None, Some(1800));
        }
    }
}
