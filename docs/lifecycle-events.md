# Agent Lifecycle Events Reference

This document describes the lifecycle events for each agent type supported by Séance, what each framework CAN emit (from upstream docs), what Séance currently handles, and the gaps between them.

## Table of Contents

- [Overview](#overview)
- [Agent Types](#agent-types)
- [Plugin Versions](#plugin-versions)
- [Upstream Framework Events](#upstream-framework-events)
  - [OpenCode/Kilo Code Events](#opencodekilo-code-events)
  - [Claude Code Events](#claude-code-events)
  - [MiMoCode Events](#mimocode-events)
- [Séance Hook Events](#seance-hook-events)
- [Status Tracking](#status-tracking)
- [Event Handling Gaps](#event-handling-gaps)
- [Deltas and Drift](#deltas-and-drift)

## Overview

Séance integrates with multiple AI coding agents through plugins that subscribe to agent framework events and translate them into Séance hooks. These hooks update the workspace status panel with real-time information about agent activity.

**Architecture Flow:**

```
Agent Framework → Plugin (TypeScript) → Séance Hook → Socket API → Workspace Metadata → Sidebar UI
```

## Agent Types

| Agent | Plugin File | Status Key Prefix | Status Mode |
|-------|-------------|-------------------|-------------|
| **OpenCode** | `plugins/seance-opencode/index.ts` | `opencode` | surface |
| **Kilo Code** | `plugins/seance-kilo/index.ts` | `kilo` | surface |
| **MiMoCode** | `plugins/seance-mimocode/index.ts` | `mimocode` | surface |
| **Claude Code** | (built-in) | `claude` | session |
| **Codex CLI** | (built-in) | `codex` | surface |
| **Pi Agent** | (built-in) | `pi` | surface |
| **Mistral Vibe** | (built-in) | `vibe` | surface |
| **Hermes Agent** | (built-in) | `hermes` | surface |

## Plugin Versions

The following plugin versions have been documented in this reference:

| Agent | Plugin Version | Last Verified |
|-------|----------------|---------------|
| OpenCode | @seance-version 6 | 2026-07-21 |
| Kilo Code | @seance-version 6 | 2026-07-21 |
| MiMoCode | @seance-version 37 | 2026-07-21 |

---

## Upstream Framework Events

These are ALL events that each framework CAN emit, as documented in their official documentation. Séance may not handle all of them.

### OpenCode/Kilo Code Events

**Source:** [opencode.ai/docs/plugins](https://opencode.ai/docs/plugins) and [kilo.ai/docs/automate/extending/plugins](https://kilo.ai/docs/automate/extending/plugins)

OpenCode and Kilo Code share the same event system (Kilo is a fork of OpenCode).

#### Session Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `session.created` | New session created | Yes |
| `session.updated` | Session state changed | Yes |
| `session.idle` | Session became idle | Yes |
| `session.error` | Session error occurred | Yes |
| `session.status` | Session status changed (busy/idle) | Yes |
| `session.deleted` | Session was deleted | **No** |
| `session.compacted` | Session context was compacted | **No** |
| `session.diff` | Session diff available | **No** |

#### Message Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `message.updated` | Message content updated | **No** |
| `message.removed` | Message removed | **No** |
| `message.part.updated` | Message part updated | **No** |
| `message.part.removed` | Message part removed | **No** |

#### Tool Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `tool.execute.before` | Before tool execution | Yes |
| `tool.execute.after` | After tool execution | Yes |

#### Permission Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `permission.asked` | Permission request | Yes |
| `permission.replied` | Permission response | Yes |

#### File Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `file.edited` | File was edited | **No** |
| `file.watcher.updated` | File changed on disk | **No** |

#### LSP Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `lsp.updated` | LSP connection state changed | **No** |
| `lsp.client.diagnostics` | LSP diagnostics received | **No** |

#### Other Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `command.executed` | Slash command executed | **No** |
| `shell.env` | Shell environment injection | **No** |
| `todo.updated` | Todo list changed | **No** |
| `server.connected` | Server connection established | **No** |
| `installation.updated` | Installation state changed | **No** |

#### TUI Events (Kilo Code only)

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `tui.prompt.append` | Append to prompt | **No** |
| `tui.command.execute` | TUI command executed | **No** |
| `tui.toast.show` | Show toast notification | **No** |

#### Actor/Subagent Events (MiMoCode extension)

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `actor.registered` | New actor/subagent registered | Yes (MiMoCode only) |
| `actor.status` | Actor status changed | Yes (MiMoCode only) |

**Important:** These events are MiMoCode-specific extensions and are NOT available in standard OpenCode or Kilo Code. OpenCode/Kilo plugins should use `session.updated` with `parentID` tracking for subagent detection instead.

---

### Claude Code Events

**Source:** [docs.anthropic.com/en/docs/claude-code/hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)

Claude Code has a comprehensive hook system with many more event types than the OpenCode/Kilo family.

#### Session Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `SessionStart` | Session begins or resumes | Yes (`session-start`) |
| `SessionEnd` | Session terminates | Yes (`session-end`) |

#### Turn Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `UserPromptSubmit` | User submits a prompt | Yes (`prompt-submit`) |
| `UserPromptExpansion` | Slash command expands to prompt | **No** |
| `Stop` | Claude finishes responding | Yes (`stop`) |
| `StopFailure` | Turn ends due to API error | **No** |

#### Tool Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `PreToolUse` | Before tool call executes | Yes (`pre-tool-use`) |
| `PostToolUse` | After tool call succeeds | Yes (`post-tool-use`) |
| `PostToolUseFailure` | After tool call fails | **No** |
| `PostToolBatch` | After parallel tool batch resolves | **No** |

#### Permission Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `PermissionRequest` | Permission dialog appears | Yes (`notification`) |
| `PermissionDenied` | Tool call denied by auto-mode | **No** |

#### Subagent Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `SubagentStart` | Subagent spawned | **No** |
| `SubagentStop` | Subagent finishes | **No** |

#### Task Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `TaskCreated` | Task created via TaskCreate | **No** |
| `TaskCompleted` | Task marked completed | **No** |

#### Notification Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `Notification` | Claude Code sends notification | Yes (`notification`) |
| `MessageDisplay` | Assistant message text displayed | **No** |

#### Compact Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `PreCompact` | Before context compaction | **No** |
| `PostCompact` | After compaction completes | **No** |

#### Worktree Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `WorktreeCreate` | Worktree being created | **No** |
| `WorktreeRemove` | Worktree being removed | **No** |

#### Teammate Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `TeammateIdle` | Teammate about to go idle | **No** |

#### Config Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `ConfigChange` | Configuration file changed | **No** |
| `InstructionsLoaded` | CLAUDE.md/rules file loaded | **No** |

#### File Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `CwdChanged` | Working directory changed | **No** |
| `FileChanged` | Watched file changed on disk | **No** |

#### Elicitation Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `Elicitation` | MCP server requests user input | **No** |
| `ElicitationResult` | User responds to MCP elicitation | **No** |

#### Setup Events

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `Setup` | Claude Code starts with --init | **No** |

---

### MiMoCode Events

**Source:** [github.com/XiaomiMiMo/MiMo-Code](https://github.com/XiaomiMiMo/MiMo-Code)

MiMoCode is a fork of OpenCode, so it inherits all OpenCode events plus adds its own extensions for subagent management.

#### Inherited from OpenCode

All OpenCode/Kilo Code events listed above.

#### MiMoCode Extensions

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `actor.registered` | New actor/subagent registered | Yes |
| `actor.status` | Actor status changed | Yes |

**Note:** MiMoCode adds actor lifecycle events that are not in the base OpenCode framework. These appear to be custom extensions for the subagent orchestration system.

---

## Séance Hook Events

Plugins translate agent framework events into Séance hooks via the `seance ctl <agent>-hook` command.

### Available Hooks

| Hook | Description | When Triggered |
|------|-------------|----------------|
| `session-start` | Agent session started | `session.created` or `session.updated` (first session) |
| `session-end` | Agent session ended | `session.error` (main session only) |
| `prompt-submit` | User prompt submitted / agent busy | `session.created`, `session.updated` (first), `session.status` (busy) |
| `pre-tool-use` | Tool execution starting | `tool.execute.before` |
| `post-tool-use` | Tool execution completed | `tool.execute.after` |
| `stop` | Agent idle, waiting for input | `session.idle` (main session, no pending permission) |
| `notification` | User notification needed | `permission.asked` |

### Hook Payload Format

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

Séance tracks agent status via the socket API. Here's how each hook updates the workspace metadata:

### Status Updates

| Hook | Séance API Call | Status Key | Status Value |
|------|-----------------|------------|--------------|
| `session-start` | `workspace.set_status` | `{agent}` | `"Working"` |
| `prompt-submit` | `workspace.set_status` | `{agent}` | `"Working"` |
| `pre-tool-use` | `workspace.set_status` | `{agent}` | `"Working"` |
| `post-tool-use` | `workspace.set_status` | `{agent}` | `"Working"` |
| `stop` | `workspace.set_status` | `{agent}` | `"Idle"` |
| `notification` | `workspace.set_status` | `{agent}` | `"Needs input"` |
| `session-end` | `workspace.clear_status` | `{agent}` | (removed) |

### Subagent Count Tracking

Plugins track subagent counts and update via `subagent-update`:

```json
{
  "workspace_id": "string",
  "subagent_count": "number",
  "background_count": 0
}
```

This calls `workspace.set_subagent_counts` to update the sidebar display.

---

## Event Handling Gaps

This section documents events that each framework CAN emit but Séance does NOT currently handle. These represent opportunities for enhanced status visibility.

### OpenCode/Kilo Code — Missing Event Coverage

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.deleted` | Clear status when session is explicitly deleted |
| `session.compacted` | Show compaction indicator in status |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |
| `lsp.client.diagnostics` | Show error/warning counts in status |
| `todo.updated` | Track task completion progress |

**Impact:** Séance currently only tracks session lifecycle and tool execution. It misses file changes, LSP diagnostics, and task progress that could provide richer status information.

### Claude Code — Missing Event Coverage

| Event | Potential Use for Séance |
|-------|--------------------------|
| `SubagentStart` / `SubagentStop` | More accurate subagent count tracking |
| `TaskCreated` / `TaskCompleted` | Show task progress in status |
| `PostToolUseFailure` | Show tool failure indicators |
| `StopFailure` | Show error status on API failures |
| `PreCompact` / `PostCompact` | Show compaction activity |
| `WorktreeCreate` / `WorktreeRemove` | Track worktree activity |
| `TeammateIdle` | Track multi-agent coordination |
| `CwdChanged` | Update directory display |
| `FileChanged` | Track file modifications |
| `UserPromptExpansion` | Track slash command usage |

**Impact:** Claude Code has the richest event system. Séance only uses a small subset, missing opportunities for detailed status reporting like subagent lifecycle, task progress, and error states.

### MiMoCode — Missing Event Coverage

Same as OpenCode/Kilo Code, plus:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session.compacted` | Show compaction indicator |
| `message.updated` | Track conversation progress |
| `file.edited` | Show file modification activity |

**Impact:** MiMoCode inherits OpenCode's events but Séance's plugin doesn't leverage the additional actor events for richer subagent status.

### Codex CLI — Missing Event Coverage

**Source:** [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks)

Codex has a comprehensive hook system similar to Claude Code.

| Event | Potential Use for Séance |
|-------|--------------------------|
| `SessionStart` | Session lifecycle tracking |
| `SubagentStart` / `SubagentStop` | Subagent count tracking |
| `PreToolUse` / `PostToolUse` | Tool execution tracking |
| `PermissionRequest` | Permission request notifications |
| `PreCompact` / `PostCompact` | Compaction activity |
| `UserPromptSubmit` | Prompt submission tracking |
| `Stop` / `StopFailure` | Agent idle/error states |
| `PostToolUseFailure` | Tool failure indicators |

**Impact:** Codex has rich hook support but Séance's built-in integration doesn't leverage most events.

### Pi Agent — Missing Event Coverage

**Source:** [github.com/earendil-works/pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)

Pi Agent has an extensive extension system with many lifecycle events.

| Event | Potential Use for Séance |
|-------|--------------------------|
| `session_start` / `session_shutdown` | Session lifecycle |
| `agent_start` / `agent_end` / `agent_settled` | Agent activity tracking |
| `turn_start` / `turn_end` | Turn-level tracking |
| `tool_call` / `tool_result` | Tool execution |
| `tool_execution_start` / `tool_execution_end` | Tool lifecycle |
| `message_start` / `message_end` | Message tracking |
| `context` | Context modification |
| `before_provider_request` | Provider request tracking |
| `model_select` | Model changes |
| `input` | User input handling |

**Impact:** Pi Agent has the most granular event system of all agents. Séance's built-in integration is minimal.

### Mistral Vibe — Missing Event Coverage

**Source:** [github.com/mistralai/mistral-vibe](https://github.com/mistralai/mistral-vibe/blob/main/README.md)

Vibe has a simpler hook system focused on tool execution.

| Event | Potential Use for Séance |
|-------|--------------------------|
| `pre_tool` | Tool execution tracking |
| `post_tool` | Tool completion tracking |
| `post_agent` | Agent turn completion |

**Impact:** Vibe has limited hook support compared to other agents. Séance's built-in integration covers the basics.

### Hermes Agent — Missing Event Coverage

**Source:** [hermes-agent.nousresearch.com/docs/user-guide/features/hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks)

Hermes has multiple hook systems: gateway hooks, plugin hooks, and shell hooks.

| Event | Potential Use for Séance |
|-------|--------------------------|
| `agent:start` / `agent:end` | Agent activity tracking |
| `agent:step` | Step-level tracking |
| `session:start` / `session:end` | Session lifecycle |
| `pre_tool_call` / `post_tool_call` | Tool execution |
| `pre_llm_call` / `post_llm_call` | LLM call tracking |
| `on_session_start` / `on_session_end` | Session events |
| `subagent_start` / `subagent_stop` | Subagent lifecycle |
| `pre_approval_request` / `post_approval_response` | Approval tracking |

**Impact:** Hermes has comprehensive hook support. Séance's built-in integration uses custom `approval-request` instead of standard hooks.

---

## Deltas and Drift

### Critical Differences Between Plugins

#### 1. Status Key Mode (Claude vs Others)

**Issue:** Claude uses `session` mode for status keys, while all other agents use `surface` mode.

**Impact:** Claude's status is shared across all surfaces in a workspace, while other agents have per-surface status.

**Configuration:**
```zig
const claude_agent = AgentConfig{
  .status_key_mode = .session,  // Status shared across workspace
};

const opencode_agent = AgentConfig{
  .status_key_mode = .surface,  // Status per-surface
};
```

#### 2. Notification Support

**Issue:** Claude, OpenCode, Kilo, and MiMoCode support the `notification` hook. Codex, Pi, and Vibe do not. Hermes uses custom `approval-request` instead.

**Impact:** Users won't see permission requests in the status panel for agents without notification support.

**Matrix:**
| Agent | Notification Support |
|-------|---------------------|
| Claude | Yes (notification hook) |
| Codex | No |
| Pi | No |
| OpenCode | Yes (notification hook) |
| Kilo | Yes (notification hook) |
| MiMoCode | Yes (notification hook) |
| Vibe | No |
| Hermes | Custom (approval-request) |

#### 3. Status Clearing on Session End

**Issue:** Most agents clear status on `session-end`, but Hermes does not (uses `llm-complete` for idle detection).

**Impact:** Hermes maintains status between turns, while others clear it.

**Matrix:**
| Agent | clear_status_on_end |
|-------|---------------------|
| Claude | Yes |
| Codex | Yes |
| Pi | Yes |
| OpenCode | Yes |
| Kilo | Yes |
| MiMoCode | Yes |
| Vibe | Yes |
| Hermes | No |

---

