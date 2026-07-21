#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_DIR="$(dirname "$SCRIPT_DIR")"
BRANCH="${1:?Usage: $0 <branch-name> [new-dir]}"
NEW_DIR="${2:-../$(basename "$MAIN_DIR")-$BRANCH}"

git worktree add "$NEW_DIR" "$BRANCH"

rm -rf "$NEW_DIR/ghostty"
ln -s "$MAIN_DIR/ghostty" "$NEW_DIR/ghostty"

echo "Worktree created at $NEW_DIR"
echo "Ghostty submodule shared from $MAIN_DIR/ghostty"
echo "Zig cache is shared — libghostty should not rebuild."
