#!/usr/bin/env python3
"""Shared version rules for local commands and GitHub Releases."""

import argparse
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "OneClick.xcodeproj/project.pbxproj"
NUMBER = r"(0|[1-9][0-9]*)"
VERSION = rf"{NUMBER}\.{NUMBER}\.{NUMBER}"
TAG = rf"v(?P<version>(?P<app_version>{VERSION})(?:-(?:alpha|beta|rc)\.{NUMBER})?)"
CONFIGURATION = re.compile(
    r"^\t\t[^\n]+ = \{\n\t\t\tisa = XCBuildConfiguration;\n.*?^\t\t\};",
    re.MULTILINE | re.DOTALL,
)
APP_PLIST = re.compile(
    r"^\s*INFOPLIST_FILE = (?:OneClick|FinderSyncExt)/Info\.plist;$", re.MULTILINE
)
MARKETING_VERSION = re.compile(r"(?m)^(\s*MARKETING_VERSION = )([^;\n]+)(;)$")


def project_version(text):
    """Locate app/extension settings without rewriting the Xcode project."""
    entries = []
    for configuration in CONFIGURATION.finditer(text):
        if not APP_PLIST.search(configuration.group()):
            continue
        matches = list(MARKETING_VERSION.finditer(configuration.group()))
        if len(matches) != 1:
            raise ValueError("Each app/extension configuration needs one MARKETING_VERSION.")
        match = matches[0]
        version = match.group(2)
        if not re.fullmatch(VERSION, version):
            raise ValueError(f"Invalid project version: {version}; expected X.Y.Z without leading zeros.")
        entries.append((configuration.start() + match.start(2),
                        configuration.start() + match.end(2), version))
    if len(entries) != 4:
        raise ValueError("Expected Debug/Release versions for OneClick and FinderSyncExt.")
    versions = {entry[2] for entry in entries}
    if len(versions) != 1:
        raise ValueError("OneClick and FinderSyncExt Debug/Release versions must match.")
    return entries[0][2], entries


def release_outputs(tag, current):
    match = re.fullmatch(TAG, tag)
    if not match:
        raise ValueError("Expected vX.Y.Z or vX.Y.Z-{alpha,beta,rc}.N without leading zeros.")
    if match["app_version"] != current:
        raise ValueError(
            f"Tag version {match['app_version']} does not match project version {current}. "
            "Bump and commit the project version before tagging."
        )
    return (
        f"version={match['version']}\n"
        f"app_version={current}\n"
        f"prerelease={str('-' in match['version']).lower()}\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=(
        "version", "bump-version", "bump-minor", "bump-major", "release",
    ))
    parser.add_argument("tag", nargs="?", help="Release tag (release command only)")
    args = parser.parse_args()
    if (args.command == "release") != (args.tag is not None):
        parser.error("Only release requires a tag argument.")

    try:
        text = PROJECT.read_text()
        current, entries = project_version(text)
        if args.command == "version":
            print(current)
        elif args.command == "release":
            print(release_outputs(args.tag, current), end="")
        else:
            parts = list(map(int, current.split(".")))
            index = {"bump-major": 0, "bump-minor": 1, "bump-version": 2}[args.command]
            parts[index] += 1
            parts[index + 1:] = [0] * (2 - index)
            version = ".".join(map(str, parts))
            for start, end, _ in reversed(entries):
                text = text[:start] + version + text[end:]
            PROJECT.write_text(text)
            print(version)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Version error: {error}\n")


if __name__ == "__main__":
    main()
