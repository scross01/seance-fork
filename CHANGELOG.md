# Changelog

## [Unreleased]

## [0.8.0]

### Added
- `system.tree` reports each pane group's settled layout state, so automation can wait for a workspace to finish laying out instead of polling sizes.
- Starved-pane diagnostics behind `SEANCE_INIT_DIAG` are documented, naming what each sample reports.

### Changed
- Panes lay out from the container's allocation instead of a viewport poll timer, which removes the panes that stayed blank after a split, restore, or an offscreen stacked column.
- Terminal and browser panels share one ID counter, so a panel keeps a single identity across every layout operation.
- Session snapshots are written atomically, ordered, and restored within a bounded budget.
- The `scrollback-lines` setting maps onto Ghostty's line-based scrollback limit.
- Browser evaluation returns native JSON with one reply owner per request.
- CI requires the installed-binary GUI suites instead of silently skipping them, and releases build through `make build`.

### Fixed
- Agent launch wrappers no longer print the hook response (`OK`) into the pane when the agent exits.
- Hermes no longer leaves a stale "Idle" row after the process exits; a dedicated `process-exit` event clears the entry once no hermes process remains.
- Stacked rows are seated by height weight at every insertion point, so reorder, close, expel, and restore keep the intended ratios.
- Browser panels transfer safely across stacked and tabbed columns, and an expelled panel gets its own row.
- Opening a URL from a pane no longer freezes the interface.
- Browser TLS approval is scoped to the approved certificate and host.
- Notifications target records by stable identity, keep siblings unread when the popover reopens, and truncate titles at UTF-8 boundaries.
- Agent configuration installers fail closed when an existing file cannot be read, write atomically, keep a one-time backup, and preserve user settings across install, upgrade and disable.
- Pool hooks merge without duplicate events, so existing mappings stay valid.
- Control-socket requests that arrive after connect are no longer dropped, and the owned socket path is removed on clean shutdown.
- Delayed file drops and tab dialogs resolve through live identities instead of freed panels.
- Installer descriptors are closed, and a failed temporary write can be retried.
- Session snapshots and installer writes flush to disk before publishing the new name, so a power loss cannot leave a truncated file behind.
- Workspace layout signals are detached on teardown so a later allocation cannot call into freed storage.
- Port and numeric settings are validated before use, and workspace ordinal exhaustion omits the port variables instead of overflowing.
- Freebuff and Codebuff sidebar status track their own launch, and a wrapper exits without leaving a monitor behind.
- The AppImage ships the transparent PNG icon, and the dangling root icon symlink is repaired.
- Git worktree metadata resolves correctly, and equal-length branch name changes are detected.

## [0.7.0]

### Added
- Command Code (`cmd`) agent integration: sidebar status tracking via Command
  Code's hooks harness (`~/.commandcode/settings.json`), plus a
  `commandcode-hooks` config toggle and Settings UI switch.

### Changed
- Mistral Vibe hooks updated to use stable hook type names (post_agent, pre_tool, post_tool).
- Pool integration now uses native Pool CLI hooks (v1.0.16+) instead of inotify-based trajectory monitoring. The `inotify-tools` system dependency is no longer required for Pool (Codebuff and Freebuff still use it).
- MiMo Code integration rewritten against the 0.1.15 plugin API: idle/end detection uses the guaranteed `session.post` lifecycle hook, subagent completion uses `actor.postStop`, infrastructure agents (title, summary, dream, distill, …) no longer inflate the sidebar subagent count, and `background_count` is reported from MiMo Code's actor registry.
- MiMo Code plugin now ships as a modern `{ id, server }` module (`@seance-version 40`).

### Fixed
- Freebuff sidebar status now tracks the agent again: the monitor discovers
  the per-launch `log.jsonl` Freebuff writes (verified by its pid field, so
  two panes in the same project never claim each other's log) and parses
  agent-step markers instead of watching a directory tree that never received
  watch events.

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


