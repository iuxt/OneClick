#!/usr/bin/env python3
"""Sign a non-sandboxed host and the mandatory sandboxed Finder extension."""
import pathlib
import plistlib
import sys


def local_entitlements(source, is_host, directory="/Library/Application Support/RClickLocal"):
    entitlements = dict(source)
    entitlements.pop("com.apple.security.application-groups", None)
    if is_host:
        # Never carry old host sandbox permissions or temporary exceptions into
        # a local/release signature. The Finder extension has a separate policy.
        entitlements = {
            key: value for key, value in entitlements.items()
            if not key.startswith(("com.apple.security.app-sandbox", "com.apple.security.inherit",
                                   "com.apple.security.files.", "com.apple.security.network.",
                                   "com.apple.security.temporary-exception."))
        }
        return entitlements
    entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] = [directory + "/"]
    operations = "network-outbound"
    # home-literal is resolved by the application sandbox at launch, on the
    # recipient's machine. A literal build-time /Users/runner path cannot work.
    import json
    entitlements["com.apple.security.temporary-exception.sbpl"] = [
        f"(allow {operations} (home-literal {json.dumps(directory + '/ipc.sock')}))"
    ]
    return entitlements


if __name__ == "__main__":
    root, output = map(pathlib.Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    for name in ("OneClick", "FinderSyncExt"):
        source = plistlib.loads((root / name / f"{name}.entitlements").read_bytes())
        (output / f"{name}.entitlements").write_bytes(
            plistlib.dumps(local_entitlements(source, name == "OneClick"))
        )
