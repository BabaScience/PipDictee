#!/bin/zsh
# Renders the Windows app's icons from the macOS app's Pip (one drawing for both apps), then packs the .ico.
# Run on a Mac after changing Pip: ./scripts/make-windows-assets.sh   (the results are committed in windows/assets/)
set -euo pipefail
cd "${0:A:h}/.."
./macos/build.sh >/dev/null
OUT=windows/assets
mkdir -p "$OUT"
"macos/build/Pip Dictée.app/Contents/MacOS/PipDictee" --render-windows-assets "$OUT"
python3 - "$OUT" <<'PY'
import struct, sys, pathlib
out = pathlib.Path(sys.argv[1])
sizes = [16, 24, 32, 48, 64, 128, 256]
pngs = [(out / f"icon-{s}.png").read_bytes() for s in sizes]
# An .ico of PNG images (supported since Windows Vista): header, one directory entry per size, then the PNGs.
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, data in zip(sizes, pngs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
(out / "pip-dictee.ico").write_bytes(header + entries + b"".join(pngs))
for s in sizes:
    if s != 64: (out / f"icon-{s}.png").unlink()
print("wrote", out / "pip-dictee.ico")
PY
