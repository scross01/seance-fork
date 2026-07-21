#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$ROOT_DIR/ghostty"
PATCHES_DIR="$ROOT_DIR/patches"

# Accept optional commit/tag argument
UPSTREAM_REF="${1:-origin/main}"

echo "Updating ghostty to $UPSTREAM_REF..."

cd "$GHOSTTY_DIR"

# Fetch upstream
git fetch origin

# Stash any local changes (shouldnt be any if using this workflow)
git stash --include-untracked 2>/dev/null || true

# Reset to upstream
git checkout "$UPSTREAM_REF"
git reset --hard "$UPSTREAM_REF"

# Re-apply patches
cd "$ROOT_DIR"
bash scripts/apply-ghostty-patches.sh

# Update the submodule reference
cd "$ROOT_DIR"
git add ghostty

echo ""
echo "Ghostty updated to $(cd ghostty && git rev-parse --short HEAD)"
echo ""
echo "Next steps:"
echo "  1. Review the changes: git diff --cached"
echo "  2. Build and test: zig build -Doptimize=ReleaseSafe"
echo "  3. Commit: git commit -m 'chore: update ghostty to <version>'"
