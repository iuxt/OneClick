#!/usr/bin/env python3
"""Check the installed distribution boundary, including nested executables."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
for name, executable, sandboxed in [
    ("OneClick", app, False),
    ("FinderSyncExt", app / "Contents/PlugIns/FinderSyncExt.appex", True),
    ("7zz", app / "Contents/Helpers/7zz", False),
    ("pigz", app / "Contents/Helpers/pigz", False),
]:
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(executable)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    assert entitlements.get("com.apple.security.app-sandbox", False) == sandboxed, name
    if not sandboxed:
        assert not entitlements.get("com.apple.security.inherit", False), name
        assert not any(key.startswith(("com.apple.security.temporary-exception.", "com.apple.security.files."))
                       for key in entitlements), name
    print(f"PASS: {name} App Sandbox {'enabled (system-required extension)' if sandboxed else 'disabled'}")
