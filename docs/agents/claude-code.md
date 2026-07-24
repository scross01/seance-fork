# Claude Code Integration

Séance integrates with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) through wrapper scripts and shell hooks. Claude Code is the only agent that uses session-level status tracking.

## How It Works

Claude Code doesn't use a TypeScript plugin. Instead, Séance:

1. **Intercepts launch** via a wrapper script in `resources/bin/claude-code`
2. **Injects hook commands** into Claude Code's hook system via `~/.claude/settings.json`
3. **Receives events** through the Unix socket as Claude Code runs

## Hook Events

| Claude Code Event | Séance Hook | What It Shows |
|-------------------|-------------|---------------|
| `SessionStart` | `session-start` | Running |
| `UserPromptSubmit` | `prompt-submit` | Running |
| `PreToolUse` | `pre-tool-use` | Running |
| `PostToolUse` | `post-tool-use` | Running |
| `PermissionRequest` | `notification` | Needs input |
| `Notification` | `notification` | Needs input |
| `Stop` | `stop` | Idle |
| `SessionEnd` | `session-end` | (cleared) |

## Features

- **Permission detection** — shows "Waiting for permission" when Claude Code asks to run a command
- **Session tracking** — tracks session lifecycle from start to end
- **Desktop notifications** — notifies on completion and permission requests
- **Focus suppression** — notifications don't steal focus when your terminal is active

## Limitations

- **Session-level status** — Claude Code uses session-level tracking, meaning status is shared across all surfaces in a workspace. If you have two Claude Code sessions in the same workspace, the status panel shows whichever updated last. Other agents (OpenCode, Kilo, MiMo Code) use per-surface tracking, where each terminal has independent status.

- **No subagent tracking** — Claude Code fires `SubagentStart`/`SubagentStop` events, but Séance doesn't handle them yet. The sidebar won't show subagent activity indicators.

---

## For Contributors

### Integration Approach

Claude Code is the only agent that does **not** use a TypeScript/Python plugin. Instead, Séance integrates through two mechanisms:

1. **Wrapper script** (`resources/bin/claude`) — intercepts `claude` launches inside Séance terminals. Discovers the real `claude` binary, exports `SEANCE_CLAUDE_PID`, and fires `session-end` on exit via `trap ... EXIT`.

2. **Shell hooks via `settings.json`** — Séance injects hook commands into `~/.claude/settings.json` (the `hooks` array). Claude Code fires these hooks during its lifecycle, which call back to `seance ctl claude-hook`.

This approach is necessary because Claude Code's hook system is configured via JSON, not a plugin API.

### Event Mapping

| Claude Code Event | Seance Hook | UI Status |
|---|---|---|
| `SessionStart` | `session-start` | Running |
| `UserPromptSubmit` | `prompt-submit` | Running |
| `PreToolUse` | `pre-tool-use` | Running |
| `PostToolUse` | `post-tool-use` | Running |
| `PermissionRequest` | `notification` | Needs input |
| `Notification` | `notification` | Needs input |
| `Stop` | `stop` | Idle |
| `SessionEnd` | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Session-level. Status key prefix `claude`, mode `session`. All other agents use surface-level mode.
- `clear_status_on_end` is `true` — status clears on `session-end`.
- `has_notification_hook` is `true` — notifications fire on permission requests and completions.
- **Auto-install:** Hook injection modifies `~/.claude/settings.json` via the auto-install mechanism in `src/app.zig`.
- **Wrapper script:** `resources/bin/claude`. Passes through if `SEANCE_SURFACE_ID` is not set (not running inside Séance).

### Upstream Framework Events

**Source:** [docs.anthropic.com/en/docs/claude-code/hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)

Claude Code has a comprehensive hook system with many more event types than the OpenCode/Kilo family:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `SessionStart` | Session begins or resumes | Yes |
| `SessionEnd` | Session terminates | Yes |
| `UserPromptSubmit` | User submits a prompt | Yes |
| `UserPromptExpansion` | Slash command expands to prompt | **No** |
| `Stop` | Claude finishes responding | Yes |
| `StopFailure` | Turn ends due to API error | **No** |
| `PreToolUse` | Before tool call executes | Yes |
| `PostToolUse` | After tool call succeeds | Yes |
| `PostToolUseFailure` | After tool call fails | **No** |
| `PostToolBatch` | After parallel tool batch resolves | **No** |
| `PermissionRequest` | Permission dialog appears | Yes |
| `PermissionDenied` | Tool call denied by auto-mode | **No** |
| `SubagentStart` | Subagent spawned | **No** |
| `SubagentStop` | Subagent finishes | **No** |
| `TaskCreated` | Task created via TaskCreate | **No** |
| `TaskCompleted` | Task marked completed | **No** |
| `Notification` | Claude Code sends notification | Yes |
| `MessageDisplay` | Assistant message text displayed | **No** |
| `PreCompact` | Before context compaction | **No** |
| `PostCompact` | After compaction completes | **No** |
| `WorktreeCreate` | Worktree being created | **No** |
| `WorktreeRemove` | Worktree being removed | **No** |
| `TeammateIdle` | Teammate about to go idle | **No** |
| `ConfigChange` | Configuration file changed | **No** |
| `InstructionsLoaded` | CLAUDE.md/rules file loaded | **No** |
| `CwdChanged` | Working directory changed | **No** |
| `FileChanged` | Watched file changed on disk | **No** |
| `Elicitation` | MCP server requests user input | **No** |
| `ElicitationResult` | User responds to MCP elicitation | **No** |
| `Setup` | Claude Code starts with --init | **No** |

### Missing Event Coverage

Events that Claude Code can emit but Séance does not currently handle:

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
