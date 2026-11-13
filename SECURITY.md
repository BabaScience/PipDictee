# Security and privacy

Pip Dictée hears everything you dictate, and can type into any app. That's a lot of trust, so the design keeps
the attack surface small and keeps your words on your machine.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Use GitHub's private
[security advisory](../../security/advisories/new) form for this repository instead. You'll get an answer within
a week. Please include the steps to reproduce and the OS version.

## What stays on your computer

- **Audio** is recorded to the per-user temporary folder and deleted as soon as it's transcribed (or at the next
  launch, after a crash). It is never uploaded.
- **Transcription** runs locally in whisper.cpp. The app talks to `127.0.0.1` only (the local whisper server,
  and, on macOS, Ollama if you turn on "Local AI clean-up") — with one exception, at setup: it downloads the voice
  model (and, on Windows, whisper.cpp) over HTTPS from Hugging Face and GitHub, checks each file's SHA-256, and
  never contacts them again. Nothing about you or your voice is sent: these are plain file downloads.
- **History** (last 200 dictations) and your **dictionary** are plain JSON files in your user data folder.
  On macOS the folder is `0700` and the files `0600`. You can turn history off or clear it from the menu.
- **The log** records events, timings and lengths — never the words you said.
- **The clipboard**: dictations are marked as concealed/transient (macOS, nspasteboard.org convention) or
  excluded from clipboard history and cloud sync (Windows), so clipboard managers don't keep them.

## Hardening in the code

| Risk | Mitigation |
|---|---|
| Another local program uses Pip Dictée's microphone permission to listen | The `fr.pip.dictee.toggle` / `.file` notifications are **off by default** (menu: "Allow control by other apps"). The file hook only accepts existing `.wav` files. |
| A malicious `whisper-server` earlier on `PATH` | macOS: only `/opt/homebrew/bin` and `/usr/local/bin`. Windows: only next to `PipDictee.exe` or `%LOCALAPPDATA%\Pip Dictée\bin`. `PATH` is never searched. |
| Tampered downloads | `scripts/setup-*.{sh,ps1}` pin versions and verify SHA-256 of whisper.cpp and models before use; a mismatch deletes the file. |
| Orphaned server holding the port | macOS kills a stale server at launch; Windows runs it in a Job Object that dies with the app. |
| Code injection into the app | macOS: hardened runtime, only entitlement is `audio-input`. |
| Other users on the same machine | Data folder is private (see above). The server listens on loopback only. |
| A web page inside the app (Windows uses WebView2 for its windows) | The page is built into the .exe, with a strict Content-Security-Policy; navigation and new windows are refused; dictated text is only ever inserted as text, never as HTML; the page's messages are validated, and it can open only four fixed destinations (microphone settings, data folder, source code, issues). |
| Tampered downloads on first launch (Windows) | whisper.cpp and the models are downloaded over HTTPS only, with Windows' own TLS, checked against pinned SHA-256 before use; archives are unpacked by file name only. |
| Secrets committed to the repo | `.gitignore` excludes user data, models, logs, signing config; `.githooks/pre-commit` and CI run gitleaks. |

## Known limitations

- The whisper server on `127.0.0.1:18765` has no authentication. Any local process (as your user) can send it
  audio to transcribe; it cannot read your history through it. Browsers block web pages from reading its
  responses. A per-launch random port and token is on the roadmap.
- Pasting works by simulating ⌘V / Ctrl+V into the front app. If focus changes between the end of the dictation
  and the paste, the text lands in the newly focused app.
- Like every keyboard-shortcut app, the macOS version needs Accessibility permission, and the Windows version
  installs a keyboard hook. Both only react to the configured shortcut, Space, and Esc; no keystrokes are
  recorded or logged.

## For contributors

- Never commit anything from your data folder (`history.json`, `dictionary.json`, `*.log`, `models/`).
- Enable the pre-commit hook once: `git config core.hooksPath .githooks` (it needs `gitleaks`).
- Don't add network calls to anything other than `127.0.0.1` without discussing it in an issue first.
- Never log transcription text.
