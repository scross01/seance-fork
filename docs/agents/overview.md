# Agent Integration Overview

Séance integrates with multiple AI coding agents to show real-time status in the sidebar. Each agent has its own integration mechanism — wrapper scripts, plugins, or config hooks — but they all follow the same core flow.

## How It Works

```
Agent Framework → Plugin/Hook → Séance Hook → Socket API → Sidebar UI
```

1. **Agent runs** inside a Séance terminal. A wrapper script intercepts the launch, tracking the process PID and ensuring cleanup on exit.
2. **Plugin/hook fires events** as the agent works — starting sessions, submitting prompts, using tools, requesting permissions, completing turns.
3. **Séance receives hooks** via a Unix socket. Each hook translates to a status update (Running, Idle, Needs input) and optional notifications.
4. **Sidebar updates** in real time, showing the agent's current state and any pending actions.

## Agent Types

| Agent | Integration Method | Config Toggle | Status Tracking |
|-------|-------------------|---------------|-----------------|
| [Claude Code](./claude-code.md) | Wrapper script + shell hooks | — (always on) | Session-level |
| [Codebuff](./codebuff.md) | Session log monitoring (inotifywait) | `codebuff-hooks` | Per-surface |
| [Codex](./codex.md) | Built-in wrapper | `codex-hooks` | Per-surface |
| [Freebuff](./freebuff.md) | Session log monitoring (inotifywait) | `freebuff-hooks` | Per-surface |
| [Hermes Agent](./hermes.md) | Python plugin | `hermes-hooks` | Per-surface |
| [Kilo Code](./kilo.md) | TypeScript plugin | `kilo-hooks` | Per-surface |
| [MiMo Code](./mimocode.md) | TypeScript plugin | `mimocode-hooks` | Per-surface |
| [Mistral Vibe](./vibe.md) | TOML config hooks | `vibe-hooks` | Per-surface |
| [OpenCode](./opencode.md) | TypeScript plugin | `opencode-hooks` | Per-surface |
| [Pi Agent](./pi.md) | Built-in wrapper | `pi-hooks` | Per-surface |
| [Poolside Agent CLI](./poolside.md) | Session log monitoring (inotifywait) | `pool-hooks` | Per-surface |

**Status tracking** means how status is scoped. Session-level (Claude) shares status across all surfaces in a workspace. Per-surface means each terminal pane has independent status.

## Zero-Config

Most agents work out of the box. Séance auto-installs plugins and wrapper scripts when it detects an agent is installed. You only need to touch config if you want to disable integration for a specific agent.

## Status Indicators

The sidebar shows these states:

| Status | Meaning |
|--------|---------|
| **Running** | Agent is processing a prompt or running a tool |
| **Idle** | Agent finished its turn, waiting for input |
| **Needs input** | Agent is waiting for permission or user input |

## Notifications

When the agent needs your attention — a permission request, a question, or a completed task — Séance sends a desktop notification. Clicking the notification focuses the relevant terminal.

## Further Reading

- [Per-agent guides](./claude-code.md) — detailed integration notes for each agent
- [Adding a new agent](./adding-agents.md) — contributor guide for adding support
- [Lifecycle events reference](../dev/lifecycle-events.md) — full event reference for all agents
