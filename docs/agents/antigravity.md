# Antigravity CLI Integration

Séance integrates with [Antigravity CLI](https://antigravity.google/docs/cli/getting-started) (`agy`) through its [status-line callback](https://antigravity.google/docs/cli/statusline/). Unlike Claude Code's shell hooks or the TypeScript plugin agents, Antigravity uses a status-line command that Séance wraps on first launch.

## How It Works

1. **Wrapper script** intercepts `agy` launches inside Séance terminals and tracks the PID
2. **Status callback installs** via `seance ctl antigravity-config` — the wrapper adds a callback to `~/.gemini/antigravity-cli/settings.json`, keeping an original backup at `settings.json.seance-backup`
3. **Antigravity reports state** through the callback, which forwards it to the socket
4. **Sidebar updates** with Starting, Running, Needs input, or Idle

## States

| `agent_state` | Séance Status |
|---------------|---------------|
| `initializing` / `authenticating` | Starting |
| `thinking` / `working` / `tool_use` | Running |
| `tool_confirmation_pending` | Needs input |
| `error` | Idle |
| `idle` | Working (if background tasks remain) or Idle |

## Features

- **Per-surface status** — each pane tracks its own Antigravity session independently
- **Needs input detection** — actual tool confirmation dialogs show **Needs input** and trigger one notification per transition
- **Idle notifications** — returning to idle triggers **Antigravity is idle**, including after cancellation or denial; this does not assert that the task succeeded
- **Background tasks** — reported background tasks keep the pane Working until they finish
- **Non-destructive install** — existing settings and custom status-line output are preserved; the default status line stays visible. An explicitly disabled status-line callback is respected and disables tracking

## Configuration

Disable the integration in **Settings → Integrations → Antigravity CLI Integration**, or set `antigravity-hooks = false` under `[behavior]` in Séance's configuration, then open a new pane:

```toml
[behavior]
antigravity-hooks = false
```

## Limitations

- **TUI status only** — headless/print mode, unreported background permission requests, and non-tool input dialogs are not covered
- **Management commands** — `agy help`, `install`, `mcp`, `models`, `plugin`, and similar subcommands pass straight through without tracking

---

## For Contributors

### Integration Approach

Antigravity uses the status-line callback. The wrapper script (`resources/bin/agy`) discovers the real `agy` binary, skips print/management invocations, and calls `seance ctl antigravity-config` to install the callback. The callback is inert outside tracked launches (it checks `SEANCE_AGY_SESSION_DIR` and `SEANCE_AGY_BIN`) and resolves Séance through the wrapper's environment, so it also works with AppImages.

### Key Implementation Details

- `src/antigravity.zig` — callback wrapping, settings install (symlink-resolved, locked against concurrent panes), and the state machine in `transition()`
- `seance ctl antigravity-hook state` receives the status-line snapshot; `antigravity-hook session-end` closes tracking
- **Status mode:** Per-surface. Status key prefix `antigravity`, mode `surface`.
- `clear_status_on_end` is `true`; `has_notification_hook` is `false`.
- **Config toggle:** `antigravity-hooks` (default `true`).
- **Settings path:** `~/.gemini/antigravity-cli/settings.json` (backup: `settings.json.seance-backup`).