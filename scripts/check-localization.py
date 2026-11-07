#!/usr/bin/env python3
"""Localization sanity checks for OneClick's String Catalogs.

Verifies, for every `Localizable.xcstrings` passed on the command line (or, by
default, both catalogs of the project):

1. The catalog is valid JSON with the expected top-level shape.
2. Every key carries a translation for each language in --languages
   (default: es). Keys whose source string holds no letters at all — bare
   format specifiers such as "%@" or "%lld" — have nothing to translate and
   are reported as skipped instead of missing.
3. Every translation uses exactly the same format specifiers, in the same
   order, as the source string (the `en` value, or the key itself when the
   catalog has no explicit `en` entry).

Exit code is 0 when everything passes, 1 otherwise.

Usage:
    python3 scripts/check-localization.py
    python3 scripts/check-localization.py --languages es ja zh-Hans
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_CATALOGS = (
    "OneClick/Localizable.xcstrings",
    "FinderSyncExt/Localizable.xcstrings",
)

# %@  %1$@  %lld  %2$lld  %d  %f  %%  ...
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(?:%|@|l{0,2}[dioux]|[eEfgGcs])")


def specifiers(text: str) -> list[str]:
    """Return the format specifiers of `text`, in order of appearance."""
    return [m.group(0) for m in SPECIFIER.finditer(text)]


def source_value(key: str, entry: dict) -> str:
    """The string the translations must stay compatible with."""
    en = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    return en.get("value", key)


def translatable(source: str) -> bool:
    """False for keys that are only format specifiers or punctuation."""
    return any(char.isalpha() for char in SPECIFIER.sub("", source))


def check_catalog(path: Path, languages: list[str]) -> tuple[list[str], list[str]]:
    problems: list[str] = []
    skipped: list[str] = []
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path}: unreadable or invalid JSON ({exc})"], skipped

    if not isinstance(catalog.get("strings"), dict):
        return [f"{path}: missing top-level 'strings' object"], skipped

    for key, entry in sorted(catalog["strings"].items()):
        localizations = entry.get("localizations", {})
        source = source_value(key, entry)
        expected = specifiers(source)

        if not translatable(source):
            skipped.append(f"{path}: nothing to translate in {key!r}")
            continue

        for language in languages:
            unit = localizations.get(language, {}).get("stringUnit", {})
            value = unit.get("value")
            if value is None:
                problems.append(f"{path}: [{language}] missing translation for {key!r}")
                continue
            found = specifiers(value)
            if found != expected:
                problems.append(
                    f"{path}: [{language}] format specifiers differ for {key!r}: "
                    f"source {expected} vs translation {found}"
                )

    return problems, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", nargs="*", default=list(DEFAULT_CATALOGS))
    parser.add_argument("--languages", nargs="+", default=["es"])
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    problems: list[str] = []
    skipped: list[str] = []
    checked = 0

    for name in args.catalogs or DEFAULT_CATALOGS:
        path = Path(name)
        if not path.is_absolute():
            path = root / path
        catalog_problems, catalog_skipped = check_catalog(path, args.languages)
        problems.extend(catalog_problems)
        skipped.extend(catalog_skipped)
        checked += 1

    for entry in skipped:
        print(f"skipped: {entry}")

    if problems:
        for problem in problems:
            print(problem)
        print(f"\n{len(problems)} problem(s) in {checked} catalog(s).")
        return 1

    print(
        f"OK: {checked} catalog(s) valid, every translatable key rendered in "
        f"{', '.join(args.languages)} with matching format specifiers "
        f"({len(skipped)} key(s) skipped as non-translatable)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
