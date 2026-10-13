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
   Running/Needs input/Idle state, while the auto-installed plugin drives the
   lifecycle hooks, `session-end`, the subagent badge, and every desktop
   notification.

Both plugin formats ship: `plugins/seance-opencode/index.ts` for OpenCode V1 and
`plugins/seance-opencode/index-v2.ts` for V2 (installed as
`share/seance/opencode-plugin.ts` / `share/seance/opencode-plugin-v2.ts`). The
wrapper and the GUI auto-installer detect the installed major version via
`opencode --version` and select the matching artifact; any detection failure
(not installed, unparseable output, timeout) keeps the V1 artifacts.

### Inline plugin: V1 takes a file, V2 takes a directory

OpenCode changed the semantics of the `plugins` config key between majors, and
the wrapper injects a different shape accordingly:

- **V1** — `plugins`/`plugin` entries are **file paths**. The wrapper injects
  `share/seance/opencode/seance.mjs`.
- **V2** — `plugins` entries must be **directories**, and only an entrypoint
  named `index.mjs`/`index.ts` inside one is loaded (`plugin.ts`,
  `package.json` `main`, and any sibling file are ignored). The wrapper injects
  the directory `share/seance/opencode/inline/`, which contains exactly one
  file: `index.mjs` (installed from the same `resources/opencode/seance-v2.mjs`).

  > Verified live against OpenCode 2.0.26: a file-shaped entry logs
  > `configured plugin path must be a directory` at location boot and the inline
  > silently never loads; an `index.mjs` entrypoint logs
  > `loading plugin id=<dir> entrypoint=<dir>/index.mjs`.

  Nothing about the plugin's contents changed — only the path shape handed to
  OpenCode. The installed `inline/` directory holds no other files on purpose:
  pointing V2 at `share/seance/opencode/` would also load `seance.mjs`, which
  is V1-format and fails noisily.

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
  session in the window is executing. The status line also carries a
  session-count suffix — `OpenCode: Idle · 2 sessions` — whenever more than
  one session shares the pane, and it repaints the moment a session is
  created or closed rather than waiting for the next activity; a
  single-session window renders no suffix. The subagent badge counts only
  real subagents — sessions created with a `parentID` — not independent
  sessions. **Needs input** status and question/form alerts come from the
  inline plugin, which V2 loads from the `inline/` directory (see below).

  > **One notification per event (V2).** Each alert has exactly one owner.
  > Completions and tool-permission prompts are announced by the
  > auto-installed plugin (`stop` and `notification` hooks); for those same
  > events the inline publishes only the Running/Needs input/Idle *status*.
  > The inline does announce the two things nothing else can: agent questions
  > (forms) and OpenCode errors — the installed plugin's `stop` hook always
  > reports "Completed", so the error notice is what carries the real reason.
  > Both plugins answering the same event is what produced the duplicate
  > desktop alerts, including the extra ones seen with a second session open
  > (the inline fired once per completed session while the installed plugin
  > fired once when the pane went idle).

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
- **V2 plugin paths are directories** — the wrapper's V2 injection only works while `share/seance/opencode/inline/index.mjs` keeps that exact name; renaming it (or adding a second file to `inline/`) silently disables the inline plugin on V2. See "Inline plugin: V1 takes a file, V2 takes a directory"

---

## For Contributors

### Integration Approach

OpenCode uses a **TypeScript plugin** (`plugins/seance-opencode/index.ts`) auto-installed to `~/.config/opencode/plugins/seance-opencode.ts`. A wrapper script (`resources/bin/opencode`) intercepts launches for PID tracking, `session-end` on exit, and injects the inline plugin for the launch.

The plugin exports a `SeancePlugin` async function receiving `$` (shell executor). It subscribes to OpenCode's event system and sends hooks via `seance ctl opencode-hook <event>` subprocess with JSON payload piped via stdin.

**Version:** `@seance-version 17` (V1), `@seance-version 20` (V2)

For OpenCode V2 the plugin lives in `plugins/seance-opencode/index-v2.ts` and
uses V2's plugin API: it exports `Plugin.define({...})`, streams lifecycle
events with `ctx.event.subscribe(...)`, observes tool execution with
`ctx.tool.hook("execute.before"/"execute.after", ...)`, and forwards payloads
to Séance through an `execFile` bridge (`seance ctl opencode-hook <event>`).
The wrapper injects the **inline** plugin — `resources/opencode/seance.mjs` for V1,
`resources/opencode/seance-v2.mjs` for V2 — into the launch with
`seance ctl opencode-config <path>` (merged into the `plugin` config key, V1
takes a **file path**) or `seance ctl opencode-config --v2 <dir>` (merged into
the V2-native `plugins` config key, V2 takes a **directory** whose entrypoint
must be named `index.mjs`/`index.ts`), exported through
`OPENCODE_CONFIG_CONTENT`. The V2 inline is installed as
`share/seance/opencode/inline/index.mjs`; the V1 one as
`share/seance/opencode/seance.mjs`. This is a different file
from the auto-installed `~/.config/opencode/plugins/seance-opencode.ts` above:
the inline plugin aggregates the window's sessions into the pane state, while
the installed one carries the lifecycle hooks, `session-end`, the
subagent-count badge for both majors, and (V2) the session count.

**Verifying that the inline actually loads:** `opencode run` never initializes
the plugin host (verified on 2.0.26 — a full successful turn produces zero hook
calls), so plugin loading must be observed at *location boot*, which happens on
the first authenticated API request:

```bash
sleep 600 | OPENCODE_CONFIG_CONTENT="$CONTENT" OPENCODE_PASSWORD=verify \
  opencode serve --stdio --port 0 &   # keep stdin open; --stdio exits on EOF
curl -u opencode:verify "http://127.0.0.1:<port>/api/plugin"   # boots the location
grep -E 'loading plugin|must be a directory' ~/.local/share/opencode/log/opencode.log
```

Expect `loading plugin id=<inline dir> entrypoint=<inline dir>/index.mjs` and no
`configured plugin path must be a directory` WARN.

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
- **Session count (V2):** every `hook()` payload carries `session_count` — the
  primary session plus the peer sessions, excluding subagent children. `ctl`
  forwards the counts to `workspace.set_status`, which stores them on the
  `StatusEntry` next to the status value; the sidebar composes ` · N sessions`
  and ` (N subagents)` when it paints. Keeping the counts out of the value
  means writers that know nothing about them (`stop`, `notification`, the
  inline `state` hook) leave them intact, and they stay visible while the pane
  is Idle. A peer session appearing or closing also fires `session-update`, a
  counts-only hook served by `workspace.set_status_counts`, so the repaint
  does not wait for the next prompt or tool event — and never invents a status
  value, which would flip an idle pane to Running. Sessions that already
  existed when the pane launched are seeded at plugin setup from
  `client.session.list()` (independent sessions become peers, `parentID` ones
  become subagents), so a pre-populated window counts correctly; the adopting
  primary drops itself from the seeded sets to avoid double-counting, and the
  seed is best-effort (a client without the method simply falls back to the
  event-driven path).

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
