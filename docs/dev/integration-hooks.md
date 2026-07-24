# Hook-Based Integration

Hook-based integrations use the agent's native hook configuration system to register callbacks that fire during the agent's lifecycle. This approach works when agents support hooks through configuration files rather than plugin APIs.

## How It Works

1. Séance injects hook definitions into the agent's configuration file
2. The agent loads the configuration and registers the hooks
3. When lifecycle events occur, the agent calls the registered hooks
4. The hooks invoke `seance ctl <agent>-hook <event>` with a JSON payload

## Hook Mechanisms

### Shell Hooks (Claude Code)

Used by: **Claude Code**

Claude Code uses a JSON-based hook system configured in `~/.claude/settings.json`. Séance injects hook commands into the `hooks` array.

**How it works:**

1. Séance reads `~/.claude/settings.json`
2. Adds hook entries to the `hooks` array:
   ```json
   {
     "hooks": {
       "SessionStart": [{"type": "command", "command": "seance ctl claude-hook session-start"}],
       "Stop": [{"type": "command", "command": "seance ctl claude-hook stop"}]
     }
   }
   ```
3. Claude Code fires these hooks during its lifecycle
4. Each hook calls back to `seance ctl claude-hook`

**Why JSON:** Claude Code's hook system is configured via JSON, not a plugin API. This is the only way to register lifecycle callbacks without modifying the agent's source code.

### TOML Config Hooks (Mistral Vibe)

Used by: **Mistral Vibe**

Vibe uses a TOML-based hook system configured in `~/.vibe/hooks.toml`. Séance appends hook definitions to this file.

**How it works:**

1. Séance reads `~/.vibe/hooks.toml` (or creates it if missing)
2. Checks for `"Auto-installed by"` marker to avoid duplicate installs
3. Appends hook definitions:
   ```toml
   # Auto-installed by Séance
   [hooks]
   before_tool = "seance ctl vibe-hook pre-tool-use"
   after_tool = "seance ctl vibe-hook post-tool-use"
   post_agent_turn = "seance ctl vibe-hook stop"
   ```
4. Vibe calls these hooks during tool execution and turn completion

**Append strategy:** The install function appends to the file rather than overwriting, preserving any user-authored hooks above the marker.

**Experimental hooks:** Vibe's hooks are experimental. The wrapper script sets `VIBE_ENABLE_EXPERIMENTAL_HOOKS=1`. Without this, hooks silently do nothing.

## Event Flow

```
Agent Configuration → Hook Registration → Agent Event → Hook Callback → seance ctl <agent>-hook → Sidebar UI
```

1. Séance injects hook definitions into the agent's config file
2. The agent loads the config and registers the hooks
3. When a lifecycle event occurs, the agent calls the registered hook
4. The hook invokes `seance ctl <agent>-hook <event>` with JSON payload
5. `ctl.zig` receives the command and updates the sidebar

## Auto-Install Mechanism

### Shell Hooks (Claude Code)

1. Read `~/.claude/settings.json`
2. Parse the `hooks` array
3. Add new hook entries if not present
4. Write back the modified JSON

### TOML Config (Vibe)

1. Check if `~/.vibe/hooks.toml` exists
2. If not, create with Séance hooks
3. If exists, check for `"Auto-installed by"` marker
4. If marker present, already installed — skip
5. If marker missing, append Séance hooks after existing content

## Advantages

- **No plugin required** — works with agents that don't have a plugin API
- **Simple configuration** — just JSON or TOML entries
- **Agent-native** — uses the agent's own hook system, not external tooling

## Limitations

- **Limited event data** — hooks receive less context than plugins (no session objects, just event names)
- **Configuration file modification** — modifies agent config files, which may conflict with user customizations
- **Inferred boundaries** — some agents (Vibe) don't have explicit session start/end hooks, requiring inference

## Agent-Specific Notes

### Claude Code

- **Status mode:** Session-level (shared across workspace surfaces)
- **Notification support:** Yes — hooks fire on permission requests and completions
- **Session directory:** Not exposed

### Mistral Vibe

- **Status mode:** Per-surface
- **Notification support:** No — Vibe has no notification hook type
- **Session boundaries:** Inferred from hook activity and wrapper exit
- **Experimental:** Requires `VIBE_ENABLE_EXPERIMENTAL_HOOKS=1`
