# Hermes Integration

Séance integrates with [Hermes Agent](https://hermes-agent.nousresearch.com) through a Python plugin. Unlike other agents that use TypeScript plugins, Hermes uses a Python-based hook system.

## How It Works

1. **Plugin auto-installs** on Séance startup to `~/.hermes/plugins/seance/`
2. **Plugin registers hooks** with Hermes's callback system, forwarding events to Séance
3. **Wrapper script** intercepts `hermes` launches, tracks PID, and fires `session-end` on exit

## Hook Event Mapping

| Hermes Hook | Fires From | Séance Command | What It Shows |
|-------------|-----------|----------------|---------------|
| `on_session_start` | conversation loop | `session-start` | Running |
| `pre_llm_call` | turn context | `prompt-submit` | Running |
| `pre_tool_call` | model tools | `pre-tool-use` | Running |
| `post_tool_call` | model tools | `post-tool-use` | Running |
| `post_llm_call` | turn finalizer | `llm-complete` | Idle |
| `pre_approval_request` | approval tools | `approval-request` | Needs input |
| `post_approval_response` | approval tools | `approval-response` | (no-op) |
| `on_session_end` | session finalize | `session-end` | (cleared) |
| `on_session_reset` | slash commands | `interrupt` | Idle |

## Features

- **Approval detection** — shows "Pending approval" when Hermes asks for permission to run a command
- **Clarify tool detection** — when Hermes asks a question via its `clarify` tool, Séance shows "Waiting for user input"
- **Interrupt handling** — `/reset` and `/new` slash commands reset stuck "Running" status back to "Idle"
- **Desktop notifications** — notifies on completion and input requests (via Hermes-specific handlers)

## Configuration

Toggle integration on or off in `config.toml`:

```toml
hermes-hooks = true
```

## Limitations

- **No session directory** — Hermes doesn't expose session directory information
- **Interrupt coverage** — a raw Ctrl-C cancel without `/reset` may not reset status, since Hermes doesn't fire a hook for that path
- **TUI session persistence** — in TUI mode, status persists after Hermes exits because the session outlives individual agent processes

---

## For Contributors

### Integration Approach

Hermes uses a **Python plugin** (`~/.hermes/plugins/seance/`) with `plugin.yaml` manifest and `__init__.py` hook registration. The plugin registers callbacks via `ctx.register_hook(event, callback)`, and each callback calls `seance ctl hermes-hook <event>` with a JSON payload.

**Why Python instead of TypeScript:** Hermes's plugin callbacks fire from the shared core, covering CLI, TUI, gateway, desktop, and dashboard surfaces. An earlier shell-hooks design only worked on the CLI surface because the TUI backend never called `register_from_config`.

A wrapper script (`resources/bin/hermes`) intercepts launches for PID tracking and `session-end` on exit.

### Event Mapping

| Hermes Hook | Seance Hook | UI Status |
|---|---|---|
| `on_session_start` | `session-start` | Running |
| `pre_llm_call` | `prompt-submit` | Running |
| `pre_tool_call` | `pre-tool-use` | Running |
| `post_tool_call` | `post-tool-use` | Running |
| `post_llm_call` | `llm-complete` | Idle |
| `pre_approval_request` | `approval-request` | Needs input |
| `post_approval_response` | `approval-response` | (no-op) |
| `on_session_end` | `session-end` | (cleared) |
| `on_session_reset` | `interrupt` | Idle |

**Note:** Hermes uses custom hook types (`llm-complete`, `approval-request`, `approval-response`, `interrupt`) rather than the standard set used by other agents.

### Custom Hook Types

Hermes uses four custom hook types not found in other agents:

| Custom Hook | Purpose |
|---|---|
| `llm-complete` | LLM call finished — sets status to Idle |
| `approval-request` | Permission requested — sets status to Needs input |
| `approval-response` | Permission granted/denied — no-op |
| `interrupt` | Session reset via `/reset` or `/new` — sets status to Idle |

### Clarify Tool Detection

Hermes has a `clarify` tool that asks the user for clarification. The plugin detects when this tool is invoked and shows "Waiting for user input" instead of the generic "Running" status.

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `hermes`, mode `surface`.
- `clear_status_on_end` is `false` — unique among all agents.
- `has_notification_hook` is `true`.
- **Auto-install target:** `~/.hermes/plugins/seance/` directory with `plugin.yaml` + `__init__.py`.

### Why `clear_status_on_end = false`

Hermes sessions outlive individual agent processes. The session continues after the agent exits, so clearing status on `session-end` would incorrectly clear status for a session that may restart. Instead, `llm-complete` is used for idle detection — when the LLM finishes a call, the status goes to Idle regardless of session lifecycle.

### Upstream Framework Events

**Source:** [hermes-agent.nousresearch.com/docs/user-guide/features/hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks)

Hermes has multiple hook systems: gateway hooks, plugin hooks, and shell hooks:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `on_session_start` | Session begins | Yes |
| `on_session_end` | Session terminates | Yes |
| `on_session_reset` | Session reset via `/reset` or `/new` | Yes |
| `pre_llm_call` | Before LLM call | Yes |
| `post_llm_call` | After LLM call | Yes |
| `pre_tool_call` | Before tool call | Yes |
| `post_tool_call` | After tool call | Yes |
| `pre_approval_request` | Permission requested | Yes |
| `post_approval_response` | Permission response | Yes |
| `agent:start` | Agent activity starts | **No** |
| `agent:end` | Agent activity ends | **No** |
| `agent:step` | Agent step completed | **No** |
| `subagent_start` | Subagent spawned | **No** |
| `subagent_stop` | Subagent finishes | **No** |

### Missing Event Coverage

Events that Hermes can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `agent:start` / `agent:end` | Agent activity tracking |
| `agent:step` | Step-level tracking |
| `subagent_start` / `subagent_stop` | Subagent lifecycle tracking |

**Impact:** Hermes has comprehensive hook support. Séance's built-in integration uses custom `approval-request` instead of standard hooks.
