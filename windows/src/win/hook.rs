//! The global shortcut: a low-level keyboard hook (needs no admin rights). The callback only updates a few
//! atomics and sends events to the controller thread — Windows drops hooks that take too long.

use super::app::Event;
use crate::store::Trigger;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering::SeqCst};
use std::sync::mpsc::Sender;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Mode { Idle = 0, Holding = 1, HandsFree = 2, Working = 3 }

static MODE: AtomicU8 = AtomicU8::new(0);
static RIGHT_CTRL_TRIGGER: AtomicBool = AtomicBool::new(false);
static LCTRL: AtomicBool = AtomicBool::new(false);
static RCTRL: AtomicBool = AtomicBool::new(false);
static WIN: AtomicBool = AtomicBool::new(false);
static SHIFT: AtomicBool = AtomicBool::new(false);
static ALT: AtomicBool = AtomicBool::new(false);
static COMBO: AtomicBool = AtomicBool::new(false);
static WIN_USED: AtomicBool = AtomicBool::new(false);
static TX: OnceLock<Sender<Event>> = OnceLock::new();

pub fn mode() -> Mode {
    match MODE.load(SeqCst) { 1 => Mode::Holding, 2 => Mode::HandsFree, 3 => Mode::Working, _ => Mode::Idle }
}
pub fn set_mode(m: Mode) { MODE.store(m as u8, SeqCst); }
pub fn set_trigger(t: Trigger) { RIGHT_CTRL_TRIGGER.store(t == Trigger::RightCtrl, SeqCst); COMBO.store(false, SeqCst); }

/// Before pasting: the shortcut keys must be up, or Ctrl+V would become Ctrl+Win+V.
pub fn wait_modifiers_released(max: Duration) {
    let t0 = Instant::now();
    while (LCTRL.load(SeqCst) || RCTRL.load(SeqCst) || WIN.load(SeqCst) || ALT.load(SeqCst)) && t0.elapsed() < max {
        std::thread::sleep(Duration::from_millis(15));
    }
}

pub fn install(tx: Sender<Event>) -> windows::core::Result<HHOOK> {
    let _ = TX.set(tx);
    unsafe {
        let module = GetModuleHandleW(None)?;
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(proc), HINSTANCE(module.0), 0)
    }
}

fn send(e: Event) { if let Some(tx) = TX.get() { let _ = tx.send(e); } }

unsafe extern "system" fn proc(code: i32, w: WPARAM, l: LPARAM) -> LRESULT {
    if code >= 0 {
        let k = &*(l.0 as *const KBDLLHOOKSTRUCT);
        // Our own Ctrl+V and masking key are injected: they never count as the user's keys.
        if k.flags.0 & LLKHF_INJECTED.0 == 0 {
            let down = matches!(w.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
            if handle(VIRTUAL_KEY(k.vkCode as u16), down) { return LRESULT(1); }
        }
    }
    CallNextHookEx(None, code, w, l)
}

/// Returns true when the key is swallowed.
fn handle(vk: VIRTUAL_KEY, down: bool) -> bool {
    let is_mod = match vk {
        VK_LCONTROL => { LCTRL.store(down, SeqCst); true }
        VK_RCONTROL => { RCTRL.store(down, SeqCst); true }
        VK_LWIN | VK_RWIN => { WIN.store(down, SeqCst); true }
        VK_LSHIFT | VK_RSHIFT | VK_SHIFT => { SHIFT.store(down, SeqCst); true }
        VK_LMENU | VK_RMENU | VK_MENU => { ALT.store(down, SeqCst); true }
        _ => false,
    };
    let (lc, rc, win, shift, alt) = (LCTRL.load(SeqCst), RCTRL.load(SeqCst), WIN.load(SeqCst), SHIFT.load(SeqCst), ALT.load(SeqCst));
    let combo = if RIGHT_CTRL_TRIGGER.load(SeqCst) { rc && !lc && !win && !shift && !alt } else { (lc || rc) && win && !shift && !alt };
    if combo != COMBO.swap(combo, SeqCst) {
        if combo && win { WIN_USED.store(true, SeqCst); }
        send(Event::Combo(combo));
    }
    if is_mod {
        // Win released after it was part of the shortcut: a "masking" key stops the Start menu from opening.
        if !down && matches!(vk, VK_LWIN | VK_RWIN) && WIN_USED.swap(false, SeqCst) { mask_start_menu(); }
        return false;
    }
    if !down { return combo && vk == VK_SPACE; }
    let m = mode();
    if vk == VK_ESCAPE && matches!(m, Mode::Holding | Mode::HandsFree) { send(Event::Escape); return true; }
    if vk == VK_SPACE && combo { send(Event::Space); return true; }
    // Any other key while the shortcut is held: it was another shortcut, not a dictation.
    if combo && m == Mode::Holding { send(Event::OtherKey); }
    false
}

fn mask_start_menu() {
    const VK_NONE: VIRTUAL_KEY = VIRTUAL_KEY(0xE8); // unassigned
    super::output::send_keys(&[(VK_NONE, true), (VK_NONE, false)]);
}
