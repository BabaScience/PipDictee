# Contributing

Thanks for helping! Pip Dictée is small on purpose: one Swift file for macOS, a small Rust crate for Windows.

## Setup

```bash
git config core.hooksPath .githooks   # secret scan before each commit (needs gitleaks: brew install gitleaks)
```

- macOS: `./scripts/setup-macos.sh`, then `./macos/build.sh` (or `install` to run it).
- Windows: `scripts\setup-windows.ps1`, then `cargo build` in `windows/`.

## Checks (CI runs the same)

```bash
# Clean-up rules, both implementations
./macos/build.sh && "macos/build/Pip Dictée.app/Contents/MacOS/PipDictee" --test-cleanup shared/cleanup-cases.json
cd windows && cargo test

# Every macOS screen as PNG, with sample data (attach them to UI pull requests)
"macos/build/Pip Dictée.app/Contents/MacOS/PipDictee" --snapshot /tmp/pip-snapshots

# Every Windows screen, in a browser, with sample data (any language: lang=de…)
python3 -m http.server 8765   # from the repository root, then open:
#   http://127.0.0.1:8765/windows/ui/ui.html#gallery&lang=fr

# Windows build from a Mac or Linux (type-check only)
rustup target add x86_64-pc-windows-msvc && cargo check --target x86_64-pc-windows-msvc
```

## Rules of the house

- **Clean-up changes go in both apps** plus a case in `shared/cleanup-cases.json`, in the same pull request.
- **Local only.** No network calls other than `127.0.0.1` without an issue to discuss it first.
- **Never log or upload what the user said.** Lengths and timings are fine.
- **No personal data in commits**: no history, dictionary, logs, models, signing identities or keys.
  The pre-commit hook and CI will refuse them.
- Keep the user's data format compatible: `dictionary.json` and `history.json` are shared by both apps
  (files from before 2.1 used French names and keys; the macOS app migrates them, both apps can read them).
- UI text is in English. Spoken commands and filler words stay multilingual: they are what users say, not UI.

## Translations

The interface is translated into French, German, Italian, Spanish and Portuguese. Both apps share the same files:
`shared/i18n/<lang>.json`, which map each English string (the key) to its translation. `%@` is a value filled in at
run time (a number, an app name): keep it, in any position that reads naturally.

- **Fix a translation:** edit the JSON file. That's all.
- **Add a string in code:** write it in English inside `L("…")` (Swift) or `t("…")` / `tf("…", &[…])` (Rust), then add it
  to every JSON file. `python3 scripts/i18n.py` lists what's missing (CI runs it too).
- **Add a language:** copy `fr.json` to `<code>.json`, translate the values, and add the code to `LANGS` in
  `scripts/i18n.py`, `FILES` in `windows/src/i18n.rs`, `CFBundleLocalizations` in `macos/Info.plist`, and an
  `InfoPlist.strings` in `macos/Resources/<code>.lproj/` (the microphone permission text).
- **Check the layout:** `PipDictee --snapshot /tmp/shots de` renders every screen in German (the longest language).

Translations were first written by the maintainers; corrections from native speakers are very welcome.

Dictation clean-up (filler words, spoken commands like "nueva línea") is separate from the interface: it lives in
`clean()` / `cleanup.rs` and is tested by `shared/cleanup-cases.json`.

## Pull requests

Small and focused, with a sentence on what you tested and on which OS. For a UI change, a screenshot helps.
