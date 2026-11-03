"""Tests for AppImage icon packaging (plan 085)."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

# Path to the helper script, relative to tests directory
HELPER_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "appimage-icon.sh"
VERIFIER_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-appimage-icon.py"
SOURCE_PNG = Path(__file__).resolve().parents[1] / "resources" / "icons" / "hicolor" / "256x256" / "apps" / "com.seance-fork.app.png"
DESKTOP_FILE = Path(__file__).resolve().parents[1] / "resources" / "com.seance-fork.app.desktop"


def create_test_png(path: Path, width: int = 256, height: int = 256, transparent: bool = True, colored: bool = True):
    """Create a test PNG using Pillow."""
    try:
        from PIL import Image
    except ImportError:
        # Skip test if Pillow not available
        raise unittest.SkipTest("Pillow not installed")
    
    # Create transparent image
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = img.load()
    
    if transparent:
        # Make top-left corner fully transparent
        pixels[0, 0] = (0, 0, 0, 0)
    
    if colored:
        # Make a colored pixel in the center
        center = width // 2, height // 2
        pixels[center] = (255, 0, 0, 255)  # Red, fully opaque
    else:
        # Grey pixel
        center = width // 2, height // 2
        pixels[center] = (128, 128, 128, 255)
    
    img.save(str(path))


def run_helper(appdir: Path, operation: str) -> tuple:
    """Run the helper script and return (returncode, stdout, stderr)."""
    cmd = [str(HELPER_SCRIPT), operation, str(appdir)]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30
    )
    return (result.returncode, result.stdout, result.stderr)


def run_verifier(appdir: Path, source_png: Path | None = None, require_transparency: bool = False, require_all_sizes: bool = False) -> tuple:
    """Run the verifier script and return (returncode, stdout, stderr)."""
    cmd = ["python3", str(VERIFIER_SCRIPT), str(appdir)]
    if source_png:
        cmd.append(str(source_png))
    if not require_transparency:
        cmd.append("--no-transparency")
    if not require_all_sizes:
        cmd.append("--no-sizes")
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30
    )
    return (result.returncode, result.stdout, result.stderr)


class TestAppImageIconHelper(unittest.TestCase):
    """Test the appimage-icon.sh helper script."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.appdir = Path(self.temp_dir) / "AppDir"
        self.appdir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_stage_creates_structure(self):
        """Test that stage operation creates the expected directory structure."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")
        
        # Check installed PNG
        installed_png = self.appdir / "usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png"
        self.assertTrue(installed_png.exists(), f"Installed PNG not found: {installed_png}")
        
        # Check root icon symlink
        root_icon = self.appdir / "com.seance-fork.app.png"
        self.assertTrue(root_icon.exists(), "Root icon not found")
        self.assertTrue(root_icon.is_symlink(), "Root icon is not a symlink")
        
        # Check .DirIcon symlink
        diricon = self.appdir / ".DirIcon"
        self.assertTrue(diricon.exists(), ".DirIcon not found")
        self.assertTrue(diricon.is_symlink(), ".DirIcon is not a symlink")

    def test_stage_removes_root_svg(self):
        """Test that stage removes an existing root SVG."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # Create a fake root SVG
        root_svg = self.appdir / "com.seance-fork.app.svg"
        root_svg.write_text("<svg>test</svg>")
        
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")
        
        self.assertFalse(root_svg.exists(), "Root SVG was not removed")

    def test_stage_removes_old_diricon(self):
        """Test that stage removes an existing .DirIcon."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # Create a fake .DirIcon
        diricon = self.appdir / ".DirIcon"
        diricon.write_text("old")
        
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")
        
        # .DirIcon should now be a symlink
        self.assertTrue(diricon.exists())
        self.assertTrue(diricon.is_symlink())

    def test_stage_fails_on_directory(self):
        """Test that stage fails if there's an unexpected directory."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # Create a directory at the root icon location
        root_icon_dir = self.appdir / "com.seance-fork.app.png"
        root_icon_dir.mkdir()
        
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertNotEqual(returncode, 0, "Helper should have failed on directory")
        self.assertIn("unexpected directory", stderr.lower())

    def test_stage_fails_on_missing_appdir(self):
        """Test that stage fails if AppDir doesn't exist."""
        non_existent = Path(self.temp_dir) / "NonExistent"
        returncode, stdout, stderr = run_helper(non_existent, "stage")
        self.assertNotEqual(returncode, 0, "Helper should have failed on missing AppDir")
        self.assertIn("not found", stderr.lower())

    def test_finalize_verifies_bytes(self):
        """Test that finalize verifies PNG bytes match source."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # First stage
        run_helper(self.appdir, "stage")
        
        # Then finalize
        returncode, stdout, stderr = run_helper(self.appdir, "finalize")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")

    def test_finalize_removes_root_svg(self):
        """Test that finalize removes root SVG."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # Stage first
        run_helper(self.appdir, "stage")
        
        # Add a root SVG
        root_svg = self.appdir / "com.seance-fork.app.svg"
        root_svg.write_text("<svg>test</svg>")
        
        # Finalize should remove it
        returncode, stdout, stderr = run_helper(self.appdir, "finalize")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")
        self.assertFalse(root_svg.exists(), "Root SVG was not removed by finalize")

    def test_idempotent_stage(self):
        """Test that calling stage multiple times is idempotent."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # First stage
        run_helper(self.appdir, "stage")
        installed_png = self.appdir / "usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png"
        first_content = installed_png.read_bytes()
        
        # Second stage
        run_helper(self.appdir, "stage")
        second_content = installed_png.read_bytes()
        
        # Content should be identical after second stage
        self.assertEqual(first_content, second_content, "Stage is not idempotent - content changed")

    def test_old_svg_linked_appdir_cleanup(self):
        """Test that stage cleans up old SVG-linked AppDir."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        
        # Create old structure with SVG
        old_png = self.appdir / "com.seance-fork.app.png"
        old_svg = self.appdir / "com.seance-fork.app.svg"
        old_svg.write_text("<svg>old</svg>")
        
        # Create symlink from PNG to SVG (old broken state)
        old_png.symlink_to(old_svg)
        
        # Stage should clean this up
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertEqual(returncode, 0, f"Helper failed: {stderr}")
        
        # Old SVG should be removed
        self.assertFalse(old_svg.exists(), "Old SVG was not removed")
        
        # New PNG should be a file or proper symlink
        self.assertTrue(old_png.exists())
        self.assertTrue(old_png.is_symlink())


class TestAppImageIconVerifier(unittest.TestCase):
    """Test the verify-appimage-icon.py script."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.appdir = Path(self.temp_dir) / "AppDir"
        self.appdir.mkdir()
        # Check if Pillow is available
        try:
            from PIL import Image
            self.has_pillow = True
        except ImportError:
            self.has_pillow = False

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_verifier_valid_structure(self):
        """Test verifier passes on valid icon structure."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        if not self.has_pillow:
            self.skipTest("Pillow not installed")
        
        # Create valid structure manually
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        shutil.copy(SOURCE_PNG, installed_png)
        
        # Create root symlink
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        # Create .DirIcon
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("com.seance-fork.app.png")
        
        # Create desktop file
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir, SOURCE_PNG, require_transparency=True)
        self.assertEqual(returncode, 0, f"Verifier failed: {stdout}\n{stderr}")

    def test_verifier_missing_desktop(self):
        """Test verifier fails when desktop file is missing."""
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on missing desktop")

    def test_verifier_wrong_icon_name(self):
        """Test verifier fails when desktop Icon= is wrong."""
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=wrong-icon\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on wrong icon name")

    def test_verifier_missing_root_png(self):
        """Test verifier fails when root PNG is missing."""
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on missing root PNG")

    def test_verifier_missing_diricon(self):
        """Test verifier fails when .DirIcon is missing."""
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.write_bytes(b"fake png")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on missing .DirIcon")

    def test_verifier_obsolete_svg(self):
        """Test verifier fails when root SVG exists."""
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        installed_png.write_bytes(b"fake png")
        
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("com.seance-fork.app.png")
        
        # Add obsolete SVG
        root_svg = self.appdir / "com.seance-fork.app.svg"
        root_svg.write_text("<svg>obsolete</svg>")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on obsolete SVG")

    def test_verifier_dangling_diricon(self):
        """Test verifier fails when .DirIcon is dangling."""
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        installed_png.write_bytes(b"fake png")
        
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        # Create dangling .DirIcon
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("nonexistent.png")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        # A dangling .DirIcon does not resolve to the real icon, so the
        # verifier must report it as missing.
        self.assertNotEqual(returncode, 0, "Verifier should have failed on dangling .DirIcon")
        self.assertIn(".DirIcon not found", stdout + stderr)


class TestIntegration(unittest.TestCase):
    """Integration tests for the complete workflow."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.appdir = Path(self.temp_dir) / "AppDir"
        self.appdir.mkdir()
        # Check if Pillow is available
        try:
            from PIL import Image
            self.has_pillow = True
        except ImportError:
            self.has_pillow = False

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_stage_then_verify(self):
        """Test stage operation followed by verification."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        if not self.has_pillow:
            self.skipTest("Pillow not installed")
        
        # Create desktop file
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        # Run stage
        returncode, stdout, stderr = run_helper(self.appdir, "stage")
        self.assertEqual(returncode, 0, f"Stage failed: {stderr}")
        
        # Run verifier
        returncode, stdout, stderr = run_verifier(self.appdir, SOURCE_PNG, require_transparency=True)
        self.assertEqual(returncode, 0, f"Verifier failed: {stdout}\n{stderr}")

    def test_stage_finalize_then_verify(self):
        """Test stage + finalize followed by verification."""
        if not SOURCE_PNG.exists():
            self.skipTest(f"Source PNG not found: {SOURCE_PNG}")
        if not self.has_pillow:
            self.skipTest("Pillow not installed")
        
        # Create desktop file
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        # Run stage
        run_helper(self.appdir, "stage")
        
        # Add a root SVG to test finalize cleanup
        root_svg = self.appdir / "com.seance-fork.app.svg"
        root_svg.write_text("<svg>test</svg>")
        
        # Run finalize
        returncode, stdout, stderr = run_helper(self.appdir, "finalize")
        self.assertEqual(returncode, 0, f"Finalize failed: {stderr}")
        
        # Verify SVG was removed
        self.assertFalse(root_svg.exists(), "SVG was not removed by finalize")
        
        # Run verifier
        returncode, stdout, stderr = run_verifier(self.appdir, SOURCE_PNG, require_transparency=True)
        self.assertEqual(returncode, 0, f"Verifier failed: {stdout}\n{stderr}")


class TestPNGTransparency(unittest.TestCase):
    """Test PNG transparency verification."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.appdir = Path(self.temp_dir) / "AppDir"
        self.appdir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_transparent_colored_png(self):
        """Test that transparent colored PNG passes verification."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        
        # Create installed PNG
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        create_test_png(installed_png, transparent=True, colored=True)
        
        # Create root symlink
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        # Create base name symlink
        base_icon = self.appdir / "com.seance-fork.app"
        base_icon.symlink_to("com.seance-fork.app.png")
        
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("com.seance-fork.app.png")
        
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertEqual(returncode, 0, f"Verifier failed on transparent colored PNG: {stdout}\n{stderr}")

    def test_opaque_png_fails(self):
        """Test that opaque PNG fails transparency check."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        
        # Create installed opaque PNG (no alpha channel)
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        img = Image.new("RGB", (256, 256), (255, 0, 0))
        img.save(str(installed_png))
        
        # Create root symlink
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        # Create base name symlink
        base_icon = self.appdir / "com.seance-fork.app"
        base_icon.symlink_to("com.seance-fork.app.png")
        
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("com.seance-fork.app.png")
        
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        self.assertNotEqual(returncode, 0, "Verifier should have failed on opaque PNG")

    def test_greyscale_png_fails(self):
        """Test that greyscale PNG fails the colored pixel check."""
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        
        # Create installed greyscale transparent PNG (R=G=B)
        installed_dir = self.appdir / "usr/share/icons/hicolor/256x256/apps"
        installed_dir.mkdir(parents=True)
        installed_png = installed_dir / "com.seance-fork.app.png"
        create_test_png(installed_png, transparent=True, colored=False)
        
        # Create root symlink
        root_png = self.appdir / "com.seance-fork.app.png"
        root_png.symlink_to("usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png")
        
        # Create base name symlink
        base_icon = self.appdir / "com.seance-fork.app"
        base_icon.symlink_to("com.seance-fork.app.png")
        
        diricon = self.appdir / ".DirIcon"
        diricon.symlink_to("com.seance-fork.app.png")
        
        desktop = self.appdir / "com.seance-fork.app.desktop"
        desktop.write_text("[Desktop Entry]\nIcon=com.seance-fork.app\n")
        
        returncode, stdout, stderr = run_verifier(self.appdir)
        # Should fail on no visible colored pixels
        self.assertNotEqual(returncode, 0, "Verifier should have failed on greyscale PNG")


if __name__ == "__main__":
    unittest.main()
