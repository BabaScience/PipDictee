# Changelog

## Unreleased

**Windows**
- Fixed: every dictation came back empty. whisper.cpp crashed while opening the model because the folder path
  contains an accent ("Pip Dictée", or a user name like "José"). It now runs inside the models folder with plain
  file names.
- The log now says why the speech engine stopped (exit code), notices within seconds if it can't start, and no
  longer restarts it in a loop.

## 2.1.0 — first open-source release

**Both apps**
- Pip's interface: the floating pill with Pip's moods, a panel from the menu bar / tray, a settings window
  (editable dictionary, history, privacy) and a first-launch setup that checks each step.
- Six interface languages (English, French, German, Italian, Spanish, Portuguese), switchable live.
- Dictation clean-up for Spanish and Portuguese, alongside English, French, German and Italian.
- Data files renamed to English (`dictionary.json`, `history.json`); older files are migrated automatically.
- Privacy: private data folder, dictations hidden from clipboard managers, history can be turned off,
  external control off by default, verified downloads.

**macOS**
- Hardened runtime, app icon drawn from Pip, `--snapshot` screenshots in every language.

**Windows** (new, not yet tested on many PCs: please report issues)
- Native app in Rust with WebView2 windows, Ctrl + Win shortcut, in-app download of whisper.cpp and the model.
- Installer (`PipDictee-Setup-<version>.exe`): per-user, no administrator rights, six languages, Start-menu and
  optional desktop shortcuts, optional open at sign-in, checks for WebView2, and an uninstaller that asks before
  deleting your data.
