#!/bin/sh
# appimage-icon.sh — stage and finalize the transparent PNG icon for AppImage
# Usage from repo root: scripts/appimage-icon.sh stage|finalize <appdir>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_PNG="$REPO_ROOT/resources/icons/hicolor/256x256/apps/com.seance-fork.app.png"
ICON_NAME="com.seance-fork.app.png"
DEST_BASE="usr/share/icons/hicolor/256x256/apps/$ICON_NAME"
ROOT_ICON="$ICON_NAME"

# Validate arguments
if [ $# -ne 2 ]; then
  echo "Usage: $0 stage|finalize <appdir>" >&2
  exit 1
fi

OPERATION="$1"
APP_DIR="$2"

# Check source PNG exists first
if [ ! -f "$SOURCE_PNG" ]; then
  echo "Error: source PNG not found: $SOURCE_PNG" >&2
  exit 1
fi

# Check AppDir exists before trying to resolve it
if [ ! -d "$APP_DIR" ]; then
  echo "Error: AppDir not found: $APP_DIR" >&2
  exit 1
fi

# Resolve AppDir to absolute path
APP_DIR="$(cd "$APP_DIR" && pwd)"

# Create staging directory if it doesn't exist
STAGING_DIR="$APP_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$STAGING_DIR"

# Full destination path for the installed PNG
DEST_PNG="$STAGING_DIR/$ICON_NAME"

stage() {
  # Install the source PNG into the staging directory
  cp -f "$SOURCE_PNG" "$DEST_PNG"

  # Remove the SVG from installed hicolor to prevent linuxdeploy/appimaged from using it
  INSTALLED_SVG="$APP_DIR/usr/share/icons/hicolor/scalable/apps/com.seance-fork.app.svg"
  if [ -e "$INSTALLED_SVG" ] || [ -L "$INSTALLED_SVG" ]; then
    if [ -d "$INSTALLED_SVG" ]; then
      echo "Error: unexpected directory at $INSTALLED_SVG" >&2
      exit 1
    fi
    rm -f "$INSTALLED_SVG"
  fi

  # Remove obsolete root entries (SVG, base name, and .DirIcon)
  # Only remove files/symlinks, fail on directories
  for entry in "$APP_DIR/com.seance-fork.app.svg" "$APP_DIR/com.seance-fork.app" "$APP_DIR/.DirIcon"; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      if [ -d "$entry" ]; then
        echo "Error: unexpected directory at $entry" >&2
        exit 1
      fi
      rm -f "$entry"
    fi
  done

  # Remove obsolete root PNG if it exists (file or symlink, will be replaced by symlink)
  ROOT_PNG="$APP_DIR/$ROOT_ICON"
  if [ -e "$ROOT_PNG" ] || [ -L "$ROOT_PNG" ]; then
    if [ -d "$ROOT_PNG" ]; then
      echo "Error: unexpected directory at $ROOT_PNG" >&2
      exit 1
    fi
    rm -f "$ROOT_PNG"
  fi

  # Create root icon as relative symlink to installed PNG
  # Relative path from AppDir root to DEST_PNG
  REL_PATH="$(echo "$DEST_PNG" | sed "s|^$APP_DIR/||")"
  ln -s "$REL_PATH" "$APP_DIR/$ROOT_ICON"

  # Create base name symlink (without .png) so desktop file Icon=com.seance-fork.app resolves to PNG
  ln -sf "$ROOT_ICON" "$APP_DIR/com.seance-fork.app"

  # Create .DirIcon as symlink to root icon
  ln -sf "$ROOT_ICON" "$APP_DIR/.DirIcon"
}

finalize() {
  # Verify source PNG matches installed PNG
  if [ ! -f "$DEST_PNG" ]; then
    echo "Error: installed PNG not found: $DEST_PNG" >&2
    exit 1
  fi

  # Compare source and installed
  if ! cmp -s "$SOURCE_PNG" "$DEST_PNG"; then
    echo "Error: installed PNG differs from source" >&2
    echo "  Source: $SOURCE_PNG" >&2
    echo "  Installed: $DEST_PNG" >&2
    exit 1
  fi

  # Ensure SVG is removed from installed hicolor
  INSTALLED_SVG="$APP_DIR/usr/share/icons/hicolor/scalable/apps/com.seance-fork.app.svg"
  if [ -e "$INSTALLED_SVG" ] || [ -L "$INSTALLED_SVG" ]; then
    if [ -d "$INSTALLED_SVG" ]; then
      echo "Error: unexpected directory at $INSTALLED_SVG" >&2
      exit 1
    fi
    rm -f "$INSTALLED_SVG"
  fi

  # Reassert root icon symlink
  ROOT_PNG="$APP_DIR/$ROOT_ICON"
  if [ -e "$ROOT_PNG" ]; then
    if [ -d "$ROOT_PNG" ]; then
      echo "Error: unexpected directory at $ROOT_PNG" >&2
      exit 1
    fi
    rm -f "$ROOT_PNG"
  fi
  REL_PATH="$(echo "$DEST_PNG" | sed "s|^$APP_DIR/||")"
  ln -s "$REL_PATH" "$APP_DIR/$ROOT_ICON"

  # Reassert base name symlink (without .png)
  ln -sf "$ROOT_ICON" "$APP_DIR/com.seance-fork.app"

  # Reassert .DirIcon symlink
  ln -sf "$ROOT_ICON" "$APP_DIR/.DirIcon"

  # Remove root SVG and base name if they still exist
  for entry in "$APP_DIR/com.seance-fork.app.svg" "$APP_DIR/com.seance-fork.app"; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      if [ -d "$entry" ]; then
        echo "Error: unexpected directory at $entry" >&2
        exit 1
      fi
      rm -f "$entry"
    fi
  done
  
  # Recreate base name symlink after cleaning up
  ln -sf "$ROOT_ICON" "$APP_DIR/com.seance-fork.app"
}

# Run the requested operation
case "$OPERATION" in
  stage)
    stage
    ;;
  finalize)
    finalize
    ;;
  *)
    echo "Error: unknown operation '$OPERATION'. Use 'stage' or 'finalize'." >&2
    exit 1
    ;;
esac

echo "$OPERATION completed successfully for $APP_DIR"
