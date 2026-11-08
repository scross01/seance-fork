"""Run with python3 -m unittest discover -s tests -p 'test_build_requirements.py' -v."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAKE = shutil.which("make")

# Paths that are local bookkeeping and never part of a distributable export.
EXPORT_EXCLUDES = ("plans/",)


def git_paths(*args):
    result = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed:\n{result.stdout}{result.stderr}"
        )
    return [entry for entry in result.stdout.split("\0") if entry]


def candidate_export_paths():
    """Paths that a source export built from this checkout would receive.

    Tracked files are always included. Untracked files are included only when
    Git does not ignore them, so an ignored entry point shows up as missing
    before it is staged and as a tracked file afterwards.
    """
    paths = git_paths("ls-files", "-z")
    paths += git_paths("ls-files", "-z", "--others", "--exclude-standard")
    return [
        rel for rel in dict.fromkeys(paths)
        if not any(rel == ex or rel.startswith(ex) for ex in EXPORT_EXCLUDES)
    ]


class BuildRequirementsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if MAKE is None:
            raise AssertionError("make is required to verify the build workflow")
        cls.export = cls._build_export()
        cls.home = cls.export / "home"
        (cls.home / ".local" / "bin").mkdir(parents=True, exist_ok=True)

    @classmethod
    def _build_export(cls):
        tmp = tempfile.TemporaryDirectory(prefix="seance-build-export-")
        cls.addClassCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for rel in candidate_export_paths():
            source = ROOT / rel
            if not source.is_file():
                continue
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        return root

    def _read(self, rel):
        return (ROOT / rel).read_text()

    def _make_env(self, path_zig=None, brew_zig=None, override_zig=None):
        bin_dir = Path(tempfile.mkdtemp(prefix="seance-fake-zig-"))
        self.addCleanup(shutil.rmtree, bin_dir)
        if path_zig is not None:
            self._fake_zig(bin_dir / "zig", path_zig)
        env = {k: v for k, v in os.environ.items()
               if k not in ("ZIG", "ZIG_BREW_016")}
        env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
        env["HOME"] = str(self.home)
        env["ZIG_BREW_016"] = str(brew_zig) if brew_zig else str(bin_dir / "absent-zig")
        if override_zig is not None:
            env["ZIG"] = str(override_zig)
        return env

    def _fake_zig(self, path, version):
        path.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "version" ]; then\n'
            f"  echo {version!r}\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        )
        path.chmod(0o755)
        return path

    def _path_zig(self, version):
        # A fresh directory per call keeps PATH resolution unambiguous.
        bin_dir = Path(tempfile.mkdtemp(prefix="seance-path-zig-"))
        self.addCleanup(shutil.rmtree, bin_dir)
        return self._fake_zig(bin_dir / "zig", version)

    def _make(self, args, env):
        return subprocess.run(
            [MAKE, *args], cwd=self.export, env=env,
            capture_output=True, text=True, timeout=120,
        )

    def _pin_zig(self):
        zig = Path(tempfile.mkdtemp(prefix="seance-pinned-zig-")) / "zig"
        self.addCleanup(shutil.rmtree, zig.parent)
        return self._fake_zig(zig, "0.16.0")

    def test_pkgbuild_declares_webkit(self):
        self.assertIn("webkitgtk-6.0", self._read("pkg/arch/PKGBUILD"))

    def test_package_nix_declares_webkit(self):
        self.assertIn("webkit", self._read("pkg/nix/package.nix").lower())

    def test_flake_declares_webkit(self):
        self.assertIn("webkit", self._read("flake.nix").lower())

    def test_readme_declares_webkit(self):
        self.assertIn("webkit", self._read("README.md").lower())

    def test_installation_declares_webkit(self):
        text = self._read("docs/guide/installation.md").lower()
        self.assertIn("webkit", text)

    def test_building_declares_webkit(self):
        text = self._read("docs/dev/building.md").lower()
        self.assertIn("webkit", text)

    def test_contributing_uses_installed_workflow(self):
        text = self._read("CONTRIBUTING.md")
        self.assertNotRegex(text, r"(?m)^cd seance$")
        self.assertIn("cd seance-fork", text)
        self.assertIn("make build", text)

    def test_candidate_export_ships_makefile(self):
        self.assertIn(
            "Makefile", candidate_export_paths(),
            "the documented build entry point is ignored or untracked",
        )
        self.assertTrue((self.export / "Makefile").is_file())

    def test_candidate_export_dry_run_build(self):
        result = self._make(["check-zig"], self._make_env(path_zig="0.16.0"))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        result = self._make(["-n", "build"], self._make_env(path_zig="0.16.0"))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("AppDir/usr", result.stdout)

    def test_candidate_export_run_depends_on_build(self):
        result = self._make(["-n", "run"], self._make_env(path_zig="0.16.0"))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        output = result.stdout
        build_at = output.find("-Doptimize=ReleaseSafe")
        run_at = output.find("AppDir/usr/bin/seance")
        self.assertNotEqual(-1, build_at, output)
        self.assertNotEqual(-1, run_at, output)
        self.assertLess(build_at, run_at, output)

    def test_check_zig_accepts_pinned_path_toolchain(self):
        result = self._make(["check-zig"], self._make_env(path_zig="0.16.0"))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0.16.0 OK", result.stdout)

    def test_check_zig_accepts_explicit_override(self):
        env = self._make_env(path_zig="0.17.0", override_zig=self._pin_zig())
        result = self._make(["check-zig"], env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_check_zig_falls_back_to_brew_pin(self):
        env = self._make_env(path_zig="0.17.0", brew_zig=self._pin_zig())
        result = self._make(["check-zig"], env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("0.16.0 OK", result.stdout)

    def test_check_zig_rejects_unsupported_toolchain(self):
        unsupported = self._path_zig("0.17.0")
        result = self._make(["check-zig"], self._make_env(override_zig=unsupported))
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn("0.16.0", result.stdout + result.stderr)

    def test_check_zig_rejects_unsupported_path_default(self):
        result = self._make(["check-zig"], self._make_env(path_zig="0.17.0"))
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn("not found", result.stdout + result.stderr)

    def test_check_zig_rejects_missing_toolchain(self):
        env = self._make_env(override_zig="/nonexistent/zig-0.16.0/zig")
        result = self._make(["check-zig"], env)
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn("not found", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
