# Lifecycle Events

This document describes Séance's unified lifecycle event system — the hooks that translate agent activity into sidebar status updates.

## Overview

All agent integrations ultimately translate to the same set of Séance hooks. Whether the agent uses a TypeScript plugin, shell hooks, or inotifywait monitoring, the end result is the same: `seance ctl <agent>-hook <event>` commands that update the sidebar.

## Agent Integration Types

| Type | Agents | How Events Are Detected |
|------|--------|------------------------|
| **TypeScript plugin** | OpenCode, Kilo Code, MiMo Code | Plugin subscribes to agent's event system |
| **Python plugin** | Hermes Agent | Plugin registers callbacks with agent's hook system |
| **Shell hooks** | Claude Code | Hooks injected into `~/.claude/settings.json` |
| **TOML config hooks** | Mistral Vibe | Hooks appended to `~/.vibe/hooks.toml` |
| **Built-in wrapper** | Codex, Pi Agent | Agent's native hooks call `seance ctl` directly |
| **Session log monitoring** | Poolside, Codebuff, Freebuff | `inotifywait` watches for file changes |

For detailed documentation on each approach, see:
- [Plugin-Based Integration](./integration-plugins.md)
- [Hook-Based Integration](./integration-hooks.md)
- [Built-in Wrapper Integration](./integration-wrapper.md)
- [Session Log Monitoring](./integration-inotifywait.md)

## Séance Hook Events

All integrations translate to these unified hook commands:

| Hook | Description | Status Effect |
|------|-------------|---------------|
| `session-start` | Agent session started | Running |
| `prompt-submit` | User prompt submitted / agent busy | Running |
| `pre-tool-use` | Tool execution starting | Running |
| `post-tool-use` | Tool execution completed | Running |
| `stop` | Agent idle, waiting for input | Idle |
| `notification` | User notification needed | Needs input |
| `session-end` | Agent session ended | (cleared) |

### Additional Hooks

Some agents have custom hooks beyond the standard set:

| Hook | Agent | Description |
|------|-------|-------------|
| `llm-complete` | Hermes | LLM call finished — sets Idle |
| `approval-request` | Hermes | Permission requested — sets Needs input |
| `approval-response` | Hermes | Permission granted/denied — no-op |
| `interrupt` | Hermes | Session reset via `/reset` or `/new` — sets Idle |

## Hook Payload Format

All hooks receive a JSON payload via stdin:

```json
{
  "session_id": "string | null",
  "workspace_id": "string (env SEANCE_WORKSPACE_ID)",
  "surface_id": "string (env SEANCE_SURFACE_ID)",
  "subagent_count": "number",
  "tool_name": "string (pre/post-tool-use only)",
  "message": "string (notification only)"
}
```

## Status Tracking

### Main Agent Status

The sidebar shows each agent's current state:

| State | Meaning | Triggered By |
|-------|---------|--------------|
| **Running** | Agent is processing | `session-start`, `prompt-submit`, `pre-tool-use`, `post-tool-use` |
| **Idle** | Agent finished, waiting | `stop`, `llm-complete` (Hermes) |
| **Needs input** | Waiting for permission | `notification`, `approval-request` (Hermes) |

### Status Updates

| Hook | Séance API Call | Status Key | Status Value |
|------|-----------------|------------|--------------|
| `session-start` | `workspace.set_status` | `{agent}` | `"Running"` |
| `prompt-submit` | `workspace.set_status` | `{agent}` | `"Running"` |
| `pre-tool-use` | `workspace.set_status` | `{agent}` | `"Running"` |
| `post-tool-use` | `workspace.set_status` | `{agent}` | `"Running"` |
| `stop` | `workspace.set_status` | `{agent}` | `"Idle"` |
| `notification` | `workspace.set_status` | `{agent}` | `"Needs input"` |
| `session-end` | `workspace.clear_status` | `{agent}` | (removed) |

### Status Scope

- **Session-level** (Claude Code only): Status is shared across all surfaces in a workspace. Two Claude Code sessions show whichever updated last.
- **Per-surface** (all other agents): Each terminal pane tracks independently.

### Subagent Tracking

Some agents (MiMo Code) spawn subagents. Séance tracks these via:

1. **Detection:** Plugin detects subagent via `actor.registered` event or session ID mismatch
2. **Counting:** Plugin maintains `subagentCount` and `backgroundCount`
3. **Reporting:** Plugin sends `subagent-update` command with counts
4. **Display:** Sidebar shows activity indicators based on counts

```json
{
  "workspace_id": "string",
  "subagent_count": "number",
  "background_count": 0
}
```

### Activity Indicators

| Subtasks Active | Background Active | Icon | Meaning |
|-----------------|-------------------|------|---------|
| No | No | Normal | Agent running, no subagents |
| Yes | No | `system-run-symbolic` | Subagents actively working |
| No | Yes | `media-playback-start-symbolic` | Background tasks running |
| Yes | Yes | `system-run-symbolic` | Subtasks take precedence |

### Subagent Status Flow

```
Agent spawns subagent
  → Plugin detects via actor.registered or session ID mismatch
  → Plugin increments subagentCount
  → Plugin sends subagent-update
  → Sidebar shows subagent indicator

Subagent completes
  → Plugin detects via actor.status (idle) or session end
  → Plugin decrements subagentCount
  → Plugin sends subagent-update
  → Sidebar updates indicator
```

## Deltas and Drift

### Critical Differences Between Agents

#### 1. Status Key Mode

Claude uses `session` mode; all others use `surface` mode.

```zig
const claude_agent = AgentConfig{
  .status_key_mode = .session,  // Shared across workspace
};

const opencode_agent = AgentConfig{
  .status_key_mode = .surface,  // Per-surface
};
```

#### 2. Notification Support

| Agent | Notification Support |
|-------|---------------------|
| Claude Code | Yes (notification hook) |
| Codebuff | No |
| Codex | No |
| Freebuff | No |
| Hermes Agent | Custom (approval-request) |
| Kilo Code | Yes (notification hook) |
| MiMo Code | Yes (notification hook) |
| Mistral Vibe | No |
| OpenCode | Yes (notification hook) |
| Pi Agent | No |
| Poolside Agent CLI | No |

#### 3. Status Clearing on Session End

Most agents clear status on `session-end`. Hermes does not — it uses `llm-complete` for idle detection because sessions outlive individual agent processes.

| Agent | clear_status_on_end |
|-------|---------------------|
| Claude Code | Yes |
| Codebuff | Yes |
| Codex | Yes |
| Freebuff | Yes |
| Hermes Agent | No |
| Kilo Code | Yes |
| MiMo Code | Yes |
| Mistral Vibe | Yes |
| OpenCode | Yes |
| Pi Agent | Yes |
| Poolside Agent CLI | Yes |
