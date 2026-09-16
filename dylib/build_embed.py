#!/usr/bin/env python3
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Translations.plist"
OUT = Path(__file__).resolve().parent / "TranslationsData.m"


def normalize(obj):
    # Legacy ZolaCN format: source -> Chinese string.
    # New format: source -> {zh, vi, en}.
    if not isinstance(obj, dict):
        return {}
    out = {}
    for key, value in obj.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, dict):
            out[key] = {
                "zh": value.get("zh", ""),
                "vi": value.get("vi", ""),
                "en": value.get("en", ""),
            }
        elif isinstance(value, str):
            out[key] = {"zh": value, "vi": key, "en": key}
    return out


def main():
    if SOURCE.exists():
        with SOURCE.open("rb") as f:
            table = normalize(plistlib.load(f))
    else:
        table = {}
        print("Translations.plist not found; embedding an empty table")

    payload = plistlib.dumps(table, fmt=plistlib.FMT_XML, sort_keys=True)
    values = ", ".join(str(b) for b in payload)
    lines = [
        "#include <stddef.h>",
        "const unsigned char ZLCNTranslationsPlist[] = {",
        "    " + values,
        "};",
        "const unsigned long ZLCNTranslationsPlistLength = sizeof(ZLCNTranslationsPlist);",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"embedded {len(table)} translation entries / {len(payload)} bytes -> {OUT}")


if __name__ == "__main__":
    main()
