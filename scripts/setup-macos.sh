#!/bin/zsh
# Pip Dictée — macOS setup: installs whisper.cpp (Homebrew) and downloads the Whisper model, checking its SHA-256.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Pip Dictée"
MODELS="$SUPPORT/models"
mkdir -p "$MODELS"
chmod 700 "$SUPPORT"

if ! command -v whisper-server >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh" >&2; exit 1; }
  brew install whisper-cpp
fi

fetch() { # name url sha256
  local dest="$MODELS/$1"
  if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$3" ]]; then echo "OK (already there): $1"; return; fi
  echo "Downloading $1…"
  curl -fL --proto '=https' --tlsv1.2 -o "$dest.part" "$2"
  local got; got="$(shasum -a 256 "$dest.part" | cut -d' ' -f1)"
  if [[ "$got" != "$3" ]]; then
    rm -f "$dest.part"
    echo "SHA-256 mismatch for $1 (expected $3, got $got). The file was deleted." >&2; exit 1
  fi
  mv "$dest.part" "$dest"; echo "OK (verified): $1"
}

fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin \
  1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin \
  29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf

echo "\nReady. Now build and start the app:  ./macos/build.sh install"
