# Building Séance

How to build Séance from source, manage dependencies, and work with the Ghostty submodule.

## Table of Contents

- [System Requirements](#system-requirements)
- [Build Dependencies](#build-dependencies)
- [Clone and Build](#clone-and-build)
- [Binary Location](#binary-location)
- [AppImage](#appimage)
- [Updating Ghostty](#updating-ghostty)
- [Worktrees](#worktrees)
- [Testing](#testing)
- [Gotchas](#gotchas)

## System Requirements

- **Language:** Zig 0.16.0 (pinned — 0.17.x is not supported yet)
- **Graphics:** GTK4, libadwaita, OpenGL 4.3+ (desktop, not GLES)
- **Platform:** Linux (X11 or Wayland)
- **GPU:** Mesa or proprietary GPU drivers (for libGL/libEGL)

## Build Dependencies

### Ubuntu/Debian

```bash
sudo apt install pkg-config libgtk-4-dev libadwaita-1-dev libcanberra-dev libwebkitgtk-6.0-dev inotify-tools
```

### Arch Linux

```bash
sudo pacman -S gtk4 libadwaita libcanberra webkitgtk-6.0 inotify-tools
```

`inotify-tools` is required for real-time agent status monitoring with Codebuff and Freebuff agents (the Freebuff monitor also uses `ps` from procps, present on any standard Linux system).

## Clone and Build

```bash
git clone --recursive https://github.com/scross01/seance-fork.git
cd seance-fork
make build
make run
```

The `--recursive` flag initializes the Ghostty submodule during clone. If you cloned without it:

```bash
git submodule update --init --recursive
```

The Makefile requires Zig 0.16.0 exactly. `make check-zig` reports the
toolchain it would use; it prefers a matching `zig` on `PATH` and otherwise
falls back to a keg-only Homebrew `zig@0.16` install. Override explicitly with
`make ZIG=/path/to/zig-0.16.0/zig build`.

### First-Time Setup

The Ghostty submodule points at `no1msd/ghostty` on the `seance-patches`
branch, which has the embedding patches baked in — no local patch
application needed. After cloning with `--recursive`, the submodule is
ready to build.

### Build with Assets

For a full build that installs icons, shell integration, and themes:

```bash
make build
```

This installs to `AppDir/usr/` and is required for the application to work correctly.

### Run

```bash
make run
```

**Do not use `zig-out/bin/seance` directly** — it lacks installed assets (icons, shell integration, themes). Always use `make run` which installs to `AppDir/usr` first.

## Binary Location

After `zig build`, the binary is at:

```
zig-out/bin/seance
```

This is a development build without installed assets. For a full build with icons and shell integration, use `make build` which installs to `AppDir/usr/`.

## AppImage

Build an AppImage for distribution:

```bash
make appimage
```

The AppImage requires `libfuse2` on the host and uses the host's `libGL`/`libEGL`.

To use `seance ctl` from your shell, move the AppImage onto your `PATH`:

```bash
mv seance-*-x86_64.AppImage ~/.local/bin/seance
```

## Updating Ghostty

The Ghostty submodule points at `no1msd/ghostty`, branch `seance-patches`
(embedding patches baked in — no local patch application). Upstream for the
patch set is `ghostty-org/ghostty`.

```bash
git -C ghostty fetch origin && git -C ghostty checkout <commit-or-tag>
git add ghostty
```

## Worktrees

To avoid re-cloning/rebuilding the Ghostty submodule in each worktree:

```bash
scripts/worktree-add.sh <branch> [directory]
```

This symlinks the worktree's `ghostty/` to the main repo's submodule. Zig's global cache (`~/.cache/zig/`) reuses the compiled `ghostty_static` artifact.

**Do NOT modify the shared Ghostty submodule from a worktree.**

**Agent worktree policy:** Do NOT use worktrees for feature branches in this repo. The Ghostty submodule symlink setup is fragile and breaks `zig build test`. Make changes directly on a feature branch in the main working tree.

## Testing

### Unit Tests

```bash
zig build test
```

Fast, no external dependencies required.

### Specific Test

```bash
zig build test -Dtest-filter=<name>
```

### E2E Tests

```bash
zig build e2e
```

Requires Xvfb for a virtual display.

### Required GUI Regression Suites

GUI suites run against the installed binary under a strict runner. A skip is a
failure there, so an environment gap cannot masquerade as a passing run:

```bash
make check-zig
make build
SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" G_DEBUG=fatal-criticals GTK_A11Y=none \
  xvfb-run -a python3 -B tests/run_required_gui.py
```

The runner rejects a missing or non-executable binary, a missing display, a
missing suite file, an import error, a zero-test module, any skip and any
failure, and prints `tests=` counts per suite. Its inventory lives in
`REQUIRED_SUITES` in `tests/run_required_gui.py`; add new GUI regressions there.
Required host tools: `Xvfb`/`xvfb-run`, `xdotool`, `setxkbmap`, `openbox`, `zsh`,
`openssl`, `inotify-tools`, plus a C compiler with GTK4 headers for the fullscreen
and IME suites. `python3 -m unittest discover -s tests -v` still runs the wrapper
and plugin suites; its GUI modules skip without `SEANCE_TEST_BINARY`, so it does
not replace the runner. Real-agent checks stay opt-in.

### Diagnostic Environment Variables

These are off by default. None of them change behaviour — they only add lines to
stderr for debugging and for the GUI harness.

| Variable | What it logs |
|---|---|
| `SEANCE_INIT_DIAG` | A pane that still has no terminal surface 500 ms after creation: its pending size, GLArea size and root-window state, then two follow-up samples of the workspace's viewport cache and layout passes. A healthy start logs nothing. |
| `SEANCE_TLS_DIALOG_LOG` | When the browser TLS exception dialog is presented, and which response it returned. `test_browser_tls.py` waits for the presentation line before typing at the dialog. |
| `SEANCE_NOTIF_FOCUS_LOG` | The keyboard-focus owner each frame while the notification popover is open, plus Tab/Return key probes at the capture and bubble phases. |
| `SEANCE_DEBUG` | What `summarizeNotification` produced for an agent hook notification (`subtitle` and `body`). |

For example, tracing a pane that never brought up its shell:

```bash
SEANCE_INIT_DIAG=1 SEANCE_TEST_BINARY="$PWD/AppDir/usr/bin/seance" \
  G_DEBUG=fatal-criticals GTK_A11Y=none xvfb-run -a python3 -B tests/run_required_gui.py
```

### Test Files

- `src/osc_parser.zig` — OSC protocol parser tests
- `src/port_scan.zig` — Port scanning tests (standalone)
- `src/e2e_test.zig` — End-to-end integration tests

## Gotchas

- **OpenGL requirement:** Ghostty requires desktop OpenGL 4.3+, not GLES. `main.zig` sets `GDK_DISABLE=gles-api,vulkan` before GTK init.
- **Fontconfig linking:** System fontconfig must be linked once per process (ELF interposition crash). See `build.zig` `system_library_options`.
- **Do not use `zig-out/bin/seance` directly:** It lacks installed assets. Use `make run` instead.
- **Ghostty submodule:** Points at the `seance-patches` branch with embedding patches baked in — do not point it back to a clean `ghostty-org/ghostty` commit.
