#!/usr/bin/env python3
"""Localization completeness check for Kumquat.

Extracts the English keys used in Sources/ (SwiftUI literals in Text/Button/Label/Toggle/…, the L()/Lp()
helpers, KumquatError(l:), the Errors table in ErrorStrings and the app's own components that localize a
String parameter) and compares them with Resources/{en,ru}.lproj/*.strings.

Reports keys missing from each language, unused keys, plural forms that are missing, and SwiftUI literals
with interpolation (those become "%lld"/"%@" keys and should go through L() instead).

Usage: scripts/check-l10n.py [--verbose]    Exit status 1 when anything is missing.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Kumquat"
RESOURCES = ROOT / "Resources"
LANGS = ["en", "ru"]
PLURAL_FORMS = {"en": ["one", "other"], "ru": ["one", "few", "many"]}
# CLI output stays English.
SKIP_FILES = {"CommandLineMode.swift"}

LIT = r'"((?:[^"\\\n]|\\.)*)"'
# Plain lookups: the first literal argument is the key.
PLAIN_PATTERNS = [
    r'\bL\(\s*' + LIT,
    r'KumquatError\(l:\s*' + LIT,
    # SwiftUI views whose literal argument is a LocalizedStringKey.
    r'\b(?:Text|Button|Label|Toggle|Picker|Section|Menu|TextField|SecureField|ColorPicker|Stepper|GroupBox|LabeledContent|Link)\(\s*' + LIT,
    r'\.help\(\s*' + LIT,
    r'\.navigationTitle\(\s*' + LIT,
    # Kumquat components that run their String parameter through L().
    r'\bOptionRow\(\s*' + LIT,
    r'\bSliderRow\(title:\s*' + LIT,
    r'\bhelp:\s*' + LIT,
    r'\bsaveTitle:\s*(?:String\s*=\s*)?' + LIT,
    r'\bsaveHelp:\s*(?:String\s*=\s*)?' + LIT,
    r'\bTimelineKeyHint\(key:\s*' + LIT,
    r'\bTimelineKeyHint\(key:\s*"(?:[^"\\]|\\.)*",\s*text:\s*' + LIT,
    r'unavailableText(?::|\s*=)\s*' + LIT,
    r'\btimeRow\(\s*' + LIT,
    r'\btool\(\s*"[^"]*",\s*' + LIT,          # OrganizePDF toolbar: tool(symbol, help)
]
PLURAL_PATTERN = r'\bLp\(\s*' + LIT
ERRORS_PATTERN = r'\bt\(\s*' + LIT + r',\s*' + LIT     # ErrorStrings.t(key, english)
INTERPOLATED_SWIFTUI = r'\b(?:Text|Button|Label|Toggle|Picker|Section|Menu|Stepper)\(\s*"[^"\n]*\\\('


def unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and s[i + 2:i + 3] == "{":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16)))
                i = j + 1
                continue
            out.append({"n": "\n", "t": "\t", "0": "\0", "\\": "\\", '"': '"', "'": "'"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_comments(text: str) -> str:
    # Drops // comments (outside string literals) so commented-out code doesn't count.
    lines = []
    for line in text.split("\n"):
        in_str, i, cut = False, 0, None
        while i < len(line):
            c = line[i]
            if c == "\\" and in_str:
                i += 2
                continue
            if c == '"':
                in_str = not in_str
            elif not in_str and line.startswith("//", i):
                cut = i
                break
            i += 1
        lines.append(line if cut is None else line[:cut])
    return "\n".join(lines)


def has_letters(s: str) -> bool:
    return re.search(r"[A-Za-z]", s) is not None


def extract():
    plain, plural, errors, interpolated = {}, {}, {}, []
    for f in sorted(SOURCES.rglob("*.swift")):
        if f.name in SKIP_FILES:
            continue
        text = strip_comments(f.read_text())
        rel = f.relative_to(ROOT)

        def where(m):
            return f"{rel}:{text.count(chr(10), 0, m.start()) + 1}"

        for p in PLAIN_PATTERNS:
            for m in re.finditer(p, text):
                raw = m.group(1)
                if "\\(" in raw:
                    continue
                key = unescape(raw)
                if has_letters(key):
                    plain.setdefault(key, where(m))
        for m in re.finditer(PLURAL_PATTERN, text):
            plural.setdefault(unescape(m.group(1)), where(m))
        for m in re.finditer(ERRORS_PATTERN, text):
            errors.setdefault(unescape(m.group(1)), (unescape(m.group(2)), where(m)))
        for m in re.finditer(INTERPOLATED_SWIFTUI, text):
            interpolated.append(where(m))
    return plain, plural, errors, interpolated


def load_strings(path: Path):
    if not path.exists():
        return None
    lint = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    if lint.returncode != 0:
        print(lint.stdout.strip() or lint.stderr.strip())
        sys.exit(2)
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def format_specs(s: str):
    # Positional specifiers (%2$d) count as their plain form; translations may reorder arguments.
    specs = re.findall(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ld|lld|[@dfsgu])", s)
    return sorted(re.sub(r"^%\d+\$", "%", x) for x in specs)


def main():
    verbose = "--verbose" in sys.argv
    plain, plural, errors, interpolated = extract()
    problems = 0

    # Keys that live only in the tables (their English differs from the key).
    contextual = {"language.system", "credits.and"}

    print(f"Keys in code: {len(plain)} plain, {len(plural)} plural, {len(errors)} in the Errors table")
    for lang in LANGS:
        table = load_strings(RESOURCES / f"{lang}.lproj" / "Localizable.strings") or {}
        err_table = load_strings(RESOURCES / f"{lang}.lproj" / "Errors.strings") or {}

        missing = [k for k in plain if k not in table]
        missing_plural = [f"{k}#{form}" for k in plural for form in PLURAL_FORMS[lang] if f"{k}#{form}" not in table]
        missing_errors = [k for k in errors if k not in err_table]
        expected = set(plain) | {f"{k}#{f}" for k in plural for f in ["one", "few", "many", "other"]} | contextual
        unused = sorted(k for k in table if k not in expected)
        unused_errors = sorted(k for k in err_table if k not in errors)

        # Format specifiers must survive translation.
        bad_specs = []
        for k, v in table.items():
            base = k.split("#")[0] if k.split("#")[0] in plural else k
            if format_specs(base) != format_specs(v) and k not in contextual:
                bad_specs.append(k)
        for k, v in err_table.items():
            if k in errors and format_specs(errors[k][0]) != format_specs(v):
                bad_specs.append(f"Errors:{k}")

        print(f"\n[{lang}] Localizable.strings: {len(table)} entries, Errors.strings: {len(err_table)} entries")
        for title, items, fatal in [("missing", missing, True), ("missing plural forms", missing_plural, True),
                                    ("missing in Errors.strings", missing_errors, True),
                                    ("format specifiers differ", bad_specs, True),
                                    ("unused", unused, False), ("unused in Errors.strings", unused_errors, False)]:
            print(f"  {title}: {len(items)}")
            if items and (fatal or verbose):
                for k in items:
                    src = plain.get(k) or (plural.get(k.split("#")[0]) if "#" in k else "") or ""
                    print(f"    {json.dumps(k, ensure_ascii=False)}  {src}")
            if fatal:
                problems += len(items)

    # InfoPlist.strings / ServicesMenu.strings: every language has the same keys.
    for name in ["InfoPlist.strings", "ServicesMenu.strings"]:
        tables = {lang: load_strings(RESOURCES / f"{lang}.lproj" / name) for lang in LANGS}
        if any(t is None for t in tables.values()):
            print(f"\n{name}: missing in " + ", ".join(l for l, t in tables.items() if t is None))
            problems += 1
            continue
        keys = set().union(*[set(t) for t in tables.values()])
        for lang, t in tables.items():
            gap = sorted(keys - set(t))
            if gap:
                print(f"\n{name} [{lang}] missing: {gap}")
                problems += len(gap)
        print(f"\n{name}: {len(keys)} keys in each language" if problems == 0 else "")

    if interpolated:
        print(f"\nSwiftUI literals with interpolation (use L() instead): {len(interpolated)}")
        for w in interpolated:
            print(f"  {w}")
        problems += len(interpolated)

    print(f"\nResult: {problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
