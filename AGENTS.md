# Agent Guide — Séance-fork

## Build & Run

```bash
# First-time setup (submodule + patches)
git submodule update --init --recursive
bash scripts/apply-ghostty-patches.sh

# Build (installs to AppDir/usr with assets)
make build

# Run (uses installed prefix with icons, shell integration, etc.)
make run

# AppImage
make appimage
```

**Do not use `zig-out/bin/seance` directly** — it lacks installed assets (icons, shell integration, themes). Always use `make run` which installs to `AppDir/usr` first.

Requires: Zig 0.15.2+, GTK4, libadwaita, pkg-config, OpenGL 4.3+.

## Testing

```bash
# Unit tests (fast, no deps)
zig build test

# Specific test
zig build test -Dtest-filter=<name>

# E2E tests (needs Xvfb)
zig build e2e
```

Test files: `src/osc_parser.zig`, `src/port_scan.zig` (standalone), `src/e2e_test.zig` (E2E).

## Updating Ghostty

Patches live in `patches/`. Upstream is `ghostty-org/ghostty`.

```bash
# Apply patches to working tree
bash scripts/apply-ghostty-patches.sh

# Update to new upstream version
bash scripts/update-ghostty.sh <commit-or-tag>
```

**Do not commit ghostty submodule with patches applied.** The submodule ref should stay at the clean upstream commit.

## Architecture

- **Language:** Zig (0.15.2), GTK4/libadwaita, OpenGL 4.3+
- **Entry:** `src/main.zig` → `src/app.zig`
- **Terminal rendering:** libghostty via `src/ghostty_bridge.zig` (C FFI)
- **CLI:** `seance ctl` → `src/ctl.zig` (Unix socket IPC)
- **Plugins:** `plugins/seance-{opencode,kilo,mimocode}/index.ts` (TypeScript, auto-installed)
- **Config:** `~/.config/seance/config.toml` (runtime), `src/default_config.toml` (defaults)

Key source files:
- `src/pane.zig` — terminal pane lifecycle
- `src/session.zig` — agent session tracking
- `src/sidebar.zig` — agent status display
- `src/socket_server.zig` — ctl IPC server
- `src/keybinds.zig` — keyboard shortcuts

## Conventions

- Zig style: standard `zig fmt` formatting
- Error handling: `!void` returns, `catch` with logging
- No comments unless non-obvious (see code comments for exceptions)
- Commit messages: conventional commits (`feat:`, `fix:`, `chore:`)

## Gotchas

- Ghostty requires desktop OpenGL 4.3+, not GLES. `main.zig` sets `GDK_DISABLE=gles-api,vulkan` before GTK init.
- System fontconfig must be linked once per process (ELF interposition crash). See `build.zig` system_library_options.
- `LOCAL.md` is gitignored — local dev notes only.
- `plans/` is gitignored — implementation plans from `/improve` skill.
