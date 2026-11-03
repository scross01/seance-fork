#!/usr/bin/env python3
"""Verify AppImage icon packaging: transparent PNG, correct paths, no SVG."""

import os
import sys
from pathlib import Path


def resolve_path(path: Path) -> Path:
    """Fully resolve a path, following symlinks."""
    try:
        return path.resolve()
    except (OSError, RuntimeError):
        return path


def read_desktop_icon(desktop_path: Path) -> str:
    """Read the Icon= value from a desktop file."""
    icon_line = None
    try:
        with open(desktop_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("Icon="):
                    icon_line = line
                    break
    except OSError as e:
        raise RuntimeError(f"Cannot read desktop file: {desktop_path}") from e

    if icon_line is None:
        raise RuntimeError(f"No Icon= line found in desktop file: {desktop_path}")

    # Extract the icon name
    icon = icon_line[len("Icon="):].strip()
    return icon


def verify_png_transparency(png_path: Path) -> tuple:
    """Verify PNG has transparency and visible content. Returns (has_alpha, has_transparent, has_visible)."""
    try:
        from PIL import Image
    except ImportError:
        raise RuntimeError(
            "Pillow is required for PNG verification. "
            "Install it with: pip install Pillow  or  uv pip install Pillow"
        )

    try:
        with Image.open(png_path) as img:
            # Check dimensions
            width, height = img.size
            if width != 256 or height != 256:
                return (False, False, False)

            # Check if image has alpha channel
            has_alpha = img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info)

            if not has_alpha:
                return (False, False, False)

            # Convert to RGBA for pixel checking
            if img.mode != "RGBA":
                img = img.convert("RGBA")

            # Get pixel accessor (works across Pillow versions, no deprecation)
            pixels = img.load()
            has_transparent = False
            has_visible = False

            for y in range(height):
                for x in range(width):
                    r, g, b, a = pixels[x, y]
                    if a == 0:
                        has_transparent = True
                    # Visible means: not fully transparent AND has color (R/G/B not all equal)
                    if a > 0 and not (r == g == b):
                        has_visible = True
                    # Also accept fully transparent as "has alpha" proof

            return (has_alpha, has_transparent, has_visible)

    except Exception as e:
        raise RuntimeError(f"Cannot decode PNG: {png_path}: {e}") from e


def verify_appimage_icon(appdir_path: Path, source_png: Path | None = None, require_transparency: bool = True, require_all_sizes: bool = True) -> list:
    """
    Verify AppImage icon packaging.
    
    Args:
        appdir_path: Path to the extracted AppDir or AppDir
        source_png: Optional path to the source PNG for byte comparison
        require_transparency: If True, PNG transparency verification is required
    
    Returns:
        List of error messages (empty if all checks pass)
    """
    errors = []
    appdir = Path(appdir_path).resolve()

    if not appdir.exists():
        errors.append(f"AppDir not found: {appdir}")
        return errors

    # 1. Check exactly one root desktop file
    desktop_files = list(appdir.glob("*.desktop"))
    if len(desktop_files) != 1:
        errors.append(f"Expected exactly 1 root desktop file, found {len(desktop_files)}")
        return errors

    desktop_file = desktop_files[0]

    # 2. Check Icon= value
    try:
        icon_name = read_desktop_icon(desktop_file)
        expected_icon = "com.seance-fork.app"
        if icon_name != expected_icon:
            errors.append(f"Desktop Icon= is '{icon_name}', expected '{expected_icon}'")
    except RuntimeError as e:
        errors.append(str(e))

    # 3. Check root PNG exists
    root_png = appdir / "com.seance-fork.app.png"
    if not root_png.exists():
        errors.append(f"Root PNG not found: {root_png}")
        return errors

    # 4. Check .DirIcon exists
    diricon = appdir / ".DirIcon"
    if not diricon.exists():
        errors.append(f".DirIcon not found: {diricon}")
        return errors

    # Resolve root PNG and .DirIcon
    try:
        resolved_root_png = resolve_path(root_png)
        resolved_diricon = resolve_path(diricon)
    except Exception as e:
        errors.append(f"Cannot resolve symlinks: {e}")
        return errors

    # Check that both resolve to the same file
    if resolved_root_png != resolved_diricon:
        errors.append(
            f"Root PNG and .DirIcon resolve to different files: "
            f"{resolved_root_png} vs {resolved_diricon}"
        )

    # 5. Check both resolve inside AppDir
    if not str(resolved_root_png).startswith(str(appdir)):
        errors.append(
            f"Root PNG resolves outside AppDir: {resolved_root_png}"
        )
    if not str(resolved_diricon).startswith(str(appdir)):
        errors.append(
            f".DirIcon resolves outside AppDir: {resolved_diricon}"
        )

    # 5b. Check base name symlink (without .png extension) resolves to PNG
    base_icon = appdir / "com.seance-fork.app"
    if base_icon.exists() or base_icon.is_symlink():
        try:
            resolved_base = resolve_path(base_icon)
            if resolved_base != resolved_root_png:
                errors.append(
                    f"Base icon 'com.seance-fork.app' resolves to {resolved_base}, "
                    f"expected {resolved_root_png}"
                )
        except Exception as e:
            errors.append(f"Cannot resolve base icon symlink: {e}")

    # 6. Check no obsolete SVG files (root or installed)
    for svg_path in [
        appdir / "com.seance-fork.app.svg",
        appdir / "usr/share/icons/hicolor/scalable/apps/com.seance-fork.app.svg"
    ]:
        if svg_path.exists():
            errors.append(f"Obsolete SVG found: {svg_path}")

    # 7. Check installed PNG location
    installed_png = appdir / "usr/share/icons/hicolor/256x256/apps/com.seance-fork.app.png"
    if not installed_png.exists():
        errors.append(f"Installed PNG not found: {installed_png}")
    else:
        resolved_installed = resolve_path(installed_png)
        if resolved_installed != resolved_root_png:
            errors.append(
                f"Installed PNG resolves differently from root PNG: "
                f"{resolved_installed} vs {resolved_root_png}"
            )

    # 8. Check standard icon sizes are present for crisp rendering (optional)
    if require_all_sizes:
        standard_sizes = [16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512]
        missing_sizes = []
        for size in standard_sizes:
            png_path = appdir / f"usr/share/icons/hicolor/{size}x{size}/apps/com.seance-fork.app.png"
            if not png_path.exists():
                missing_sizes.append(f"{size}x{size}")
        if missing_sizes:
            errors.append(f"Missing standard icon sizes: {', '.join(missing_sizes)}")

    # 9. Byte comparison (if source PNG provided)
    if source_png is not None:
        source_png_path = Path(source_png).resolve()
        if source_png_path.exists():
            try:
                source_bytes = source_png_path.read_bytes()
                installed_bytes = installed_png.read_bytes()
                if source_bytes != installed_bytes:
                    errors.append("Installed PNG bytes differ from source PNG")
            except Exception as e:
                errors.append(f"Cannot compare bytes: {e}")

    # 10. Verify PNG transparency (optional if Pillow not available)
    if installed_png.exists() and require_transparency:
        try:
            has_alpha, has_transparent, has_visible = verify_png_transparency(installed_png)
            if not has_alpha:
                errors.append("PNG does not have alpha channel")
            if not has_transparent:
                errors.append("PNG has no fully transparent pixels")
            if not has_visible:
                errors.append("PNG has no visible colored pixels")
        except RuntimeError as e:
            # If Pillow is missing and transparency is required, this is an error
            errors.append(str(e))

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 verify-appimage-icon.py <appdir> [source_png] [--no-transparency] [--no-sizes]", file=sys.stderr)
        sys.exit(1)

    appdir = Path(sys.argv[1])
    source_png = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    
    # Check for flags
    require_transparency = True
    require_all_sizes = True
    args = sys.argv[3:]
    if "--no-transparency" in args:
        require_transparency = False
    if "--no-sizes" in args:
        require_all_sizes = False

    errors = verify_appimage_icon(appdir, source_png, require_transparency, require_all_sizes)

    if errors:
        print("FAILED: AppImage icon verification failed:")
        for error in errors:
            print(f"  - {error}")
        sys.exit(1)
    else:
        print("PASSED: AppImage icon verification succeeded")
        sys.exit(0)


if __name__ == "__main__":
    main()
