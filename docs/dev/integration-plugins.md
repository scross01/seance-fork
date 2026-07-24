# Plugin-Based Integration

Plugin-based integrations use the agent's native plugin system to subscribe to lifecycle events and forward them to Séance. This is the most common integration approach for agents with rich plugin ecosystems.

## How It Works

1. Séance auto-installs a plugin to the agent's config directory on startup
2. The agent process loads the plugin and exposes its event system
3. The plugin subscribes to lifecycle events (session created, tool executed, permission requested, etc.)
4. Each event is translated to a Séance hook command via `seance ctl <agent>-hook <event>`
5. The hook payload (JSON) is piped via stdin to the running Séance instance

## Plugin Types

### TypeScript Plugins

Used by: **OpenCode**, **Kilo Code**, **MiMo Code**

TypeScript plugins are the most common approach. The plugin is a `.ts` file that exports a `SeancePlugin` async function receiving `$` (shell executor). It subscribes to the agent's event system and sends hooks via subprocess calls.

**Install locations:**

| Agent | Install Target | Source |
|-------|----------------|--------|
| OpenCode | `~/.config/opencode/plugins/seance-opencode.ts` | `plugins/seance-opencode/index.ts` |
| Kilo Code | `~/.config/kilo/plugins/seance-kilo.ts` | `plugins/seance-kilo/index.ts` |
| MiMo Code | `~/.config/mimocode/plugins/seance-mimocode.ts` | `plugins/seance-mimocode/index.ts` |

**Version tracking:** Each plugin embeds a version comment:
```typescript
// @seance-version 13
```

This version is extracted by `extractVersion()` in `src/app.zig` and compared against the installed version. If the bundled version is newer, the plugin is reinstalled.

### Python Plugins

Used by: **Hermes Agent**

Python plugins are used when the agent's plugin callbacks fire from a shared core that covers multiple surfaces (CLI, TUI, gateway, desktop).

**Install location:** `~/.hermes/plugins/seance/` directory with:
- `plugin.yaml` — manifest with `name`, `version`, `hooks:` list
- `__init__.py` — exposes `def register(ctx)` that calls `ctx.register_hook(event, callback)`

**Why Python:** Hermes's plugin callbacks fire from the shared core, covering CLI, TUI, gateway, desktop, and dashboard surfaces. An earlier shell-hooks design only worked on the CLI surface because the TUI backend never called `register_from_config`.

## Event Flow

```
Agent Framework → Plugin → seance ctl <agent>-hook → Socket API → Workspace Metadata → Sidebar UI
```

1. The agent framework fires a lifecycle event
2. The plugin receives the event and translates it to a Séance hook command
3. The plugin runs `seance ctl <agent>-hook <event>` as a subprocess, passing JSON via stdin
4. `ctl.zig` receives the command over the Unix socket, updates workspace metadata
5. The sidebar UI reflects the updated status

## Auto-Install Mechanism

Plugins are auto-installed on Séance startup:

1. **Check if agent is installed** — verify the config directory exists
2. **Read bundled plugin** — from `{prefix}/share/seance/{name}-plugin.ts`
3. **Compare version and content** — extract `@seance-version` from bundled and installed plugins
4. **Write atomically** — if outdated or missing, write to a `.tmp` file then rename (atomic replace)

For Python plugins (Hermes), the mechanism installs a directory with `plugin.yaml` and `__init__.py`.

## Advantages

- **Rich event data** — plugins receive structured event objects with session IDs, tool names, and other metadata
- **Reliable** — events are fired by the agent framework itself, not inferred from file changes
- **Real-time** — events fire immediately when they occur
- **Full lifecycle coverage** — can track sessions, tools, permissions, and more

## Limitations

- **Agent-specific** — each agent has its own plugin API; plugins can't be shared across agents
- **Maintenance burden** — plugins must be updated when the agent's API changes
- **Installation complexity** — requires writing to the agent's config directory

## Adding a New Plugin-Based Integration

To add support for a new agent with a TypeScript plugin:

1. Create `plugins/seance-{name}/index.ts` — copy from an existing plugin
2. Create `resources/bin/{binary-name}` — wrapper script for PID tracking
3. Add `AgentConfig` in `src/ctl.zig` — define the agent's config struct
4. Add dispatch in `src/ctl.zig` — `if (eql(command, "{name}-hook"))`
5. Add auto-install in `src/app.zig` — `install{Name}Plugin()` function
6. Add config toggle in `src/config.zig` — `{name}_hooks: bool = true`
7. Add settings UI in `src/settings.zig` — toggle widget
8. Add build integration in `build.zig` — install plugin to `share/seance/`
