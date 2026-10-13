#!/usr/bin/env bash
# Keep every release-version location in sync with build.zig.zon.
#
#   --check                            verify only, touch nothing (exit 1 lists drift)
#   --dry-run X.Y.Z --notes '<p>'      show the edits as diffs, touch nothing
#   X.Y.Z --notes '<p>' [--date D] [--no-git]
#                                      edit, verify, stage, commit and tag
#
# build.zig.zon:3 is the only canonical version; every other location is a
# hand-maintained copy. This script is the only writer and the only verifier,
# so a release bump is one command plus a push.
set -euo pipefail

ROOT="${SEANCE_BUMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DRY_RUN_TMP=""

FILES=(
  build.zig.zon
  src/app.zig
  pkg/arch/PKGBUILD
  pkg/arch/.SRCINFO
  resources/com.seance-fork.app.metainfo.xml
  .github/ISSUE_TEMPLATE/bug_report.yml
  CHANGELOG.md
)

usage() {
  cat <<'EOF'
usage: bump-version.sh --check
       bump-version.sh --dry-run X.Y.Z --notes '<paragraph>'
       bump-version.sh X.Y.Z --notes '<paragraph>' [--date YYYY-MM-DD] [--no-git]

build.zig.zon holds the canonical version; this script syncs every other
release-version location to it. Apply mode refuses (exit 2, nothing written)
unless the new version is a strictly greater semver, --notes is a non-empty
paragraph, the git worktree is clean (tracked files), and no vX.Y.Z tag exists.
EOF
}

refuse() {
  echo "refusing: $*" >&2
  exit 2
}

preflight() {
  local rel
  for rel in "${FILES[@]}"; do
    if [[ ! -f "$ROOT/$rel" ]]; then
      refuse "$ROOT/$rel is missing"
    fi
  done
  if ! canonical_version > /dev/null; then
    refuse "cannot read .version from $ROOT/build.zig.zon"
  fi
}

canonical_version() {
  grep -oP '(?<=\.version = ")[^"]+' "$ROOT/build.zig.zon"
}

# 0.5.1 -> 0\.5\.1 for use as a sed BRE pattern.
sed_pattern() {
  printf '%s' "${1//./\\.}"
}

# Exactly one matching line, or the whole invocation is unsafe to run.
assert_unique() {
  local file="$1" pattern="$2" count
  count="$(grep -cE -- "$pattern" "$file" || true)"
  if [[ "$count" != "1" ]]; then
    refuse "${file#"$ROOT"/} does not contain exactly one match for /$pattern/ (found ${count:-0})"
  fi
}

check_about_dialog() {
  local v="$1"
  if grep -q 'adw_about_dialog_set_version(d, "' "$ROOT/src/app.zig"; then
    if grep -qF "adw_about_dialog_set_version(d, \"$v\");" "$ROOT/src/app.zig"; then
      echo "OK  src/app.zig"
    else
      echo "DRIFT src/app.zig: About dialog literal is not \"$v\""
      return 1
    fi
  else
    # Phase 2 shape: the version comes from build_options, no literal to drift.
    echo "OK  src/app.zig (version injected via build_options)"
  fi
}

check_pkgbuild() {
  local v="$1"
  if grep -qxF "pkgver=$v" "$ROOT/pkg/arch/PKGBUILD"; then
    echo "OK  pkg/arch/PKGBUILD"
  else
    echo "DRIFT pkg/arch/PKGBUILD: no pkgver=$v line"
    return 1
  fi
}

check_srcinfo() {
  local v="$1" source_line
  source_line="$(printf '\tsource = seance-fork-%s-src.tar.gz::https://github.com/scross01/seance-fork/releases/download/v%s/seance-fork-%s-src.tar.gz' "$v" "$v" "$v")"
  if grep -qxF "	pkgver = $v" "$ROOT/pkg/arch/.SRCINFO" \
    && grep -qxF "$source_line" "$ROOT/pkg/arch/.SRCINFO"; then
    echo "OK  pkg/arch/.SRCINFO"
  else
    echo "DRIFT pkg/arch/.SRCINFO: pkgver or source line is not $v"
    return 1
  fi
}

first_metainfo_release() {
  awk '/<releases>/{seen=1; next} seen && /release version=/{print; exit}' \
    "$ROOT/resources/com.seance-fork.app.metainfo.xml"
}

check_metainfo() {
  local v="$1" line
  line="$(first_metainfo_release)"
  if [[ -z "$line" ]]; then
    echo "DRIFT resources/com.seance-fork.app.metainfo.xml: no <release> entry after <releases>"
    return 1
  fi
  if printf '%s\n' "$line" | grep -qE "^[[:space:]]*<release version=\"$v\" date=\"[^\"]*\">[[:space:]]*$"; then
    echo "OK  resources/com.seance-fork.app.metainfo.xml"
  else
    echo "DRIFT resources/com.seance-fork.app.metainfo.xml: newest release is not $v"
    return 1
  fi
}

check_bug_report() {
  local v="$1"
  if grep -qF "placeholder: \"$v\"" "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"; then
    echo "OK  .github/ISSUE_TEMPLATE/bug_report.yml"
  else
    echo "DRIFT .github/ISSUE_TEMPLATE/bug_report.yml: placeholder is not \"$v\""
    return 1
  fi
}

first_version_heading_after_unreleased() {
  awk '/^## \[/ {
    if (!unreleased) { if ($0 == "## [Unreleased]") unreleased = 1; next }
    print
    exit
  }' "$ROOT/CHANGELOG.md"
}

check_changelog() {
  local v="$1" heading
  heading="$(first_version_heading_after_unreleased)"
  if [[ "$heading" == "## [$v]" ]]; then
    echo "OK  CHANGELOG.md"
  else
    echo "DRIFT CHANGELOG.md: first section after ## [Unreleased] is not ## [$v]"
    return 1
  fi
}

check_all() {
  local v failures=0
  v="$(canonical_version)"
  check_about_dialog "$v" || failures=1
  check_pkgbuild "$v" || failures=1
  check_srcinfo "$v" || failures=1
  check_metainfo "$v" || failures=1
  check_bug_report "$v" || failures=1
  check_changelog "$v" || failures=1
  return "$failures"
}

guard_edits() {
  local old="$1" old_re
  old_re="$(sed_pattern "$old")"
  assert_unique "$ROOT/build.zig.zon" "^[[:space:]]*\.version = \"$old_re\",$"
  if grep -qF 'adw_about_dialog_set_version(d, "' "$ROOT/src/app.zig"; then
    assert_unique "$ROOT/src/app.zig" "adw_about_dialog_set_version\(d, \"$old_re\"\);"
  fi
  assert_unique "$ROOT/pkg/arch/PKGBUILD" "^pkgver=$old_re$"
  assert_unique "$ROOT/pkg/arch/.SRCINFO" "^	pkgver = $old_re$"
  assert_unique "$ROOT/pkg/arch/.SRCINFO" "^	source = seance-fork-$old_re-src\.tar\.gz::"
  assert_unique "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml" "^[[:space:]]*placeholder: \"$old_re\"$"
  assert_unique "$ROOT/resources/com.seance-fork.app.metainfo.xml" "^  <releases>$"
  assert_unique "$ROOT/CHANGELOG.md" "^## \[Unreleased\]$"
  assert_unique "$ROOT/CHANGELOG.md" "^## \[$old_re\]$"
}

edit_all() {
  local old="$1" new="$2" notes="$3" date="$4"
  local old_re block tmp
  old_re="$(sed_pattern "$old")"

  sed -i "s|^\([[:space:]]*\)\.version = \"$old_re\"|\1.version = \"$new\"|" "$ROOT/build.zig.zon"

  # Phase 2 trees inject the version instead of carrying a literal.
  if grep -qF 'adw_about_dialog_set_version(d, "' "$ROOT/src/app.zig"; then
    sed -i "s|adw_about_dialog_set_version(d, \"$old_re\")|adw_about_dialog_set_version(d, \"$new\")|" \
      "$ROOT/src/app.zig"
  fi

  sed -i "s|^pkgver=$old_re$|pkgver=$new|" "$ROOT/pkg/arch/PKGBUILD"

  sed -i -e "s|^\([[:space:]]*\)pkgver = $old_re\$|\1pkgver = $new|" \
    -e "/^[[:space:]]source = / s|$old_re|$new|g" \
    "$ROOT/pkg/arch/.SRCINFO"

  sed -i "s|placeholder: \"$old_re\"|placeholder: \"$new\"|" \
    "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"

  block="$(printf '    <release version="%s" date="%s">\n      <description>\n        <p>%s</p>\n      </description>\n    </release>' \
    "$new" "$date" "$notes")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/bump-metainfo.XXXXXX")"
  awk -v block="$block" '/^  <releases>$/ { print; print block; next } { print }' \
    "$ROOT/resources/com.seance-fork.app.metainfo.xml" > "$tmp"
  mv "$tmp" "$ROOT/resources/com.seance-fork.app.metainfo.xml"

  tmp="$(mktemp "${TMPDIR:-/tmp}/bump-changelog.XXXXXX")"
  awk -v v="$new" '/^## \[Unreleased\]$/ { print; print ""; print "## [" v "]"; next } { print }' \
    "$ROOT/CHANGELOG.md" > "$tmp"
  mv "$tmp" "$ROOT/CHANGELOG.md"
}

dry_run() {
  local original="$ROOT" rel new="$1" notes="$2" date="$3"
  DRY_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/seance-bump.XXXXXX")"
  trap 'rm -rf "$DRY_RUN_TMP"' EXIT
  for rel in "${FILES[@]}"; do
    mkdir -p "$DRY_RUN_TMP/$(dirname "$rel")"
    cp "$original/$rel" "$DRY_RUN_TMP/$rel"
  done
  ROOT="$DRY_RUN_TMP"
  guard_edits "$(canonical_version)"
  edit_all "$(canonical_version)" "$new" "$notes" "$date"
  if ! check_all; then
    echo "dry-run result would not pass --check" >&2
    exit 1
  fi
  ROOT="$original"
  for rel in "${FILES[@]}"; do
    diff -u "$original/$rel" "$DRY_RUN_TMP/$rel" || true
  done
  echo "dry-run complete: no file under $original was modified"
}

parse_args() {
  MODE=apply
  NEW_VERSION=""
  NOTES=""
  DATE="$(date +%F)"
  NO_GIT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) MODE=check ;;
      --dry-run) MODE=dry-run ;;
      --no-git) NO_GIT=1 ;;
      --date)
        [[ $# -ge 2 && -n "${2:-}" ]] || refuse "--date needs a YYYY-MM-DD value"
        DATE="$2"
        shift
        ;;
      --notes)
        [[ $# -ge 2 && -n "${2:-}" ]] || refuse "--notes needs a paragraph (the AppStream release description needs it)"
        NOTES="$2"
        shift
        ;;
      -h|--help) usage; exit 0 ;;
      --*) refuse "unknown option $1" ;;
      *)
        [[ -z "$NEW_VERSION" ]] || refuse "unexpected argument $1"
        NEW_VERSION="$1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  preflight

  if [[ "$MODE" == "check" ]]; then
    if check_all; then
      echo "all locations in sync with build.zig.zon ($(canonical_version))"
      exit 0
    fi
    echo "version drift detected" >&2
    exit 1
  fi

  [[ -n "$NEW_VERSION" ]] || refuse "a X.Y.Z version argument is required"
  [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || refuse "$NEW_VERSION is not a X.Y.Z version"
  [[ -n "$NOTES" ]] || refuse "--notes is required (the AppStream release description needs it)"
  case "$NOTES" in
    *"&"*|*"<"*|*">"*)
      refuse "--notes must be XML-safe text: no & < or > (use plain wording, not markup)"
      ;;
  esac

  if [[ "$MODE" == "apply" && "$NO_GIT" == "0" && -e "$ROOT/.git" ]]; then
    if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
      refuse "tracked files are modified; commit or stash first (git status --porcelain)"
    fi
    if [[ -n "$(git -C "$ROOT" tag -l "v$NEW_VERSION")" ]]; then
      refuse "tag v$NEW_VERSION already exists"
    fi
  fi

  local old sorted
  old="$(canonical_version)"
  sorted="$(printf '%s\n%s\n' "$old" "$NEW_VERSION" | sort -V)"
  if [[ "$(head -n1 <<<"$sorted")" != "$old" || "$(tail -n1 <<<"$sorted")" != "$NEW_VERSION" ]]; then
    refuse "$NEW_VERSION is not strictly greater than the current version $old"
  fi

  guard_edits "$old"

  if [[ "$MODE" == "dry-run" ]]; then
    dry_run "$NEW_VERSION" "$NOTES" "$DATE"
    exit 0
  fi

  edit_all "$old" "$NEW_VERSION" "$NOTES" "$DATE"

  if ! check_all; then
    echo "files were left edited: run bash scripts/bump-version.sh --check for details" >&2
    exit 1
  fi

  if [[ "$NO_GIT" == "0" ]]; then
    if [[ ! -e "$ROOT/.git" ]]; then
      refuse "no git repo at $ROOT (use --no-git to edit without committing)"
    fi
    git -C "$ROOT" add -- build.zig.zon src/app.zig pkg/arch/PKGBUILD \
      pkg/arch/.SRCINFO resources/com.seance-fork.app.metainfo.xml \
      .github/ISSUE_TEMPLATE/bug_report.yml CHANGELOG.md
    git -C "$ROOT" commit -m "chore: bump version to $NEW_VERSION and sync release metadata" \
      -m "All release-version locations synced by scripts/bump-version.sh. sha256sums are updated at release time."
    git -C "$ROOT" tag "v$NEW_VERSION"
    echo "Done: commit + tag v$NEW_VERSION created locally. Push with: git push origin HEAD v$NEW_VERSION"
  else
    echo "Done: files edited. Run bash scripts/bump-version.sh --check to verify."
  fi
}

main "$@"
