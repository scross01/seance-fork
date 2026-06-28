# MiMo Code Integration

How Séance integrates with [MiMo Code](https://github.com/XiaoMi/mimo-code), and what was different from the other agent integrations.

## Overview

MiMo Code integration follows the same architecture as all Séance agent integrations:

1. **Plugin** (`plugins/seance-mimocode/index.ts`) — runs inside MiMo Code's process, hooks into its event system, and forwards lifecycle events to Séance via `seance ctl mimocode-hook`.
2. **Launch wrapper** (`resources/bin/mimo`) — intercepts `mimo` invocations inside Séance terminals, exports the PID for process tracking, and ensures `session-end` fires on crash or forced exit.
3. **Zig backend** (`src/ctl.zig`, `src/app.zig`, `src/config.zig`, `src/pane.zig`) — handles the hook commands, auto-installs the plugin, and wires up the config toggle.

## What was different from Kilo/OpenCode

The Kilo and OpenCode plugins are nearly identical to each other. MiMo Code required one significant change: **dual session tracking**.

### The problem: concurrent sessions

Kilo and OpenCode fire events from a single session at a time. MiMo Code can fire events from **multiple concurrent sessions** — for example, a background indexing session and a foreground user session running simultaneously.

In Kilo/OpenCode, every event is assumed to belong to `currentSessionId`. If a `session.idle` or `session.status` event arrives with a different session ID, it's either ignored or misattributed.

MiMo Code's events carry a `sessionID` in `event.properties`. When a `session.status` event arrives with a session ID that doesn't match `currentSessionId`, the plugin needs to decide:

- Is this from the known session? Forward it.
- Is this from an unknown background session? Track it as `statusSessionId` so we don't misattribute it to the foreground session.

### How the plugin handles it

```typescript
let currentSessionId: string | undefined;   // the "real" session (from session.created)
let statusSessionId: string | undefined;    // a secondary session we've seen status events from
```

- **`session.created`**: Always sets `currentSessionId`. If one was already set, fires `session-end` first (cleanup).
- **`session.status`**: If the event's `sessionID` differs from `currentSessionId` and we haven't seen a secondary session yet, we track it as `statusSessionId`. Events from either session are forwarded.
- **`session.idle` / `session.error`**: Only fire if the event belongs to `currentSessionId` or `statusSessionId`. Unknown sessions are ignored.
- **`session.error`**: Clears both `currentSessionId` and `statusSessionId`.

This prevents background sessions from accidentally cancelling the foreground session's status in Séance's sidebar.

### Comparison table

| Feature | Kilo / OpenCode | MiMo Code |
|---|---|---|
| Session tracking | Single `currentSessionId` | Dual: `currentSessionId` + `statusSessionId` |
| `session.idle` filter | Always fires | Only fires for known sessions |
| `session.error` filter | Always fires | Only fires for known sessions |
| `session.status` filter | Always fires (busy only) | Only fires for known sessions; idle also fires `stop` |
| `statusSessionId` reset | N/A | Cleared on `session.error` |
| `@seance-version` | 2 | 9 |

### The `session.status` idle handling

Kilo/OpenCode only map `session.status` busy events to `prompt-submit`. MiMo Code also maps **idle** status to `stop`:

```typescript
if (event.properties.status.type === "busy") {
  await hook("prompt-submit");
} else if (event.properties.status.type === "idle") {
  await hook("stop");
}
```

This is because MiMo Code emits explicit idle status transitions rather than relying on `session.idle` as the sole signal for completion.

## The `session_dir_env` difference

MiMo Code sets `session_dir_env = null` in the `AgentConfig`, unlike Kilo and OpenCode which set it to `SEANCE_KILO_SESSION_DIR` / `SEANCE_OPENCODE_SESSION_DIR`. MiMo Code doesn't expose a session directory through environment variables — the session is managed entirely through the plugin's in-memory state.

## The wrapper script

The `resources/bin/mimo` wrapper is structurally identical to the Kilo and OpenCode wrappers. The only differences are the binary name (`mimo`), the PID env var (`SEANCE_MIMOCODE_PID`), and the hook command (`mimocode-hook`).

The wrapper always fires `session-end` on exit as a safety net, since MiMo Code's plugin may not reliably fire it on crash or forced termination.

## The env_vars overflow

When adding MiMo Code, the `env_vars` array in `src/pane.zig` was declared as `[18]` — exactly enough for the existing 6 unconditional + 12 conditional entries. Adding the `SEANCE_MIMOCODE_HOOKS_DISABLED` conditional entry bumped the maximum possible count to 19, creating a potential buffer overflow.

This was fixed by:
1. Replacing the magic `18` with a named constant `max_env_vars = 24`.
2. Adding a bounds check before passing the array to ghostty, with a clear error message if exceeded.

This pattern is fragile — every new agent adds a conditional entry. The named constant + bounds check ensures future additions fail loudly rather than silently overflowing.

## Auto-install

The Zig backend auto-installs the MiMo Code plugin on startup if `~/.config/mimocode` exists. It follows the same pattern as Kilo:

1. Check if the config directory exists (MiMo Code is installed).
2. Read the bundled plugin from `{prefix}/share/seance/mimocode-plugin.ts`.
3. Compare version and content against the installed plugin at `~/.config/mimocode/plugins/seance-mimocode.ts`.
4. If outdated or missing, write atomically via a `.tmp` file + rename.

The plugin version is embedded as `@seance-version 9` in the TypeScript source and extracted by `extractVersion()` in `app.zig`.

## Adding a new agent

To add a new agent integration, you need:

1. **Plugin** in `plugins/seance-{name}/index.ts` — copy from an existing plugin, adjust event handling.
2. **Launch wrapper** in `resources/bin/{binary-name}` — copy from an existing wrapper, adjust binary name, PID env var, and hook command.
3. **AgentConfig** in `src/ctl.zig` — define the agent's config struct and `cmd{Name}Hook` function.
4. **Dispatch** in `src/ctl.zig` — add `if (eql(command, "{name}-hook"))` to the dispatcher.
5. **Plugin install** in `src/app.zig` — add `install{Name}Plugin()` and `ensure{Name}PluginDir()`, call from `onActivate`.
6. **Config** in `src/config.zig` — add `{name}_hooks: bool = true`, plus save/apply logic.
7. **Pane env** in `src/pane.zig` — add `SEANCE_{NAME}_HOOKS_DISABLED` conditional, **and verify `max_env_vars` is still sufficient**.
8. **Settings** in `src/settings.zig` — add the toggle widget and change handler.
9. **Build** in `build.zig` — install the plugin to `share/seance/{name}-plugin.ts`.
