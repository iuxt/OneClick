#!/usr/bin/env python3
"""Exercise version commands in an isolated project copy."""

from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class VersionCommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "OneClick.xcodeproj").mkdir()
        for name in ("scripts/version.py", "build.sh", "OneClick.xcodeproj/project.pbxproj"):
            shutil.copy2(ROOT / name, self.root / name)
        self.project = self.root / "OneClick.xcodeproj/project.pbxproj"
        text = self.project.read_text()
        # Use a fixed fixture version independent of future repository bumps.
        module = runpy.run_path(str(self.root / "scripts/version.py"))
        _, entries = module["project_version"](text)
        for start, end, _ in reversed(entries):
            text = text[:start] + "2.3.9" + text[end:]
        self.project.write_text(text)
        self.original = text

    def command(self, *args):
        return subprocess.run(
            ["bash", str(self.root / "build.sh"), *args],
            cwd="/", capture_output=True, text=True,
        )

    def release(self, tag):
        return subprocess.run(
            [sys.executable, str(self.root / "scripts/version.py"), "release", tag],
            cwd="/", capture_output=True, text=True,
        )

    def test_version_is_read_only(self):
        result = self.command("version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "2.3.9\n")
        self.assertEqual(self.project.read_text(), self.original)

    def test_bumps_only_app_and_extension_versions(self):
        for command, expected in (
            ("bump-version", "2.3.10"),
            ("bump-minor", "2.4.0"),
            ("bump-major", "3.0.0"),
        ):
            with self.subTest(command=command):
                self.project.write_text(self.original)
                result = self.command(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected + "\n")
                self.assertEqual(
                    self.project.read_text(),
                    self.original.replace("MARKETING_VERSION = 2.3.9;",
                                          f"MARKETING_VERSION = {expected};"),
                )
                self.assertEqual(self.command("version").stdout, expected + "\n")

    def test_invalid_project_does_not_write(self):
        for replacement, count in (("2.4.0", 1), ("02.3.9", 4), ("2.3", 4)):
            with self.subTest(replacement=replacement):
                invalid = self.original.replace("MARKETING_VERSION = 2.3.9;",
                                                f"MARKETING_VERSION = {replacement};", count)
                self.project.write_text(invalid)
                result = self.command("bump-version")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.project.read_text(), invalid)

    def test_release_outputs(self):
        for suffix in ("", "-alpha.0", "-beta.2", "-rc.1"):
            with self.subTest(suffix=suffix):
                result = self.release("v2.3.9" + suffix)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout,
                                 f"version=2.3.9{suffix}\napp_version=2.3.9\n"
                                 f"prerelease={str(bool(suffix)).lower()}\n")
        self.assertEqual(self.project.read_text(), self.original)

    def test_invalid_release_tags(self):
        for tag in ("v2.3.10", "v2.3.10-rc.1", "2.3.9", "v02.3.9", "v2.03.9",
                    "v2.3.09", "v2.3.9-rc.01", "v2.3.9-preview.1", "v2.3.9+build.1",
                    "v2.3.9\n"):
            with self.subTest(tag=tag):
                result = self.release(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_invalid_command_arguments(self):
        for args in (("bump-patch",), ("version", "extra"), ("bump-major", "extra")):
            with self.subTest(args=args):
                self.assertNotEqual(self.command(*args).returncode, 0)
                self.assertEqual(self.project.read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
