# OpenCode Integration

Séance integrates with [OpenCode](https://opencode.ai) through a TypeScript plugin that auto-installs to `~/.config/opencode/plugins/`.

## How It Works

1. **Plugin auto-installs** on Séance startup (if `~/.config/opencode` exists)
2. **Plugin hooks into** OpenCode's event system, forwarding lifecycle events to Séance
3. **Wrapper script** intercepts `opencode` launches, tracks PID, and fires `session-end` on exit

## Events Handled

| OpenCode Event | Séance Hook | What It Shows |
|----------------|-------------|---------------|
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
- **Permission detection** — shows "Waiting for permission" when OpenCode asks to run a command
- **Desktop notifications** — notifies on completion and permission requests
- **Session directory tracking** — OpenCode exposes session directory via `SEANCE_OPENCODE_SESSION_DIR` environment variable

## Configuration

Toggle integration on or off in `config.toml`:

```toml
opencode-hooks = true
```

## Limitations

- **No subagent tracking** — OpenCode doesn't emit subagent lifecycle events (unlike MiMo Code)
- **No session directory** — session is managed through plugin in-memory state

---

## For Contributors

### Integration Approach

OpenCode uses a **TypeScript plugin** (`plugins/seance-opencode/index.ts`) auto-installed to `~/.config/opencode/plugins/`. A wrapper script (`resources/bin/opencode`) intercepts launches for PID tracking and `session-end` on exit.

The plugin exports a `SeancePlugin` async function receiving `$` (shell executor). It subscribes to OpenCode's event system and sends hooks via `seance ctl opencode-hook <event>` subprocess with JSON payload piped via stdin.

**Version:** `@seance-version 13`

### Event Mapping

| OpenCode Event | Seance Hook | UI Status |
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

**Unhandled events:** `session.deleted`, `session.compacted`, `session.diff`, all message events, all file events, all LSP events, `command.executed`, `shell.env`, `todo.updated`.

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `opencode`, mode `surface`. Each pane tracks independently.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.config/opencode/plugins/seance-opencode.ts`
- **Early exit conditions:** Plugin returns empty object if `SEANCE_SOCKET_PATH` not set or `SEANCE_OPENCODE_HOOKS_DISABLED=1`.
- **Binary discovery:** Derives `seanceBin` from `SEANCE_BIN_DIR` env var, falling back to `"seance"`.
- **State variables:** `currentSessionId`, `sessionIdle`, `permissionPending`, `childSessions` (Set), `completedSessions` (Set), `subagentCount`.
- **Subagent detection via session ID mismatch:** When `session.created` or `session.updated` fires with a session ID different from `currentSessionId`, it's tracked as a child session. Uses `completedSessions` set to avoid re-tracking completed sessions.

### Upstream Framework Events

**Source:** [opencode.ai/docs/plugins](https://opencode.ai/docs/plugins)

OpenCode's full event system includes:

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

### Missing Event Coverage

Events that OpenCode can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.deleted` | Clear status when session is explicitly deleted |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |

**Impact:** Séance currently only tracks session lifecycle and tool execution. It misses file changes, LSP diagnostics, and task progress that could provide richer status information.
