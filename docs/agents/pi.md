# Pi Agent Integration

Séance integrates with [Pi Agent](https://github.com/earendil-works/pi) through built-in wrapper scripts and native hook support.

## How It Works

1. **Wrapper script** intercepts `pi` launches inside Séance terminals
2. **Built-in integration** handles lifecycle events without requiring a plugin
3. **Status tracking** updates the sidebar with real-time agent state

## Hook Events

| Pi Event | Séance Hook | What It Shows |
|----------|-------------|---------------|
| `session_start` | `session-start` | Running |
| `agent_start` | `prompt-submit` | Running |
| `tool_call` | `pre-tool-use` | Running |
| `tool_result` | `post-tool-use` | Running |
| `agent_end` | `stop` | Idle |
| `session_shutdown` | `session-end` | (cleared) |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Session tracking** — tracks session lifecycle from start to end
- **Desktop notifications** — notifies on completion events

## Configuration

Toggle integration on or off in `config.toml`:

```toml
pi-hooks = true
```

## Limitations

- **No notification support** — Pi doesn't emit permission request events through the hook system Séance uses
- **No permission detection** — when Pi prompts for permission, the sidebar shows "Running" instead of "Waiting for Permission"
- **No subagent tracking** — Pi doesn't expose subagent lifecycle events to Séance

---

## For Contributors

### Integration Approach

Pi uses a **built-in integration** — no TypeScript plugin or Python plugin is required. The wrapper script (`resources/bin/pi`) intercepts launches for PID tracking and fires `session-end` on exit.

### Event Mapping

| Pi Event | Seance Hook | UI Status |
|---|---|---|
| `session_start` | `session-start` | Running |
| `agent_start` | `prompt-submit` | Running |
| `tool_call` | `pre-tool-use` | Running |
| `tool_result` | `post-tool-use` | Running |
| `agent_end` | `stop` | Idle |
| `session_shutdown` | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `pi`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `pi-hooks = true` in `config.toml`.
- **Cache directory:** `~/.cache/seance-pi/` — cleaned up on session end.

### Upstream Framework Events

**Source:** [github.com/earendil-works/pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)

Pi Agent has an extensive extension system with many lifecycle events:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `session_start` | Session begins | Yes |
| `session_shutdown` | Session terminates | Yes |
| `agent_start` | Agent starts processing | Yes |
| `agent_end` | Agent finishes processing | Yes |
| `agent_settled` | Agent reaches stable state | **No** |
| `turn_start` | Turn begins | **No** |
| `turn_end` | Turn ends | **No** |
| `tool_call` | Tool call initiated | Yes |
| `tool_result` | Tool call result received | Yes |
| `tool_execution_start` | Tool execution begins | **No** |
| `tool_execution_end` | Tool execution ends | **No** |
| `message_start` | Message begins | **No** |
| `message_end` | Message ends | **No** |
| `context` | Context modification | **No** |
| `before_provider_request` | Provider request about to be made | **No** |
| `model_select` | Model selection changed | **No** |
| `input` | User input handling | **No** |

### Missing Event Coverage

Events that Pi Agent can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `agent_settled` | Track agent stability |
| `turn_start` / `turn_end` | Turn-level tracking |
| `tool_execution_start` / `tool_execution_end` | Tool lifecycle tracking |
| `message_start` / `message_end` | Message tracking |
| `context` | Context modification tracking |
| `before_provider_request` | Provider request tracking |
| `model_select` | Model changes tracking |

**Impact:** Pi Agent has the most granular event system of all agents. Séance's built-in integration is minimal.
