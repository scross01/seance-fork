# Feature Matrix

Comparison of Séance's agent integration capabilities across all supported agents.

## Integration Overview

| Feature | Antigravity CLI | Claude Code | Codebuff | Codex | Freebuff | Hermes Agent | Kilo Code | MiMo Code | Mistral Vibe | OpenCode | Pi Agent | Poolside Agent CLI |
|---------|:----------:|:-----------:|:--------:|:-----:|:--------:|:------------:|:---------:|:---------:|:------------:|:--------:|:--------:|:------------------:|
| Hook mechanism | Status callback | Shell hooks | inotifywait | Built-in | inotifywait | Python plugin | TS plugin | TS plugin | TOML config | TS plugin | Built-in | inotifywait |
| Auto-install | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Notification support | Custom | Yes | No | No | No | Custom | Yes | Yes | No | Yes | No | No |
| AskUser / permission detection | Yes | Yes | No | No | No | Yes | Yes | Yes | No | Yes | No | No |
| Session directory tracking | Yes | Yes | No | No | No | No | Yes | Yes | No | Yes | Yes | No |
| Subagent tracking | No | No | No | No | No | No | Yes | Yes | No | Yes | No | No |
| Status key mode | surface | session | surface | surface | surface | surface | surface | surface | surface | surface | surface | surface |
| clear\_status\_on\_end | Yes | Yes | Yes | Yes | Yes | No | Yes | Yes | Yes | Yes | Yes | Yes |

## Hook Mechanism Details

| Agent | Mechanism | Install target | Bundled artifact |
|-------|-----------|----------------|------------------|
| Antigravity CLI | Status-line callback | `~/.gemini/antigravity-cli/settings.json` | Wrapper script + callback |
| Claude Code | Shell hooks | `~/.claude/settings.json` | Wrapper script only |
| Codebuff | Session log monitoring | *(inotifywait)* | Wrapper script |
| Codex | Built-in wrapper | *(native)* | *(none)* |
| Freebuff | Session log monitoring | *(inotifywait)* | Wrapper script |
| Hermes Agent | Python plugin | `~/.hermes/plugins/seance/` | `hermes-plugin/` |
| Kilo Code | TS plugin | `~/.config/kilo/plugins/` | `kilo-plugin.ts` |
| MiMo Code | TS plugin | `~/.config/mimocode/plugins/` | `mimocode-plugin.ts` |
| Mistral Vibe | TOML config | `~/.vibe/hooks.toml` | `vibe-hooks.toml` |
| OpenCode | TS plugin | `~/.config/opencode/plugins/` | `opencode-plugin.ts` (V1), `opencode-plugin-v2.ts` (V2) |
| Pi Agent | Built-in wrapper | *(native)* | *(none)* |
| Poolside Agent CLI | Session log monitoring | *(inotifywait)* | Wrapper script |

## Status Key Mode

- **session** — Status is shared across all surfaces in a workspace. A single agent status applies globally. Used by Claude Code.
- **surface** — Status is per-surface. Each pane tracks its own agent state independently. Used by all other agents.

## Notification Support

Agents with notification support emit desktop notifications when:

- The agent completes a task (focus-suppressed)
- The agent needs user input (permission request, question)

Agents without native notification support (Codex, Mistral Vibe, Pi Agent) do not forward desktop notifications through Séance.

Hermes Agent achieves notification parity through custom handlers (`llm-complete`, `approval-request`) rather than the standard notification hook.

Antigravity CLI emits its own notifications (permission requests and idle transitions) directly from the status-line callback rather than a hook.

## clear\_status\_on\_end

When `true`, agent status is removed from the sidebar when the session ends. When `false` (Hermes Agent only), status persists after the session ends because the TUI session may outlive individual agent processes.

## Session Directory Tracking

Whether the integration captures the agent session's working directory and uses it in Séance: the directory is stored with the session record (`ctl session list`) and completion notifications read "Completed in `<project>`". It works when a hook payload carries `cwd` — today that is Claude Code's native hook JSON, Pi's injected hook extension, Antigravity's status snapshot, and the plugin payloads of OpenCode, Kilo, and MiMo Code (the plugin process runs inside the pane, so its working directory is the launch directory). Codex, Mistral Vibe, and Hermes Agent do not send `cwd`; the inotifywait monitors have no payload channel.
