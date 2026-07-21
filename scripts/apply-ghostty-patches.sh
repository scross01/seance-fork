#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$ROOT_DIR/ghostty"
PATCHES_DIR="$ROOT_DIR/patches"

echo "Applying seance patches to ghostty..."

cd "$GHOSTTY_DIR"

# Check if patches are already applied
if git log --oneline -1 | grep -q "seance-patches"; then
    echo "Patches already applied. Skipping."
    exit 0
fi

# Apply patches in order
for patch in "$PATCHES_DIR"/*.patch; do
    echo "Applying: $(basename "$patch")"
    git apply --check "$patch" || {
        echo "ERROR: Patch does not apply cleanly: $patch"
        echo "This may indicate upstream changes that conflict with the patch."
        echo "Please review and update the patch manually."
        exit 1
    }
    git apply "$patch"
done

echo "All patches applied successfully."
