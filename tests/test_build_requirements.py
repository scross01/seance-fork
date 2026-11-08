"""Run with python3 -m unittest discover -s tests -p 'test_build_requirements.py' -v."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildRequirementsTests(unittest.TestCase):
    def _read(self, rel):
        return (ROOT / rel).read_text()

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


if __name__ == "__main__":
    unittest.main()