# Codex CLI Integration

Séance integrates with [OpenAI Codex CLI](https://github.com/openai/codex) through built-in wrapper scripts and native hook support.

## How It Works

1. **Wrapper script** intercepts `codex` launches inside Séance terminals
2. **Built-in integration** handles lifecycle events without requiring a plugin
3. **Status tracking** updates the sidebar with real-time agent state

## Hook Events

| Codex Event | Séance Hook | What It Shows |
|-------------|-------------|---------------|
| `SessionStart` | `session-start` | Running |
| `UserPromptSubmit` | `prompt-submit` | Running |
| `PreToolUse` | `pre-tool-use` | Running |
| `PostToolUse` | `post-tool-use` | Running |
| `Stop` | `stop` | Idle |
| `SessionEnd` | `session-end` | (cleared) |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Session tracking** — tracks session lifecycle from start to end
- **Desktop notifications** — notifies on completion events

## Configuration

Toggle integration on or off in `config.toml`:

```toml
codex-hooks = true
```

## Limitations

- **No notification support** — Codex doesn't emit permission request events through the hook system Séance uses
- **No permission detection** — when Codex prompts for permission, the sidebar shows "Running" instead of "Waiting for Permission"
- **No subagent tracking** — Codex doesn't expose subagent lifecycle events to Séance

---

## For Contributors

### Integration Approach

Codex uses a **built-in integration** — no TypeScript plugin or Python plugin is required. The wrapper script (`resources/bin/codex`) intercepts launches for PID tracking and fires `session-end` on exit.

### Event Mapping

| Codex Event | Seance Hook | UI Status |
|---|---|---|
| `SessionStart` | `session-start` | Running |
| `UserPromptSubmit` | `prompt-submit` | Running |
| `PreToolUse` | `pre-tool-use` | Running |
| `PostToolUse` | `post-tool-use` | Running |
| `Stop` | `stop` | Idle |
| `SessionEnd` | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `codex`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `codex-hooks = true` in `config.toml`.
- **Cache directory:** `~/.cache/seance-codex/` — cleaned up on session end.

### Upstream Framework Events

**Source:** [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks)

Codex has a comprehensive hook system similar to Claude Code:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `SessionStart` | Session begins or resumes | Yes |
| `SessionEnd` | Session terminates | Yes |
| `UserPromptSubmit` | User submits a prompt | Yes |
| `PreToolUse` | Before tool call executes | Yes |
| `PostToolUse` | After tool call succeeds | Yes |
| `Stop` | Agent finishes responding | Yes |
| `SubagentStart` | Subagent spawned | **No** |
| `SubagentStop` | Subagent finishes | **No** |
| `PermissionRequest` | Permission dialog appears | **No** |
| `PreCompact` | Before context compaction | **No** |
| `PostCompact` | After compaction completes | **No** |
| `StopFailure` | Turn ends due to API error | **No** |
| `PostToolUseFailure` | After tool call fails | **No** |

### Missing Event Coverage

Events that Codex can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `SubagentStart` / `SubagentStop` | Subagent count tracking |
| `PermissionRequest` | Permission request notifications |
| `PreCompact` / `PostCompact` | Compaction activity |
| `StopFailure` | Agent idle/error states |
| `PostToolUseFailure` | Tool failure indicators |

**Impact:** Codex has rich hook support but Séance's built-in integration doesn't leverage most events.
