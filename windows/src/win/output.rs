//! Putting the text where the cursor is: clipboard + Ctrl+V, the way Wispr-style apps do it.

use arboard::SetExtWindows;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::UI::WindowsAndMessaging::{MB_ICONASTERISK, MB_OK};

/// The dictation goes on the clipboard, but kept out of Windows' clipboard history (Win+V) and cloud sync.
pub fn set_clipboard(text: &str) -> bool {
    match arboard::Clipboard::new() {
        Ok(mut c) => c.set().exclude_from_history().exclude_from_cloud().exclude_from_monitoring().text(text.to_string()).is_ok(),
        Err(_) => false,
    }
}

pub fn send_keys(keys: &[(VIRTUAL_KEY, bool)]) {
    let inputs: Vec<INPUT> = keys.iter().map(|&(vk, down)| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP }, time: 0, dwExtraInfo: 0 } },
    }).collect();
    unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32); }
}

pub fn paste() { send_keys(&[(VK_CONTROL, true), (VK_V, true), (VK_V, false), (VK_CONTROL, false)]); }

pub fn beep(start: bool) { unsafe { let _ = MessageBeep(if start { MB_ICONASTERISK } else { MB_OK }); } }
