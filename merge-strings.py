#!/usr/bin/env python3
"""Backfill the port's own Chinese strings into a built app's Localizable.strings.

Why this exists
---------------
The port reuses the release's already-compiled `Localizable.strings` (Assets.car and the string
tables cannot be rebuilt without Xcode's actool/xcstringstool). Any key the port adds on top of
upstream would therefore fall back to its English source text inside an otherwise Chinese UI.

What it does
------------
Adds only the keys the bundle is missing. Existing translations are never rewritten, so a mistake
in `port-localizations.json` can degrade at most the handful of strings the port owns — it cannot
regress the rest of the interface.

Usage
-----
    merge-strings.py --bundle-strings <app>/Contents/Resources/zh-Hans.lproj/Localizable.strings
    merge-strings.py --bundle-strings <path> --check     # 只报告差异，不写入
"""

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_SOURCE = HERE / "port-localizations.json"


def read_strings(path: Path) -> dict:
    """Read a .strings table whether it is binary, UTF-8, or the UTF-16 the release ships.

    That last one is the awkward case: the file carries a BOM and UTF-16 bytes but declares
    `encoding="UTF-8"`, and Expat trusts the declaration and rejects the file. Decoding the bytes
    here and dropping the declaration before handing them over sidesteps the contradiction.
    """
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
    elif raw[:3] == b"\xef\xbb\xbf":
        text = raw.decode("utf-8-sig")
    else:
        return plistlib.loads(raw)
    # fmt 必须显式给出：plistlib 靠开头的 `<?xml` 认格式，而这个声明正是要丢掉的那部分。
    return plistlib.loads(re.sub(r"^\s*<\?xml[^>]*\?>", "", text, count=1).encode("utf-8"),
                          fmt=plistlib.FMT_XML)


def format_arguments(value: str) -> list:
    """The `%` directives in a format string, in order — the same shape L10n validates.

    Only the directives matter here: a translation whose directives do not match its source is
    discarded by L10n at runtime, which would leave the string in English with no other symptom.
    """
    arguments, index = [], 0
    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        index += 1
        if index < len(value) and value[index] == "%":
            index += 1
            continue
        start = index
        while index < len(value) and value[index].isdigit():
            index += 1
        if index < len(value) and value[index] == "$":
            index += 1
        while index < len(value) and value[index] in "-+0#":
            index += 1
        while index < len(value) and value[index].isdigit():
            index += 1
        if index < len(value) and value[index] == ".":
            index += 1
            while index < len(value) and value[index].isdigit():
                index += 1
        if index < len(value) and value[index] in "hlqLztj":
            index += 1
            if index < len(value) and value[index] == value[index - 1]:
                index += 1
        if index >= len(value):
            break
        arguments.append(value[start:index + 1])
        index += 1
    return arguments


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-strings", required=True,
                        help="the built app's zh-Hans Localizable.strings")
    parser.add_argument("--source", default=str(DEFAULT_SOURCE),
                        help="port-localizations.json (default: next to this script)")
    parser.add_argument("--check", action="store_true", help="report only; write nothing")
    args = parser.parse_args()

    target = Path(args.bundle_strings)
    source = Path(args.source)
    if not source.is_file():
        print(f"✗ 找不到译文文件 {source}", file=sys.stderr)
        return 1
    if not target.is_file():
        print(f"✗ 找不到包内字符串表 {target}", file=sys.stderr)
        return 1

    translations = {k: v for k, v in json.loads(source.read_text(encoding="utf-8")).items()
                    if not k.startswith("_")}
    strings = read_strings(target)

    # Keys the port actually references. A mismatch here is a typo in one of the two files, and it
    # would otherwise surface as a stray English label at runtime rather than as a build error.
    unmatched = {k: v for k, v in translations.items() if format_arguments(k) != format_arguments(v)
                 and format_arguments(k) != []}
    for key, value in sorted(unmatched.items()):
        print(f"✗ 占位符不匹配，该译文会被 L10n 丢弃：\n    {key!r}\n    {value!r}", file=sys.stderr)

    missing = [k for k in translations if k not in strings]
    present = len(translations) - len(missing)
    print(f"· 移植层译文 {len(translations)} 条：包内已有 {present} 条，待补 {len(missing)} 条")
    for key in missing:
        print(f"    + {key}")
    if unmatched:
        return 1
    if not missing:
        return 0
    if args.check:
        return 0

    for key in missing:
        strings[key] = translations[key]
    # Rewritten as UTF-8 XML with a declaration that matches its bytes — the release's own file is
    # the opposite, and CoreFoundation tolerates that only because it never asks the XML parser.
    target.write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_XML))
    print(f"✓ 已补入 {len(missing)} 条中文译文（{target.name} 现共 {len(strings)} 键）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
