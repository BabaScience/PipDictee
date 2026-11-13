#!/bin/zsh
# Renders the Windows app's icons and installer images from the macOS app's Pip (one drawing for both apps),
# then packs the .ico.
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
# The installer wants bitmaps for its wizard images: classic 24-bit, bottom-up BMPs, which every Inno Setup reads.
for f in wizard wizard-2x wizard-small wizard-small-2x; do
  sips -s format bmp "$OUT/$f.png" --out "$OUT/$f.bmp" >/dev/null && rm "$OUT/$f.png"
done
python3 - "$OUT" <<'PY'
import struct, sys, pathlib
for f in pathlib.Path(sys.argv[1]).glob("wizard*.bmp"):
    d = f.read_bytes()
    off, = struct.unpack_from("<I", d, 10)
    w, h, _, bpp = struct.unpack_from("<iiHH", d, 18)
    top_down, h = h < 0, abs(h)
    src_row = ((w * bpp + 31) // 32) * 4
    rows = [d[off + y * src_row: off + y * src_row + w * bpp // 8] for y in range(h)]
    if not top_down: rows.reverse()                       # now top row first
    dst_row = ((w * 24 + 31) // 32) * 4
    px = bytearray()
    for r in reversed(rows):                              # bottom-up for the file
        line = bytearray()
        for x in range(w):
            b, g, r_, *a = r[x * bpp // 8: x * bpp // 8 + bpp // 8]
            line += bytes((b, g, r_))
        px += line + b"\0" * (dst_row - len(line))
    head = struct.pack("<2sIHHI", b"BM", 54 + len(px), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(px), 2835, 2835, 0, 0)
    f.write_bytes(head + info + bytes(px))
PY
echo "wrote installer images"
