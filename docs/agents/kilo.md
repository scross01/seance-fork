# Kilo Code Integration

Séance integrates with [Kilo Code](https://kilo.ai) through a TypeScript plugin that auto-installs to `~/.config/kilo/plugins/`. Kilo is a fork of OpenCode, so the integration is nearly identical.

## How It Works

1. **Plugin auto-installs** on Séance startup (if `~/.config/kilo` exists)
2. **Plugin hooks into** Kilo's event system, forwarding lifecycle events to Séance
3. **Wrapper script** intercepts `kilo` launches, tracks PID, and fires `session-end` on exit

## Events Handled

| Kilo Event | Séance Hook | What It Shows |
|------------|-------------|---------------|
| `session.created` | `session-start` | Running |
| `session.status` (busy) | `prompt-submit` | Running |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |
| `permission.asked` | `notification` | Needs input |
| `session.idle` | `stop` | Idle |
| `session.error` | `session-end` | (cleared) |
| `session.updated` | `session-start` | Running |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Permission detection** — shows "Waiting for permission" when Kilo asks to run a command
- **Desktop notifications** — notifies on completion and permission requests
- **Session directory tracking** — Kilo exposes session directory via `SEANCE_KILO_SESSION_DIR` environment variable

## Configuration

Toggle integration on or off in `config.toml`:

```toml
kilo-hooks = true
```

## Limitations

- **No subagent tracking** — Kilo doesn't emit subagent lifecycle events (unlike MiMo Code)
- **Session directory** — Kilo exposes a session directory via environment variable, which is unused by Séance

---

## For Contributors

### Integration Approach

Kilo Code uses a **TypeScript plugin** (`plugins/seance-kilo/index.ts`) auto-installed to `~/.config/kilo/plugins/`. Kilo is a fork of OpenCode, so the integration is virtually identical — the plugin is a copy of the OpenCode plugin with command substitutions (`kilo-hook` instead of `opencode-hook`).

A wrapper script (`resources/bin/kilo`) intercepts launches for PID tracking and `session-end` on exit.

**Version:** `@seance-version 13` (same as OpenCode)

### Event Mapping

Identical to OpenCode:

| Kilo Event | Seance Hook | UI Status |
|---|---|---|
| `session.created` | `session-start` | Running |
| `session.status` (busy) | `prompt-submit` | Running |
| `session.idle` | `stop` | Idle |
| `session.error` | `session-end` | (cleared) |
| `session.updated` | `session-start` | Running |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |
| `permission.asked` | `notification` | Needs input |
| `permission.replied` | (no-op) | — |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `kilo`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.config/kilo/plugins/seance-kilo.ts`
- **Disabled check:** `SEANCE_KILO_HOOKS_DISABLED=1`.
- **Subagent detection:** Same heuristic as OpenCode — detects children via `sessionID` mismatch on session events. Uses `completedSessions` to avoid re-tracking. Has `trackChildSession()` / `untrackChildSession()` helper functions.

### Upstream Framework Events

**Source:** [kilo.ai/docs/automate/extending/plugins](https://kilo.ai/docs/automate/extending/plugins)

Kilo Code shares OpenCode's event system (Kilo is a fork of OpenCode), plus adds TUI-specific events:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `session.created` | New session created | Yes |
| `session.updated` | Session state changed | Yes |
| `session.idle` | Session became idle | Yes |
| `session.error` | Session error occurred | Yes |
| `session.status` | Session status changed (busy/idle) | Yes |
| `session.deleted` | Session was deleted | **No** |
| `session.compacted` | Session context was compacted | **No** |
| `session.diff` | Session diff available | **No** |
| `message.updated` | Message content updated | **No** |
| `message.removed` | Message removed | **No** |
| `message.part.updated` | Message part updated | **No** |
| `message.part.removed` | Message part removed | **No** |
| `tool.execute.before` | Before tool execution | Yes |
| `tool.execute.after` | After tool execution | Yes |
| `permission.asked` | Permission request | Yes |
| `permission.replied` | Permission response | Yes |
| `file.edited` | File was edited | **No** |
| `file.watcher.updated` | File changed on disk | **No** |
| `lsp.updated` | LSP connection state changed | **No** |
| `lsp.client.diagnostics` | LSP diagnostics received | **No** |
| `command.executed` | Slash command executed | **No** |
| `shell.env` | Shell environment injection | **No** |
| `todo.updated` | Todo list changed | **No** |
| `server.connected` | Server connection established | **No** |
| `installation.updated` | Installation state changed | **No** |
| `tui.prompt.append` | Append to prompt | **No** |
| `tui.command.execute` | TUI command executed | **No** |
| `tui.toast.show` | Show toast notification | **No** |

### Missing Event Coverage

Events that Kilo Code can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.deleted` | Clear status when session is explicitly deleted |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |

**Impact:** Séance currently only tracks session lifecycle and tool execution. It misses file changes, LSP diagnostics, and task progress that could provide richer status information.
