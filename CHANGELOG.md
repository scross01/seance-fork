# Changelog

## [Unreleased]

## [0.6.0]

### Added
- OpenCode V2 support alongside V1: both plugins ported to the V2 plugin
  API, with version-aware launch/install selection via `opencode --version`
  (V1 on any detection failure) and per-launch `--standalone` private
  servers so each pane's status stays attributed to its own surface
  (`SEANCE_OPENCODE_V2_STANDALONE=0` opts out; explicit `--server` targets
  pass through untracked).
- Multi-session awareness for OpenCode V2 panes: the pane stays Running
  while any session in the window executes, and the subagent badge counts
  only sessions created with a `parentID`.
- Session-count suffix for multi-session OpenCode V2 panes
  (`OpenCode: Running · 2 sessions (1 subagent)`), stored as structured
  status data so completion, permission, and state writes no longer erase
  it. Counts repaint on session create/close and are seeded from
  `session.list` at startup so pre-existing sessions count immediately
  (OpenCode V2 plugin version 20).
- Project-aware completion notifications: the OpenCode (V1/V2), Kilo Code,
  and MiMo Code plugins send `cwd` on session hooks, so session records
  carry the launch directory (`ctl session list`) and notifications read
  "Completed in `<project>`" (plugin versions: OpenCode V1 17 / V2 20,
  Kilo 15, MiMo 39).
- Readable sidebar activity descriptions for OpenCode-family tool names
  (`shell`, `read`, `edit`, `patch`, `glob`, `grep`, `list`, `subagent`,
  `webfetch`, `websearch`, …) instead of raw tool names.
- Notification history: entries are kept and marked read on viewing or pane
  focus instead of being deleted.
- Full hamburger command menu with Splits & Layout, Tabs, and Browser
  submenus, top-level Edit (Copy/Paste/Find) sections, and native shortcut
  hints that follow keybind customization. `close_window` is a rebindable
  menu/palette action.
- Setting to adjust the active-pane focus ring opacity
  (`focus-ring-opacity` under `[colors]`).

### Changed
- Active-pane indicator rebuilt on the system accent color as a uniform
  outline; the top focus bar is gone.
- Sidebar width is capped on narrow windows and the window has a minimum
  size.
- Interface text honors system text scaling (em-based chrome type) with
  higher-contrast dimmed text.
- Labels across the app use sentence case with proper ellipses.
- Notifications go through the system notification service with per-app
  settings and Do Not Disturb awareness.
- Browser toolbar compacted to headerbar metrics with a single accent focus
  ring.
- Header Settings gear dropped in favor of the hamburger menu; Preferences,
  Keyboard Shortcuts, and About live in the primary menu.

### Fixed
- OpenCode V2 inline plugin now loads: the wrapper injects the `inline/`
  directory (V2 requires directory entries with an `index.mjs` entrypoint)
  instead of a file path, so question/form alerts and Needs input status
  fire on V2.
- OpenCode V2 duplicate alerts eliminated: each event has a single owner —
  the installed plugin announces completions and permission prompts while
  the inline publishes only Running/Needs input/Idle status for those,
  keeping the two alerts nothing else can produce (agent questions and
  OpenCode errors).
- OpenCode wrapper reports fallback decisions on the terminal (socket
  unreachable) and via notification (plugin unreadable /
  `opencode-config` failure) instead of silently disabling tracking.
- Agent plugin sync gated on content; agent plugins resolve the séance
  binary via `SEANCE_OPENCODE_BIN`.
- Browser commands run asynchronously instead of freezing the interface for
  several seconds.
- Scrollback clearing routed through ghostty's `clear_screen` binding.
- Accessibility, keyboard navigation, high-contrast, and reduced-motion
  support hardened; file pickers use the modern system dialog.
- Removed a dead 3-second timer and moved socket reads and session I/O off
  the UI path.

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


