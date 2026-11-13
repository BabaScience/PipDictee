#!/bin/zsh
# Builds Pip Dictée for macOS.
#   ./build.sh            → build/Pip Dictée.app
#   ./build.sh install    → also copies it to ~/Applications and starts it
#
# Code signing: macOS ties the microphone and Accessibility permissions to the signature, so signing with
# the same identity every time keeps them across rebuilds. Put yours in signing.local (git-ignored):
#   PIP_SIGN_IDENTITY="My Personal Signing"
# Without one, the app is signed ad hoc and macOS asks for the permissions again after each rebuild.
set -euo pipefail
cd "${0:A:h}"

[[ -f signing.local ]] && source ./signing.local
IDENTITY="${PIP_SIGN_IDENTITY:--}"

APP="build/Pip Dictée.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/PipDictee" Sources/*.swift \
  -framework AppKit -framework AVFoundation -framework Carbon -framework ServiceManagement -framework SwiftUI -framework CryptoKit
cp Info.plist "$APP/Contents/Info.plist"
# The app icon, drawn by the app itself (Sources/AppIcon.swift), so it always matches its Pip.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/PipDictee" --render-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"

# Translations: the shared JSON files (shared/i18n, also used on Windows) become Localizable.strings.
for d in Resources/*.lproj; do cp -R "$d" "$APP/Contents/Resources/"; done
for f in ../shared/i18n/*.json; do
  plutil -convert binary1 -o "$APP/Contents/Resources/$(basename "$f" .json).lproj/Localizable.strings" "$f"
done

# Hardened runtime, with the microphone as the only exception (see PipDictee.entitlements).
sign() { codesign --force --options runtime --entitlements PipDictee.entitlements --identifier fr.pip.dictee --sign "$1" "$APP"; }
if ! sign "$IDENTITY" 2>/dev/null; then
  echo "Signing with \"$IDENTITY\" failed; signing ad hoc." >&2
  sign -
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x PipDictee || true
  sleep 0.5
  rm -rf ~/Applications/"Pip Dictée.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Pip Dictée.app"
  echo "Installed and started."
fi
