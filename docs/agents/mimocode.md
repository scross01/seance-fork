# MiMo Code Integration

Séance integrates with [MiMo Code](https://github.com/XiaomiMiMo/MiMo-Code) through a TypeScript plugin that auto-installs to `~/.config/mimocode/plugins/`. MiMo Code is a fork of OpenCode with additional subagent orchestration features.

## How It Works

1. **Plugin auto-installs** on Séance startup (if `~/.config/mimocode` exists)
2. **Plugin hooks into** MiMo Code's lifecycle hooks and event bus, forwarding them to Séance as `seance ctl` events. Idle/end state comes from the harness's guaranteed `session.post` lifecycle hook.
3. **Wrapper script** intercepts `mimo` launches, tracks PID, and fires `session-end` on exit as a crash safety net

## Events Handled

| Harness Source | Séance Hook | What It Shows |
|----------------|-------------|---------------|
| `session.created` / `session.updated` | `session-start` + `prompt-submit` | Running |
| `session.pre` | `prompt-submit` | Running |
| `session.post` (`completed` / `cancelled`) | `stop` | Idle |
| `session.post` (`error`) | `session-end` | (cleared) |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |
| `permission.asked` | `notification` | Needs input |
| `actor.registered` | `prompt-submit` + `subagent-update` | Running |
| `actor.postStop` | `prompt-submit` + `subagent-update` | Running |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Permission detection** — shows "Waiting for permission" when MiMo Code asks to run a command
- **Desktop notifications** — notifies on completion and permission requests
- **Session directory tracking** — hook payloads carry the pane's launch directory, so the session record stores it and completion notifications read "Completed in `<project>`" (same as OpenCode and Kilo Code)
- **Subagent tracking** — MiMo Code's actor registry reports subagents registering and stopping; the plugin counts them and reports both `subagent_count` and `background_count`
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

---

## For Contributors

### Integration Approach

MiMo Code uses a **TypeScript plugin** (`plugins/seance-mimocode/index.ts`) auto-installed to `~/.config/mimocode/plugins/`. Since `@seance-version 40` it uses the modern MiMoCode plugin module shape:

```ts
export default { id: "seance-mimocode", server: async (input) => ({ /* hooks */ }) };
```

Path plugins loaded from `~/.config/mimocode/plugins/` **must** export `id` with this shape. The plugin uses MiMo Code 0.1.15's typed lifecycle hooks (`session.pre`, `session.post`, `actor.postStop`) instead of event-stream heuristics, and still subscribes to the event bus for session identity, permissions, and actor registration.

A wrapper script (`resources/bin/mimo`) intercepts launches for PID tracking and `session-end` on exit as a crash safety net.

**Version:** `@seance-version 40` (higher than OpenCode/Kilo due to subagent extensions)

### Event Mapping

| Harness Source | Seance Hook | UI Status |
|---|---|---|
| `session.created` / `session.updated` | `session-start` + `prompt-submit` | Running |
| `session.pre` (adopted session only) | `prompt-submit` | Running |
| `session.post` `completed` | `stop` (+ `message` from `finalText`) | Idle |
| `session.post` `cancelled` | `stop` | Idle |
| `session.post` `error` | `session-end` | (cleared) |
| `permission.asked` | `notification` | Needs input |
| `actor.registered` (subagent, non-infrastructure) | `prompt-submit` + `subagent-update` | Running |
| `actor.postStop` (matched subagent) | `prompt-submit` + `subagent-update` | Running |
| `tool.execute.before` | `pre-tool-use` | Running |
| `tool.execute.after` | `post-tool-use` | Running |

There is no `permissionPending` guard: a permission request fires `notification`, and the completion that follows fires `stop` as usual.

**Unhandled events:** Same as OpenCode (session.deleted, message events, file events, LSP events, etc.).

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `mimocode`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.config/mimocode/plugins/seance-mimocode.ts`
- **Disabled check:** `SEANCE_MIMOCODE_HOOKS_DISABLED=1` (or an unset `SEANCE_SOCKET_PATH`) makes `server()` return no hooks.
- **Session identity:** `currentSessionId` is adopted from `session.created`/`session.updated`; `session.pre`/`session.post` and tool hooks only fire for that session, so subagent slices never idle or end the main pane.

### Subagent Tracking

- **Increment:** `actor.registered` with `mode === "subagent"` and an agent **not** in the infrastructure set `["main", "summary", "title", "checkpoint-writer", "dream", "distill", "compaction"]`. `general`, `build`, and `explore` are real user-facing subagents and **are** counted. The actor is added to `childActors`, `subagentCount` is incremented, and `background_count` is set from the event's `background` flag.
- **Decrement:** the `actor.postStop` typed hook, replacing the old actor-status idle heuristic. It carries a custom matcher — `{ mode: "subagent", agentType: { excludeOnly: <infrastructure set> } }` — because the default matcher excludes *all* built-in agents, including `general`/`build`/`explore`. Background actors tracked at register time decrement `backgroundCount` too, so the count does not leak.

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

- **Modern module shape.** `export default { id, server }` rather than the named `SeancePlugin` export OpenCode/Kilo still use.
- **Typed lifecycle hooks.** `session.post` (guaranteed once via `Effect.onExit`) drives idle/end and `actor.postStop` drives subagent completion; no event-stream heuristics.
- **No `permissionPending` guard** and no `sessionIdle` flag.
- **No `completedSessions` set.** Subagents are tracked in `childActors` from the actor registry instead of session ID mismatch heuristics.
- **Session ID extraction.** Uses `event.properties?.sessionID` directly (no fallback to `event.properties?.info?.id`).
- **Multiple concurrent sessions.** MiMo Code can fire events from multiple concurrent sessions (foreground + background indexing), tracked via `currentSessionId` plus the `childActors` set.

### Subagent Update Command

The plugin sends a `subagent-update` command with `workspace_id`, `subagent_count`, and `background_count` whenever subagent counts change. This drives the icon state machine in the sidebar.

### Upstream Framework Events

**Source:** [github.com/XiaomiMiMo/MiMo-Code](https://github.com/XiaomiMiMo/MiMo-Code)

MiMo Code 0.1.15 exposes lifecycle hooks as a first-class part of the plugin API (`@mimo-ai/plugin`). Its `BUILT_IN_AGENTS` list is `["main", "general", "build", "explore", "summary", "title", "checkpoint-writer", "dream", "distill", "compaction"]`; Séance excludes the infrastructure subset of that list from the sidebar count while still counting `general`/`build`/`explore`.

#### Inherited from OpenCode

All OpenCode/Kilo Code events (see [OpenCode Integration](./opencode.md#upstream-framework-events)).

#### MiMo Code Extensions

| Source | Description | Séance Handles? |
|--------|-------------|-----------------|
| `actor.registered` (event) | New actor/subagent registered | Yes (count) |
| `actor.postStop` (hook) | Subagent delivered its final output | Yes (count) |
| `session.pre` / `session.post` (hooks) | Main turn started / finished exactly once | Yes |

**Note:** the typed hooks are the primary status source; the event bus is only used for session adoption, permissions, and actor registration.

### Missing Event Coverage

Events that MiMo Code can emit but Séance does not currently handle (optional follow-ups only — idle/end no longer depend on any of them):

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.deleted` | Clear status when session is explicitly deleted |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |
