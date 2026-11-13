// Pip Dictée for Windows — free, 100 % local voice dictation.
// Hold Ctrl + Win and talk, release and the text is typed where the cursor is.
// Ctrl + Win + Space = hands-free (press Ctrl + Win again to finish). Esc cancels.
// Speech is transcribed on this PC by whisper.cpp (whisper-server.exe), kept loaded in a local server.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]
#![cfg_attr(not(windows), allow(dead_code))]

mod cleanup;
mod i18n;
mod store;
#[cfg(windows)]
mod win;

#[cfg(windows)]
fn main() { win::app::run(); }

#[cfg(not(windows))]
fn main() {
    eprintln!("This is the Windows edition of Pip Dictée. On macOS, build macos/ with ./macos/build.sh.");
    std::process::exit(1);
}
