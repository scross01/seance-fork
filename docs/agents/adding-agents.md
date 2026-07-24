# Adding a New Agent

Guide for contributors adding support for a new AI coding agent in Séance.

## Overview

Each agent integration requires these components:

1. **Plugin** — subscribes to agent events and forwards them to Séance
2. **Wrapper script** — intercepts agent launches for PID tracking and cleanup
3. **AgentConfig** — defines how the agent behaves in Séance
4. **Dispatch** — routes hook commands to the right handler
5. **Auto-install** — installs the plugin on Séance startup
6. **Config toggle** — lets users enable/disable integration
7. **Settings UI** — exposes the toggle in the settings window
8. **Build integration** — installs the plugin artifact

## Step 1: Plugin

Create `plugins/seance-{name}/index.ts`. Copy from an existing plugin (e.g., `plugins/seance-opencode/index.ts`) and adjust event handling.

The plugin should:
- Subscribe to the agent's event system
- Translate events to Séance hook commands via `seance ctl {name}-hook <event>`
- Pass `workspace_id` and `surface_id` from environment variables
- Be fail-open — swallow exceptions so a broken Séance never breaks the agent

## Step 2: Wrapper Script

Create `resources/bin/{binary-name}`. Copy from an existing wrapper and adjust:
- Binary name
- PID env var (`SEANCE_{NAME}_PID`)
- Hook command (`{name}-hook`)

The wrapper should:
- Skip hooking if not inside a Séance terminal
- Skip if hooks are disabled or socket is unreachable
- Export the PID env var
- Fire `session-end` on exit (via `trap ... EXIT`)

## Step 3: AgentConfig

In `src/ctl.zig`, define the agent's config struct:

```zig
const my_agent = AgentConfig{
    .status_key_mode = .surface,  // or .session
    .clear_status_on_end = true,
    .has_notification_hook = true,  // or false
};
```

Fields:
- `status_key_mode` — `.session` for shared status across surfaces, `.surface` for per-pane status
- `clear_status_on_end` — whether to clear status when session ends
- `has_notification_hook` — whether the agent supports the `notification` hook

## Step 4: Dispatch

In `src/ctl.zig`, add a dispatch entry:

```zig
if (eql(command, "{name}-hook")) {
    return cmdAgentHook(allocator, stdin, .{name});
}
```

Then implement `cmd{Name}Hook` to handle the agent's specific events (use an existing handler as a template).

## Step 5: Auto-Install

In `src/app.zig`, add plugin installation logic:
- Check if the agent's config directory exists
- Read the bundled plugin from `{prefix}/share/seance/{name}-plugin.ts`
- Compare version and content against installed plugin
- Write atomically via `.tmp` file + rename

## Step 6: Config Toggle

In `src/config.zig`, add:
- `{name}_hooks: bool = true` field
- Save/apply logic for the toggle

## Step 7: Settings UI

In `src/settings.zig`, add a toggle widget and change handler for the new agent.

## Step 8: Build Integration

In `build.zig`, install the plugin to `share/seance/{name}-plugin.ts`.

## Verification

After implementation:
1. Run `zig build test` to verify compilation
2. Install the agent, launch it in a Séance terminal, and verify status updates appear in the sidebar
3. Test notifications and permission detection
4. Test the config toggle (disable and verify hooks stop firing)
