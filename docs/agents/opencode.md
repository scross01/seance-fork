# OpenCode Integration

Séance integrates with [OpenCode](https://opencode.ai) through TypeScript plugins that auto-install to `~/.config/opencode/plugins/` (V1 and V2 formats — Séance selects the one matching the installed major version).

## How It Works

1. **Plugin auto-installs** on Séance startup (if `~/.config/opencode` exists)
2. **Plugin hooks into** OpenCode's event system, forwarding lifecycle events to Séance
3. **Wrapper script** intercepts `opencode` launches, tracks PID, and fires `session-end` on exit
4. **Wrapper injects a second, inline plugin** — `resources/opencode/seance.mjs` (V1) or
   `resources/opencode/seance-v2.mjs` (V2) — into that launch only, via
   `seance ctl opencode-config [--v2] <path>` exported as `OPENCODE_CONFIG_CONTENT`.
   The inline plugin aggregates every session in the window into the pane's
   Running/Needs input/Idle state (including completion notices), while the
   auto-installed plugin drives the lifecycle hooks, `session-end`, and the
   subagent badge.

Both plugin formats ship: `plugins/seance-opencode/index.ts` for OpenCode V1 and
`plugins/seance-opencode/index-v2.ts` for V2 (installed as
`share/seance/opencode-plugin.ts` / `share/seance/opencode-plugin-v2.ts`). The
wrapper and the GUI auto-installer detect the installed major version via
`opencode --version` and select the matching artifact; any detection failure
(not installed, unparseable output, timeout) keeps the V1 artifacts.

### OpenCode V2 notes

- Wrapper-launched V2 TUI/`run` invocations run `opencode --standalone`
  (a private server per launch), because a shared V2 background service keeps
  the environment of whichever launch started it — the bridge would then
  misattribute per-surface status to that one pane.
- `SEANCE_OPENCODE_V2_STANDALONE=0` opts out back to the shared service, with
  tracking disabled (no plugin is injected).
- `--server` launches pass through untouched: an explicit remote server cannot
  carry this pane's plugin.
- **Shared session storage.** All OpenCode launches — any pane, any
  workspace, even bare non-séance invocations — read the same on-disk
  session database (`~/.local/share/opencode/opencode.db`), so the session
  picker in one pane lists sessions started from any other. `--standalone`
  isolates the serve process and plugin environment (séance's per-pane
  status attribution), never session data. Keep each *live* session in one
  pane: resuming the same session in two tracked panes at once makes both
  plugins adopt it, and the session-store record flips to the last writer.
- A V2 window can run several sessions at once (session picker, background
  tasks). Séance shows one status per pane: it is **Running** while any
  session in the window is executing. The subagent badge counts only real
  subagents — sessions created with a `parentID` — not independent sessions.
  **Needs input** status and question/form alerts depend on the inline
  plugin, which does not currently load on V2 (see Limitations).

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

> **V1 vs V2 vocabulary:** the table above uses OpenCode V1 event names. The V2
> plugin receives V2's renamed lifecycle events instead —
> `session.execution.started` (busy → `prompt-submit`),
> `session.execution.succeeded`/`session.execution.interrupted` (idle → `stop`),
> `session.execution.failed` (error notice + `stop`), and `session.deleted`
> (`session-end`). V1's `question.*` events were replaced by
> `form.created`/`form.replied`/`form.cancelled` (**Needs input**), and
> `permission.asked`/`permission.replied` keep their names but their payload
> fields became `action`/`resources` (V1: `permission`/`patterns`). The
> Séance-side hooks and JSON payloads are identical for both formats.

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Permission detection** — shows "Waiting for permission" when OpenCode asks to run a command
- **Desktop notifications** — notifies on completion and permission requests
- **Multi-session aggregation** — one status per pane even when a V2 window runs several concurrent sessions (see the V2 notes above)
- **Session directory tracking** — the hook payloads carry the pane's launch directory, so the session record stores it and completion notifications read "Completed in `<project>`"

## Configuration

Toggle integration on or off in `config.toml`:

```toml
opencode-hooks = true
```

## Limitations

- **Subagent counting is session-based** — subagent counts come from child sessions (`session.created` with `parentID`); independent sessions in the same window share the pane's status instead of being counted
- **V2 inline plugin does not load (known bug, plan 066)** — OpenCode 2.x requires `plugins` config entries to be *directories*, and séance's per-launch injection passes a file path, so the inline plugin (`resources/opencode/seance-v2.mjs`) is rejected at serve startup (`configured plugin path must be a directory` in `~/.local/share/opencode/log/opencode.log`). Until fixed, V2 has no question/form alerts and no **Needs input** status; tool-permission notifications still work through the global plugin. The fix points the injection at a plugin directory — no plugin-logic changes

---

## For Contributors

### Integration Approach

OpenCode uses a **TypeScript plugin** (`plugins/seance-opencode/index.ts`) auto-installed to `~/.config/opencode/plugins/seance-opencode.ts`. A wrapper script (`resources/bin/opencode`) intercepts launches for PID tracking, `session-end` on exit, and injects the inline plugin for the launch.

The plugin exports a `SeancePlugin` async function receiving `$` (shell executor). It subscribes to OpenCode's event system and sends hooks via `seance ctl opencode-hook <event>` subprocess with JSON payload piped via stdin.

**Version:** `@seance-version 17` (V1 and V2)

For OpenCode V2 the plugin lives in `plugins/seance-opencode/index-v2.ts` and
uses V2's plugin API: it exports `Plugin.define({...})`, streams lifecycle
events with `ctx.event.subscribe(...)`, observes tool execution with
`ctx.tool.hook("execute.before"/"execute.after", ...)`, and forwards payloads
to Séance through an `execFile` bridge (`seance ctl opencode-hook <event>`).
The wrapper injects the **inline** plugin — `resources/opencode/seance.mjs` for V1,
`resources/opencode/seance-v2.mjs` for V2 — into the launch with
`seance ctl opencode-config <path>` (merged into the `plugin` config key) or
`seance ctl opencode-config --v2 <path>` (merged into the V2-native `plugins`
config key), exported through `OPENCODE_CONFIG_CONTENT`. This is a different file
from the auto-installed `~/.config/opencode/plugins/seance-opencode.ts` above:
the inline plugin aggregates the window's sessions into the pane state, while
the installed one carries the lifecycle hooks, `session-end`, and the
subagent-count badge for both majors.

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

**Unhandled events:** `session.deleted` (V1; the V2 port does handle it — `session-end`), `session.compacted`, `session.diff`, all message events, all file events, all LSP events, `command.executed`, `shell.env`, `todo.updated`.

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `opencode`, mode `surface`. Each pane tracks independently.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.config/opencode/plugins/seance-opencode.ts`
- **Early exit conditions:** Plugin returns empty object if `SEANCE_SOCKET_PATH` not set or `SEANCE_OPENCODE_HOOKS_DISABLED=1`.
- **Binary discovery:** Derives `seanceBin` from `SEANCE_BIN_DIR` env var, falling back to `"seance"`.
- **State variables:** `currentSessionId`, `sessionIdle`, `permissionPending`, `childSessions` (Set), `peerSessions` (Set), `executing` (Set), `completedSessions` (Set), `subagentCount`.
- **Subagent detection (V2):** only `session.created` events carrying a `parentID` are tracked as subagent children (counted); independent sessions without `parentID` are peer sessions that share the pane's single Running/Idle state via the `executing` set (the pane goes Idle only when the last executing session finishes). `completedSessions` avoids re-tracking finished subagents. (V1 tracked every non-primary session as a subagent — V2 sessions are first-class and several can run in one window.)

### Upstream Framework Events

**Source (V1):** [opencode.ai/docs/plugins](https://opencode.ai/docs/plugins) — the V2 event registry is documented at [opencode.ai/v2/docs/plugins](https://opencode.ai/v2/docs/plugins)

OpenCode's full event system includes:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `session.created` | New session created | Yes |
| `session.updated` | Session state changed | Yes |
| `session.idle` | Session became idle | Yes |
| `session.error` | Session error occurred | Yes |
| `session.status` | Session status changed (busy/idle) | Yes |
| `session.deleted` | Session was deleted | **V1: No · V2: Yes** |
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
| `session.deleted` | Clear status when session is explicitly deleted (done by the V2 port; not on V1) |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |

**Impact:** Séance currently only tracks session lifecycle and tool execution. It misses file changes, LSP diagnostics, and task progress that could provide richer status information.
