# Changelog

## [Unreleased]

### Added
- OpenCode V2 support: both Séance plugins ported to the V2 plugin API, with
  version-aware launch/install selection via `opencode --version` (V1-safe
  fallback) and per-launch `--standalone` private servers so each pane's
  status stays correctly attributed (`SEANCE_OPENCODE_V2_STANDALONE=0` opts
  out; explicit `--server` targets pass through untracked).
- Multi-session awareness for OpenCode V2 windows: the pane is **Running**
  while any session in the window executes and the subagent badge counts only
  sessions with a `parentID`, so independent concurrent sessions no longer
  inflate the count or leave a working pane marked idle.

## [0.5.1]

### Changed
- Merged upstream Séance v0.1.7 baseline.

### Fixed
- Crash when closing the last pane.
- Socket server crashes on numeric inputs and scrollbar teardown.
- Deadlock when closing busy windows and workspaces (includes ghostty
  submodule advance `7ff3a3da`→`77d8eee`: cancel surface mailbox sends before
  joining worker threads).
- Browser `system.capabilities` result buffer sizing.

## [0.5.0]

### Changed
- Merged upstream Séance v0.1.6 baseline; fork versioning is now independent
  of upstream.
- Migrated to Zig 0.16.0 and upgraded the embedded Ghostty.

### Added
- OpenCode agent tracking via per-launch inline plugin injection.
- Antigravity CLI status tracking.
- Setting to hide the sidebar button bar.
- Fullscreen toggle and desktop search keyword.

### Fixed
- XKB keyboard remap issues.
- IME composition routing and cursor placement.
- Codex hook warnings and repeated approvals.
- Shell integration resources.

## [0.4.0]

### Added
- Browser panel UX overhaul, full keybind customization with conflict
  detection, and per-shortcut reset.

## [0.3.1]

### Fixed
- VitePress build/CI config (static assets moved to `docs/public`).
- AppImage icon rendered greyscaled (now uses a pre-rendered PNG).

## [0.3.0]

### Changed
- Ghostty decoupled from the fork: builds against upstream with build-time
  patches instead of vendoring.
- CI updated for the Node.js 20 deprecation.

### Added
- Poolside `pool`, Codebuff, and Freebuff agent integrations.
- inotifywait-based status detection for shell-wrapped agents.
- Desktop notifications when the window is unfocused.
- VitePress documentation site and worktree helper for the ghostty submodule.
- SessionStore unit tests.

### Fixed
- Session store writes are now atomic (prevent concurrent clobbering).
- Overflow-safe buffer pattern in socket server list handlers.
- Backslash escaping in shell integration git branch JSON.
- Subagent status tracking in OpenCode and Kilo plugins.

## [0.2.0]

### Added
- Dual session tracking, subagent support, and detailed permission alerts for
  OpenCode and Kilo.
- MiMo Code subagent count in status text and simplified permission
  notification.
- Status set to Idle after new session creation in MiMo Code, OpenCode, and
  Kilo plugins.
- Config parser resilience, JSON injection fixes, temp file hardening, and
  path validation (Vibe idempotency included).

### Fixed
- Hermes wrapper skips itself via directory comparison instead of checking for
  the seance binary.
- `.zshenv` symlinked into wrapper resources to skip the new-user wizard.

## Older releases

Before the fork's own numbering started at `v0.2.0`, seance-fork tracked
upstream's `0.1.x` version numbers while shipping its own unversioned updates
under them — the agent support in those tags was seance-fork's work, not
upstream features: OpenCode, Kilo CLI, MiMo Code, and Mistral Vibe (0.1.5) and
Hermes Agent (0.1.6) landed here before upstream adopted them. `v0.1.7` is a
genuine upstream release merged into the fork with the rest of the v0.1.7
baseline (see 0.5.1).


