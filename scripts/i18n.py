#!/usr/bin/env python3
"""Checks the translations in shared/i18n/ against the strings the apps actually use.

  python3 scripts/i18n.py          check: every key used in the code is translated in every language,
                                   no file has unused keys, and %@ placeholders match. Exit code 1 if not.
  python3 scripts/i18n.py keys     print every key used in the code (one JSON string per line)

Keys are the English text, as written in L("…") in macos/Sources/*.swift, t("…") / tf("…") in windows/src/**/*.rs,
and t("…") in windows/ui/ui.html.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGS = ["fr", "de", "it", "es", "pt"]
STRING = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = {".swift": re.compile(r'\b(?:L)\(' + STRING), ".rs": re.compile(r'\b(?:t|tf)\(' + STRING),
            ".html": re.compile(r'\bt\(' + STRING)}


def unescape(s: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def used_keys() -> dict:
    keys = {}
    files = (list((ROOT / "macos/Sources").glob("*.swift")) + list((ROOT / "windows/src").rglob("*.rs"))
             + list((ROOT / "windows/ui").glob("*.html")))
    for f in files:
        pattern = PATTERNS[f.suffix]
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in pattern.finditer(line):
                keys.setdefault(unescape(m.group(1)), f"{f.relative_to(ROOT)}:{n}")
    return keys


def main() -> int:
    keys = used_keys()
    if sys.argv[1:] == ["keys"]:
        for k in sorted(keys):
            print(json.dumps(k, ensure_ascii=False))
        return 0
    problems = []
    for lang in LANGS:
        path = ROOT / "shared/i18n" / f"{lang}.json"
        try:
            table = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{path.name}: cannot read ({e})")
            continue
        for k, where in keys.items():
            if k not in table:
                problems.append(f"{lang}: missing {json.dumps(k, ensure_ascii=False)} (used at {where})")
            elif k.count("%@") != table[k].count("%@"):
                problems.append(f"{lang}: %@ count differs for {json.dumps(k, ensure_ascii=False)}")
            elif not table[k].strip():
                problems.append(f"{lang}: empty translation for {json.dumps(k, ensure_ascii=False)}")
        for k in table:
            if k not in keys:
                problems.append(f"{lang}: unused key {json.dumps(k, ensure_ascii=False)}")
    for p in problems:
        print(p)
    print(f"{len(keys)} strings × {len(LANGS)} languages: " + ("all translated" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
