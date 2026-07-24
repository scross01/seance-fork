# MiMo Code Integration

Séance integrates with [MiMo Code](https://github.com/XiaoMi/mimo-code) through a TypeScript plugin that auto-installs to `~/.config/mimocode/plugins/`. MiMo Code is a fork of OpenCode with additional subagent orchestration features.

## How It Works

1. **Plugin auto-installs** on Séance startup (if `~/.config/mimocode` exists)
2. **Plugin hooks into** MiMo Code's event system, forwarding lifecycle events to Séance
3. **Wrapper script** intercepts `mimo` launches, tracks PID, and fires `session-end` on exit

## Events Handled

| MiMo Code Event | Séance Hook | What It Shows |
|-----------------|-------------|---------------|
| `session.created` | `session-start` | Running |
| `session.status` (busy) | `prompt-submit` | Running |
| `session.status` (idle) | `stop` | Idle |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |
| `permission.asked` | `notification` | Needs input |
| `session.idle` | `stop` | Idle |
| `session.error` | `session-end` | (cleared) |
| `actor.registered` | `prompt-submit` | Running |
| `actor.status` (idle) | `prompt-submit` | Running |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Permission detection** — shows "Waiting for permission" when MiMo Code asks to run a command
- **Desktop notifications** — notifies on completion and permission requests
- **Subagent tracking** — MiMo Code can run multiple concurrent sessions; the plugin detects subagents via `tool.execute.before` session ID mismatches and tracks them separately
- **Activity indicators** — the sidebar icon changes based on subagent activity:

| Subtasks Active | Background Active | Icon |
|-----------------|-------------------|------|
| No | No | Normal |
| Yes | No | `system-run-symbolic` |
| No | Yes | `media-playback-start-symbolic` |
| Yes | Yes | `system-run-symbolic` (subtasks take precedence) |

## Configuration

Toggle integration on or off in `config.toml`:

```toml
mimocode-hooks = true
```

## Limitations

- **No session directory** — MiMo Code manages sessions entirely through plugin in-memory state (unlike OpenCode/Kilo which expose session directories via environment variables)

---

## For Contributors

### Integration Approach

MiMo Code uses a **TypeScript plugin** (`plugins/seance-mimocode/index.ts`) auto-installed to `~/.config/mimocode/plugins/`. MiMo Code is a fork of OpenCode with additional subagent orchestration extensions, so the plugin shares the same base architecture but adds dedicated subagent lifecycle handling.

A wrapper script (`resources/bin/mimo`) intercepts launches for PID tracking and `session-end` on exit.

**Version:** `@seance-version 37` (higher than OpenCode/Kilo due to subagent extensions)

### Event Mapping

| MiMo Code Event | Seance Hook | UI Status |
|---|---|---|
| `session.created` | `session-start` | Running |
| `session.status` (busy) | `prompt-submit` | Running |
| `session.status` (idle) | (handled by `session.idle`) | — |
| `session.idle` | `stop` | Idle |
| `session.error` | `session-end` | (cleared) |
| `session.updated` | `session-start` | Running |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |
| `permission.asked` | `notification` | Needs input |
| `permission.replied` | (no-op) | — |
| `actor.registered` | `prompt-submit` | Running |
| `actor.status` (idle) | `prompt-submit` | Running |

**Unhandled events:** Same as OpenCode (session.deleted, message events, file events, LSP events, etc.).

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `mimocode`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.config/mimocode/plugins/seance-mimocode.ts`
- **Disabled check:** `SEANCE_MIMOCODE_HOOKS_DISABLED=1`.

### Subagent Tracking

MiMo Code is the only agent with dedicated subagent lifecycle events:

- **`actor.registered`:** When `mode === "subagent"` and the agent is not `"checkpoint-writer"` or `"compaction"`, adds the actor to `childSessions`, increments `subagentCount`, and fires `updateCounts()` + `prompt-submit`.
- **`actor.status` (idle):** When the actorID is in `childSessions`, removes it and decrements the count, firing `updateCounts()` + `prompt-submit`.

This is more reliable than the session ID mismatch heuristic used by OpenCode/Kilo.

### Icon State Machine

The sidebar icon changes based on subagent/background activity:

| State | Icon |
|---|---|
| No subtasks, no background | Normal icon |
| Subtasks active | `system-run-symbolic` |
| Background active | `media-playback-start-symbolic` |
| Both active | `system-run-symbolic` (subtasks take precedence) |

### Key Differences from OpenCode

- **No `completedSessions` set.** MiMo Code uses dedicated `actor.registered`/`actor.status` events instead of session ID mismatch heuristics.
- **Session ID extraction.** Uses `event.properties?.sessionID` directly (no fallback to `event.properties?.info?.id`).
- **Session status mapping.** Maps both busy and idle `session.status` events (idle handled by `session.idle`).
- **Multiple concurrent sessions.** MiMo Code can fire events from multiple concurrent sessions (foreground + background indexing), tracked via `currentSessionId` plus a `childSessions` map.

### Subagent Update Command

The plugin sends a `subagent-update` command with `workspace_id`, `subagent_count`, and `background_count` whenever subagent counts change. This drives the icon state machine in the sidebar.

### Upstream Framework Events

**Source:** [github.com/XiaomiMiMo/MiMo-Code](https://github.com/XiaomiMiMo/MiMo-Code)

MiMo Code is a fork of OpenCode, so it inherits all OpenCode events plus adds its own extensions for subagent management:

#### Inherited from OpenCode

All OpenCode/Kilo Code events (see [OpenCode Integration](./opencode.md#upstream-framework-events)).

#### MiMo Code Extensions

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `actor.registered` | New actor/subagent registered | Yes |
| `actor.status` | Actor status changed | Yes |

**Note:** MiMo Code adds actor lifecycle events that are not in the base OpenCode framework. These appear to be custom extensions for the subagent orchestration system.

### Missing Event Coverage

Events that MiMo Code can emit but Séance does not currently handle (same as OpenCode, plus):

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.deleted` | Clear status when session is explicitly deleted |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |

**Impact:** MiMo Code inherits OpenCode's events but Séance's plugin doesn't leverage the additional actor events for richer subagent status.
