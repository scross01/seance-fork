"""Run with python3 -m unittest discover -s tests -v.

Every release-version location must agree with build.zig.zon. These tests
re-derive the assertions from the canonical file with their own regexes rather
than trusting scripts/bump-version.sh, then also run the script's --check and a
forced-drift scenario, so a bug in one verifier cannot hide drift from the other.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ZON = ROOT / "build.zig.zon"
SCRIPT = ROOT / "scripts" / "bump-version.sh"

# Every hand-maintained copy of the release version, besides build.zig.zon.
VERSION_FILES = (
    "src/app.zig",
    "pkg/arch/PKGBUILD",
    "pkg/arch/.SRCINFO",
    "resources/com.seance-fork.app.metainfo.xml",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    "CHANGELOG.md",
)


class VersionSyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        match = re.search(r'\.version = "([^"]+)"', ZON.read_text())
        cls.assertIsNotNone(match, "build.zig.zon has no .version entry")
        cls.version = match.group(1)

    def scratch_tree(self, mutations=None):
        """Copy the script plus every version file into a temporary repo layout.

        mutations maps a path from VERSION_FILES to a callable that rewrites the
        copy, so --check can be exercised against a tree nobody can damage.
        """
        tmp = tempfile.TemporaryDirectory(prefix="seance-version-sync-")
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for rel in ("build.zig.zon", *VERSION_FILES):
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, target)
            if mutations and rel in mutations:
                target.write_text(mutations[rel](target.read_text()))
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPT, scripts / "bump-version.sh")
        return root

    def check_script(self, root=None):
        script = (root / "scripts" / "bump-version.sh") if root else SCRIPT
        return subprocess.run(
            ["bash", str(script), "--check"],
            env={**os.environ, "SEANCE_BUMP_ROOT": str(root or ROOT)},
            capture_output=True, text=True, timeout=30,
        )

    def test_zon_version_is_semver(self):
        self.assertRegex(self.version, r"^\d+\.\d+\.\d+$")

    def test_about_dialog_version(self):
        found = re.search(
            r'adw_about_dialog_set_version\(d, "([^"]*)"\);',
            (ROOT / "src/app.zig").read_text(),
        )
        if found is None:
            self.skipTest("the About dialog version is injected via build_options")
        self.assertEqual(found.group(1), self.version)

    def test_pkgbuild_pkgver(self):
        lines = (ROOT / "pkg/arch/PKGBUILD").read_text().splitlines()
        self.assertIn(f"pkgver={self.version}", lines)

    def test_srcinfo_pkgver(self):
        lines = (ROOT / "pkg/arch/.SRCINFO").read_text().splitlines()
        self.assertIn(f"\tpkgver = {self.version}", lines)

    def test_srcinfo_source_url(self):
        expected = (
            f"\tsource = seance-fork-{self.version}-src.tar.gz::"
            "https://github.com/scross01/seance-fork/releases/download/"
            f"v{self.version}/seance-fork-{self.version}-src.tar.gz"
        )
        lines = (ROOT / "pkg/arch/.SRCINFO").read_text().splitlines()
        self.assertIn(expected, lines)

    def newest_release_entry(self):
        in_releases = False
        for line in (ROOT / "resources/com.seance-fork.app.metainfo.xml").read_text().splitlines():
            if not in_releases:
                in_releases = "<releases>" in line
            elif "release version=" in line:
                return line
        self.fail("metainfo.xml has no <release> entry after <releases>")

    def test_metainfo_newest_release(self):
        self.assertIn(
            f'version="{self.version}"', self.newest_release_entry(),
            "the newest <release> entry is not the current version",
        )

    def test_bug_report_placeholder(self):
        template = (ROOT / ".github/ISSUE_TEMPLATE/bug_report.yml").read_text()
        self.assertIn(f'placeholder: "{self.version}"', template)

    def first_section_after_unreleased(self):
        lines = (ROOT / "CHANGELOG.md").read_text().splitlines()
        start = lines.index("## [Unreleased]") + 1
        sections = [line for line in lines[start:] if line.startswith("## [")]
        self.assertTrue(sections, "no versioned section follows ## [Unreleased]")
        return sections[0]

    def test_changelog_section(self):
        self.assertEqual(f"## [{self.version}]", self.first_section_after_unreleased())

    def test_bump_script_check_passes(self):
        result = self.check_script()
        self.assertEqual(0, result.returncode, f"--check failed:\n{result.stdout}{result.stderr}")

    def test_bump_script_detects_drift(self):
        off_version = "9.8.7"
        v = self.version
        mutations = {
            "src/app.zig": lambda text: text.replace(
                f'adw_about_dialog_set_version(d, "{v}");',
                f'adw_about_dialog_set_version(d, "{off_version}");', 1),
            "pkg/arch/PKGBUILD": lambda text: text.replace(
                f"pkgver={v}", f"pkgver={off_version}", 1),
            "pkg/arch/.SRCINFO": lambda text: text.replace(
                f"\tpkgver = {v}", f"\tpkgver = {off_version}", 1),
            "resources/com.seance-fork.app.metainfo.xml": lambda text: text.replace(
                f'version="{v}"', f'version="{off_version}"', 1),
            ".github/ISSUE_TEMPLATE/bug_report.yml": lambda text: text.replace(
                f'placeholder: "{v}"', f'placeholder: "{off_version}"', 1),
            "CHANGELOG.md": lambda text: text.replace(
                f"## [{v}]", f"## [{off_version}]", 1),
        }
        for rel, mutate in mutations.items():
            with self.subTest(location=rel):
                result = self.check_script(self.scratch_tree({rel: mutate}))
                self.assertEqual(
                    1, result.returncode,
                    f"--check passed even though {rel} was off-version",
                )
                self.assertIn(rel, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
