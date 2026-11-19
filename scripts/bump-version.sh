#!/usr/bin/env bash
# Sets the version everywhere a release needs it, so the tag and the apps always agree (the Release workflow
# refuses a tag whose version doesn't match both apps).
#
#   scripts/bump-version.sh 2.3.1
#
# Changes windows/Cargo.toml (+ Cargo.lock), macos/Info.plist (version, and the build number + 1), the installer's
# default version, and renames "## Unreleased" in CHANGELOG.md to "## 2.3.1 — <today>". Commits nothing: check
# `git diff`, commit, push to main, then `git tag v2.3.1 && git push origin v2.3.1`.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/bump-version.sh X.Y.Z" >&2; exit 2
fi
if ! grep -q '^## Unreleased$' CHANGELOG.md; then
  echo "CHANGELOG.md has no '## Unreleased' section: write what changed there first." >&2; exit 1
fi

# Windows
sed -i.bak "s/^version = \"[^\"]*\"/version = \"$version\"/" windows/Cargo.toml
sed -i.bak "s/#define AppVersion \"[^\"]*\"/#define AppVersion \"$version\"/" windows/installer/PipDictee.iss
# Cargo.lock: only this package's own entry.
awk -v v="$version" '
  /^name = "pip-dictee"$/ { print; mine = 1; next }
  mine && /^version = / { print "version = \"" v "\""; mine = 0; next }
  { mine = 0; print }' windows/Cargo.lock > windows/Cargo.lock.new && mv windows/Cargo.lock.new windows/Cargo.lock

# macOS: edited as text, so the file keeps its one-line-per-key layout.
build=$(sed -n 's|.*<key>CFBundleVersion</key><string>\([0-9]*\)</string>.*|\1|p' macos/Info.plist)
sed -i.bak \
  -e "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$version</string>|" \
  -e "s|<key>CFBundleVersion</key><string>[0-9]*</string>|<key>CFBundleVersion</key><string>$((build + 1))</string>|" \
  macos/Info.plist

# Release notes
sed -i.bak "s/^## Unreleased$/## $version — $(date +%Y-%m-%d)/" CHANGELOG.md

rm -f windows/Cargo.toml.bak windows/installer/PipDictee.iss.bak macos/Info.plist.bak CHANGELOG.md.bak
plutil -lint macos/Info.plist >/dev/null 2>&1 || python3 -c "import plistlib; plistlib.load(open('macos/Info.plist','rb'))"

echo "Version $version (macOS build $((build + 1))). Next:"
echo "  git diff            # check"
echo "  git commit -am \"Version $version\" && git push origin main"
echo "  git tag v$version && git push origin v$version"
