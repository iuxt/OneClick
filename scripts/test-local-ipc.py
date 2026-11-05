#!/usr/bin/env python3
"""macOS integration check for the exact local/release entitlement generator.

Uses isolated app IDs, a disposable home-relative socket directory and the
production transport. Never launches OneClick or accesses its settings/socket.
"""
import importlib.util
import pathlib
import plistlib
import pwd
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("entitlements", ROOT / "scripts/local-entitlements.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def run(*args):
    subprocess.run(args, check=True, cwd=ROOT)


def main():
    suffix = uuid.uuid4().hex[:8]
    relative = "/Library/Application Support/OneClickIPC-" + suffix
    shared = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir) / relative.lstrip("/")
    # Keep bundles under .build, so the integration check leaves no repository files.
    (ROOT / ".build").mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="sandbox-ipc-", dir=ROOT / ".build") as temporary:
            temporary = pathlib.Path(temporary)
            binary = temporary / "probe"
            run("xcrun", "swiftc", "-swift-version", "6", "-D", "RC_LOCAL_BUILD",
                "Shared/HintClickLaunch.swift", "Shared/LocalIPCTransport.swift",
                "scripts/fixtures/LocalIPCProbe.swift", "-o", str(binary))
            bundles = {}
            for role, source in [("extension", "FinderSyncExt"), ("host", "OneClick"), ("control", "OneClick")]:
                bundle = (temporary / "host.app/Contents/PlugIns/FinderSyncExt.appex"
                          if role == "extension" else temporary / f"{role}.app")
                executable = bundle / "Contents/MacOS/probe"
                executable.parent.mkdir(parents=True)
                shutil.copy2(binary, executable)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleExecutable": "probe", "CFBundleIdentifier": f"cn.oneclick.ipctest.{role}",
                    "CFBundlePackageType": "APPL", "LSUIElement": True,
                }))
                source_entitlements = plistlib.loads((ROOT / source / f"{source}.entitlements").read_bytes())
                entitlements = generator.local_entitlements(source_entitlements, role != "extension", relative)
                assert "app-sandbox" in str(entitlements) and "/Users/" not in str(entitlements)
                # Directly exec'ing an appex does not receive Finder's enclosing
                # bundle read grant. Allow only the disposable fixture bundles so
                # both endpoints can load their peer's designated requirement.
                entitlements["com.apple.security.temporary-exception.files.absolute-path.read-only"] = [str(temporary) + "/"]
                if role == "control":
                    entitlements.pop("com.apple.security.temporary-exception.sbpl")
                entitlement_file = temporary / f"{role}.plist"
                entitlement_file.write_bytes(plistlib.dumps(entitlements))
                run("codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", "-",
                    "--entitlements", str(entitlement_file), str(bundle))
                bundles[role] = (bundle, executable)

            # The old release entitlements must fail to bind; otherwise the test
            # would not distinguish a sandboxed regression from an unsandboxed run.
            result = subprocess.run([str(bundles["control"][1]), "host", str(shared),
                                     str(bundles["control"][0]), "1"], timeout=10)
            assert result.returncode == 2, f"Unexpected negative control exit: {result.returncode}"
            host = subprocess.Popen([str(bundles["host"][1]), "host", str(shared), str(bundles["extension"][0]), "10"])
            try:
                subprocess.run([str(bundles["extension"][1]), "extension", str(shared),
                                str(bundles["host"][0]), "10"], check=True, timeout=15)
                assert host.wait(timeout=15) == 0, "Sandbox host failed"
            finally:
                if host.poll() is None:
                    host.kill()
                    host.wait()
            print("PASS: denied without socket exception; signed host and extension exchange authenticated frames with it")
    finally:
        shutil.rmtree(shared, ignore_errors=True)


if __name__ == "__main__":
    main()
