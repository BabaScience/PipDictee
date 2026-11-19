# Changelog

## 2.3.1 — 2026-11-19

**Both apps**
- Fixed: dictations much slower since 2.3.0 (on Windows, about 20 s instead of 2 s). Asking Whisper for its
  segments, for paragraphs, also made it score every language with a second pass of the model. Pip no longer asks
  for that.

## 2.3.0 — 2026-11-17

**Both apps**
- Fixed: words cut in two ("trans cribing", "l' analyse"). Whisper's server could split its text inside a word, and
  the clean-up turned each split into a space. Pip now asks it to split between words only, and joins the pieces as
  they are.
- Paragraphs on their own: a new paragraph where a sentence ends and you paused for a second or more.
- A better dictionary hint for Whisper: your newest words, written so it no longer joins sentences with commas, and
  without entries that aren't words (like "@").
- macOS: `PipDictee --transcribe file.wav` prints what Pip would type for a recording (for testing).
- Update notifications: once a day Pip asks GitHub for the latest version number. When a newer one is out, the pill
  says so once, and the panel, the tray menu (Windows) and Settings › About show a download link. Nothing is
  downloaded or installed by itself. Off in Settings › Privacy › Check for updates; "Check now" in About.
- Releases are published automatically when a version tag is pushed on `main` (no more drafts), with the notes
  from this changelog, SHA-256 sums and a signed build provenance.

## 2.2.0 — 2026-11-17

**Both apps**
- `skills/install-pip-dictee`: a skill that lets an AI agent (Claude Code, Claude Desktop) install Pip, check it
  and walk you through setup.

**Windows**
- Fixed: every dictation came back empty. whisper.cpp crashed while opening the model because the folder path
  contains an accent ("Pip Dictée", or a user name like "José"). It now runs inside the models folder with plain
  file names.
- The log now says why the speech engine stopped (exit code), notices within seconds if it can't start, and no
  longer restarts it in a loop.
- A speed test picks the voice model for each PC: Pip times this computer and keeps the most accurate model that
  stays quick (large-v3-turbo on a fast PC or a GPU, a smaller one on a laptop running on its processor alone).
- Settings › General › Voice model: choose Accurate (large-v3-turbo, 1.5 GB), Balanced (small, 252 MB) or Fast
  (base, 77 MB), with each one's expected time on this PC and the speed test's recommendation. A model picked by
  hand is downloaded there and the previous one is kept, so switching back is instant. "Test speed again" re-runs
  the test.
- Intel graphics: with the Accurate model, Pip downloads an OpenVINO build of whisper.cpp and the model's encoder
  (1.3 GB, checked with SHA-256), times it, and uses it if it beats the processor. On a Core Ultra 7 laptop,
  dictations went from about 31 s to between 4 and 12 s, with the same text. If it fails to start, Pip goes back to
  the processor. The files are built by `scripts/build-openvino-windows.ps1`.
- Faster on the processor too: the engine uses the processor's fast cores only (performance cores on Intel's
  hybrid chips), and the dictation language now defaults to Windows' language instead of automatic detection,
  which made every dictation about twice as slow.
- Fixed: the pill blinked while listening. Each sound-level update rebuilt it, restarting its pop-in animation;
  the bars and the timer are now updated in place.
- A dictation made while the engine restarts (after a model change) waits for it instead of falling back to the
  much slower one-shot mode.

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
