//! "Open at sign-in": a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run (per user, no admin rights).

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::*;

const KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const NAME: PCWSTR = w!("PipDictee");

pub fn enabled() -> bool {
    unsafe { RegGetValueW(HKEY_CURRENT_USER, KEY, NAME, RRF_RT_REG_SZ, None, None, None) == ERROR_SUCCESS }
}

pub fn set(on: bool) -> Result<(), String> {
    unsafe {
        if on {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            // Quoted, so a path with spaces can't be read as another program plus arguments.
            let value: Vec<u16> = format!("\"{}\"", exe.display()).encode_utf16().chain(Some(0)).collect();
            let r = RegSetKeyValueW(HKEY_CURRENT_USER, KEY, NAME, REG_SZ.0, Some(value.as_ptr().cast()), (value.len() * 2) as u32);
            if r != ERROR_SUCCESS { return Err(HSTRING::from(format!("{r:?}")).to_string()); }
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, KEY, NAME);
        }
    }
    Ok(())
}
