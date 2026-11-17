---
name: install-pip-dictee
description: Install Pip Dictée, the free, 100 % local push-to-talk voice dictation app, on the user's Mac or Windows PC, then walk them through its first-launch setup and check that dictation works. Use when the user asks to install, set up, reinstall, update or uninstall Pip Dictée (or "Pip", "PipDictee"), or asks for a free/local/offline dictation app like Wispr Flow and agrees to Pip Dictée. Needs a shell on the user's own computer (PowerShell on Windows, zsh on macOS).
---

# Install Pip Dictée

Pip Dictée turns speech into text in any app: hold a shortcut, speak, release, and the text is typed where the
cursor is. Everything runs on the user's computer with whisper.cpp; nothing is sent online.
Repository: https://github.com/BabaScience/PipDictee

You do the downloads, checks and builds. The user does what only a person can do: speak into the microphone,
grant macOS permissions, and click through Windows' warning for unsigned apps. Tell them when it's their turn.

## Ground rules

- **Say what you'll download and install before doing it**, with sizes, and wait for a yes. Total: about 10 MB for
  the app, then 0.1–3 GB that the app downloads itself (whisper.cpp and a voice model, more on PCs with Intel
  graphics). Building from source adds the toolchain (Rust or Xcode tools, 1–4 GB).
- **Download only from** `github.com/BabaScience/PipDictee` (releases or source), `github.com/ggml-org/whisper.cpp`,
  `huggingface.co`, `brew.sh`, `rustup.rs`, and Microsoft or Apple. Check every release download against the
  release's `SHA256SUMS.txt`; delete it and stop if the hash differs.
- **Never weaken the system's protections**: don't turn off SmartScreen or Gatekeeper, don't remove quarantine
  attributes, don't run anything as administrator. Pip installs per user and needs no admin rights.
- **Don't grant permissions on the user's behalf** (microphone, Accessibility). Tell them where to click.
- **Report what actually happened.** If a step fails, show the error and the relevant log lines (see Checking).

## 1. Look at the computer

- **Windows**: needs Windows 10 version 1809 or later, 64-bit (x64), and WebView2 (built into Windows 11 and up-to-date
  Windows 10). `[Environment]::OSVersion.Version`, `$env:PROCESSOR_ARCHITECTURE` (must be `AMD64`).
- **macOS**: needs macOS 14 Sonoma or later (`sw_vers -productVersion`); Apple Silicon recommended.
- **Disk**: about 3 GB free to be safe.
- **Already installed?**
  - Windows: `%LOCALAPPDATA%\Programs\Pip Dictée\PipDictee.exe`.
  - macOS: `~/Applications/Pip Dictée.app` or `/Applications/Pip Dictée.app`.

  If it is, ask whether to update. An update keeps the dictionary, history, settings and models.
- **Is a release published?** `https://api.github.com/repos/BabaScience/PipDictee/releases/latest` returns 404 when
  there's none yet. Then use the "from source" path for that system.

## 2a. Windows, from the release (preferred)

```powershell
$rel = Invoke-RestMethod https://api.github.com/repos/BabaScience/PipDictee/releases/latest
$setup = $rel.assets | Where-Object name -like 'PipDictee-Setup-*.exe'
$sums  = $rel.assets | Where-Object name -eq 'SHA256SUMS.txt'
$dir = Join-Path $env:TEMP "pip-dictee-install"; New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest $setup.browser_download_url -OutFile "$dir\$($setup.name)" -UseBasicParsing
Invoke-WebRequest $sums.browser_download_url -OutFile "$dir\SHA256SUMS.txt" -UseBasicParsing
$want = (Select-String "$dir\SHA256SUMS.txt" -Pattern ([regex]::Escape($setup.name))).Line.Split(' ')[0]
$got  = (Get-FileHash "$dir\$($setup.name)" -Algorithm SHA256).Hash.ToLower()
if ($want -ne $got) { Remove-Item "$dir\$($setup.name)"; throw "Checksum mismatch: deleted the download." }
```

Run the installer. To let the user choose options, run it normally (`Start-Process "$dir\$($setup.name)"`). It
asks the language, then offers a desktop shortcut and "open at sign-in". For a quiet install with the defaults
(open at sign-in, no desktop shortcut):

```powershell
Start-Process "$dir\$($setup.name)" -ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS="autostart"' -Wait
Start-Process "$env:LOCALAPPDATA\Programs\Pip Dictée\PipDictee.exe"
```

The installer isn't code-signed yet. If Windows shows *"Windows protected your PC"*, the user clicks
**More info › Run anyway**. The installer closes a running Pip and restarts it after an update. If WebView2 is
missing, it says so and links to Microsoft's download.

Then go to step 3.

## 2b. Windows, from source (no release yet, or the user prefers it)

Needs git, Rust (https://rustup.rs) and the Visual Studio 2022 Build Tools with the C++ workload, for the linker.
Check what's there (`git --version`, `cargo --version`). Ask before installing anything missing, e.g.:

```powershell
winget install --id Git.Git -e
winget install --id Rustlang.Rustup -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

Open a new shell afterwards so PATH is updated. Then:

```powershell
git clone https://github.com/BabaScience/PipDictee.git "$env:USERPROFILE\PipDictee"
cd "$env:USERPROFILE\PipDictee\windows"
cargo build --release          # a few minutes the first time
Start-Process .\target\release\PipDictee.exe
```

To make it the installed copy (Start menu and sign-in use `%LOCALAPPDATA%\Programs\Pip Dictée`), the release
installer is the clean way. Without one, ask before copying `target\release\PipDictee.exe` there.

Optional, NVIDIA GPU: `powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Cuda` (from the
repository root) installs the CUDA build of whisper.cpp, which is much faster. Intel graphics need nothing: Pip
sets up OpenVINO itself when the user picks the Accurate model.

## 2c. macOS (from source, the documented way)

Needs Homebrew (https://brew.sh) and the Xcode command-line tools. `xcode-select -p` fails when they're missing.
`xcode-select --install` opens a dialog the user has to accept.

```bash
brew install whisper-cpp
git clone https://github.com/BabaScience/PipDictee.git ~/PipDictee
cd ~/PipDictee && ./macos/build.sh install     # builds, copies to ~/Applications, starts it
```

Release zips (`PipDictee-macOS.zip`) are signed ad hoc, not notarized, so Gatekeeper blocks them. Prefer the source
build, and never strip the quarantine attribute for the user.

macOS ties permissions to the app's signature. A rebuild without a personal signing identity asks for them
again; see the top of `macos/build.sh` (`signing.local`).

## 3. First launch: hand over to the user

Pip opens a short setup window. Tell the user, in their language, what each step needs from them:

1. **Microphone check**: they say a few words. Windows may need **Settings › Privacy › Microphone › Let desktop
   apps access your microphone**; macOS shows a permission prompt.
2. **macOS only: Accessibility**, so Pip can notice the shortcut and type. They tick Pip Dictée in
   **System Settings › Privacy & Security › Accessibility**.
3. **Downloads and speed test**: automatic. On Windows, Pip times the PC and picks the most accurate model that
   stays quick: Accurate (large-v3-turbo, 1.5 GB), Balanced (small, 252 MB) or Fast (base, 77 MB). They can change
   it later in **Settings › General › Voice model**; smaller models make more mistakes, especially outside English.
4. **First dictation**: hold the shortcut, speak, release.
   - Windows: **Ctrl + Win**
   - macOS: **⌃⌥** (Control + Option)

Pip lives in the notification area (Windows) or the menu bar (macOS).

## Checking

Read the log rather than guessing. It records events and timings, never what was said.

- Windows: `%APPDATA%\Pip Dictée\pip-dictee.log`
- macOS: `~/Library/Application Support/Pip Dictée/pip-dictee.log`

Good signs:
- `whisper-server ready`: the engine is running.
- `model chosen: …` / `speed test: …`: Windows' choice of model and why.
- `… OpenVINO on the Intel graphics`: Intel acceleration is on.
- Windows: `transcribed in 3.12 s: 84 chars` after each dictation (`0 chars` means nothing was heard).

Common problems:
- `whisper-server stopped while loading: exit code … (a DLL is missing)`: the Microsoft Visual C++ runtime is
  missing. Ask before installing it: `winget install --id Microsoft.VCRedist.2015+.x64 -e`.
- `checksum mismatch`: a download was corrupted or tampered with, and Pip deleted it. Retry from Settings
  (**Test speed again**). If it persists, report it as an issue.
- "I didn't hear anything": wrong or muted microphone in the system's sound settings. The setup window shows
  which one Pip uses.
- Dictations are slow on Windows: compare the model in Settings with the speed test's recommendation. Setting the
  dictation language explicitly (instead of automatic) is about twice as fast.

Problems you can't solve: point the user to https://github.com/BabaScience/PipDictee/issues, with the log lines.

## Uninstall

- **Windows**: **Settings › Apps › Pip Dictée › Uninstall**, or run
  `%LOCALAPPDATA%\Programs\Pip Dictée\unins000.exe`. It asks whether to also delete the data (dictionary,
  history, models). Ask the user that question yourself rather than answering it for them.
- **macOS**: quit Pip, delete `Pip Dictée.app`. Its data is in `~/Library/Application Support/Pip Dictée`; delete
  it only if the user says so. `brew uninstall whisper-cpp` removes the engine.
