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

- **Language:** Zig 0.15.2+
- **Graphics:** GTK4, libadwaita, OpenGL 4.3+ (desktop, not GLES)
- **Platform:** Linux (X11 or Wayland)
- **GPU:** Mesa or proprietary GPU drivers (for libGL/libEGL)

## Build Dependencies

### Ubuntu/Debian

```bash
sudo apt install pkg-config libgtk-4-dev libadwaita-1-dev libnotify-dev libcanberra-dev inotify-tools
```

### Arch Linux

```bash
sudo pacman -S gtk4 libadwaita libnotify libcanberra inotify-tools
```

`inotify-tools` is required for real-time agent status monitoring with Poolside, Codebuff, and Freebuff agents.

## Clone and Build

```bash
git clone --recursive https://github.com/scross01/seance-fork.git
cd seance
zig build
```

The `--recursive` flag initializes the Ghostty submodule during clone. If you cloned without it:

```bash
git submodule update --init --recursive
```

### First-Time Setup (Patches)

After cloning, apply the Ghostty patches:

```bash
bash scripts/apply-ghostty-patches.sh
```

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

Patches live in `patches/`. The upstream is `ghostty-org/ghostty`.

### Apply Patches

```bash
bash scripts/apply-ghostty-patches.sh
```

### Update to New Upstream Version

```bash
bash scripts/update-ghostty.sh <commit-or-tag>
```

**Do not commit the ghostty submodule with patches applied.** The submodule ref should stay at the clean upstream commit.

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

### Test Files

- `src/osc_parser.zig` — OSC protocol parser tests
- `src/port_scan.zig` — Port scanning tests (standalone)
- `src/e2e_test.zig` — End-to-end integration tests

## Gotchas

- **OpenGL requirement:** Ghostty requires desktop OpenGL 4.3+, not GLES. `main.zig` sets `GDK_DISABLE=gles-api,vulkan` before GTK init.
- **Fontconfig linking:** System fontconfig must be linked once per process (ELF interposition crash). See `build.zig` `system_library_options`.
- **Do not use `zig-out/bin/seance` directly:** It lacks installed assets. Use `make run` instead.
- **Ghostty submodule:** Keep the submodule ref at the clean upstream commit. Patches are applied to the working tree, not committed to the submodule.
