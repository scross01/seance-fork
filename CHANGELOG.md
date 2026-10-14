# Changelog

## [Unreleased]

## [0.6.0]

### Added
- Support for OpenCode V2 alongside V1 with automatic version detection.
- OpenCode V2 panes stay Running while any session in the window is working and count subagents separately from independent sessions.
- OpenCode V2 panes with multiple sessions show how many sessions share the pane.
- Completion notifications for OpenCode, Kilo Code, and MiMo Code now name the project that finished.
- Notification history is kept and marked read on viewing instead of being deleted.
- Header menu with the full command list, shortcut hints, Preferences, Keyboard Shortcuts, and About.
- Close window is now in the menu and command palette and can be rebound like any shortcut.
- Setting to adjust the active-pane focus ring opacity.

### Changed
- Sidebar shows readable activity descriptions for OpenCode-family tools instead of raw tool names.
- Active-pane indicator follows the system accent color with a uniform outline.
- Sidebar width is capped on narrow windows and the window has a minimum size.
- Interface text respects system text scaling with brighter dimmed text for readability.
- Labels across the app use sentence case with proper ellipses.
- Notifications use the system notification service with per-app settings and Do Not Disturb awareness.
- Browser toolbar is more compact with a single focus ring.

### Fixed
- OpenCode V2 questions and status prompts that previously never appeared are now tracked.
- Duplicate desktop alerts for OpenCode V2 events are gone.
- Séance now explains when OpenCode tracking falls back instead of failing silently.
- Browser commands no longer freeze the interface for several seconds.
- Accessibility, keyboard navigation, high-contrast, and reduced-motion support hardened.
- File pickers use the modern system dialog.

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


