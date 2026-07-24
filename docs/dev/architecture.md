# Architecture

This document describes Séance's core architecture, focusing on how agent status tracking works and why.

## Overview

Séance is a GTK4 terminal multiplexer that tracks AI coding agents running inside it. The key innovation is **agent status awareness** — the sidebar shows each agent's current state (Running, Idle, Needs input) in real time.

## Why Agent Status Tracking?

When running multiple AI coding agents in parallel, it's hard to know which ones are actively working, which are idle, and which need your attention. Séance solves this by:

1. **Intercepting agent launches** via wrapper scripts
2. **Subscribing to lifecycle events** via plugins, hooks, or file monitoring
3. **Translating events to status updates** in the sidebar
4. **Sending notifications** when agents need permission or complete tasks

This gives you a unified view of all your agents without switching between terminals.

## Tech Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| UI framework | GTK4 + libadwaita | Native Linux GUI |
| Terminal rendering | libghostty (Ghostty as library) | GPU-accelerated terminal emulation |
| Language | Zig 0.15.2+ | Systems programming |
| IPC | Unix domain socket | Communication between CLI and GUI |
| Agent integration | Plugins, hooks, or inotifywait | Lifecycle event detection |

## Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Séance GUI (GTK4)                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Sidebar  │  │  Panes   │  │ Workspace│  │ Keybinds │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
                           │
                    ┌──────┴──────┐
                    │  Socket API │
                    └──────┬──────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                     Agent Integration                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Plugin  │  │  Hooks   │  │ Wrapper  │  │inotifywait│   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
                           │
                    ┌──────┴──────┐
                    │   Agents    │
                    │ Claude, Codex, OpenCode, etc. │
                    └─────────────┘
```

## Agent Status Tracking

### Status States

| State | Meaning | Icon |
|-------|---------|------|
| **Running** | Agent is processing a prompt or running a tool | `camera-flash-symbolic` |
| **Idle** | Agent finished its turn, waiting for input | `pause-symbolic` |
| **Needs input** | Agent is waiting for permission or user input | `bell-outline-symbolic` |

### Status Scope

- **Session-level** (Claude Code only): Status is shared across all surfaces in a workspace. Two Claude Code sessions in the same workspace show whichever updated last.
- **Per-surface** (all other agents): Each terminal pane tracks its own agent state independently.

### How Status Updates Flow

1. Agent fires a lifecycle event (session started, tool executed, etc.)
2. Integration layer (plugin/hook/monitor) captures the event
3. Integration calls `seance ctl <agent>-hook <event>` with JSON payload
4. `ctl.zig` receives the command over Unix socket
5. `workspace.set_status()` updates the agent's status
6. Sidebar UI reflects the updated status in real time

### Subagent Tracking

Some agents (MiMo Code) can spawn subagents. Séance tracks these separately:

1. Plugin detects subagent via `actor.registered` event or session ID mismatch
2. Plugin sends `subagent-update` with counts
3. Sidebar shows activity indicators based on subagent state

| Subtasks Active | Background Active | Icon |
|-----------------|-------------------|------|
| No | No | Normal |
| Yes | No | `system-run-symbolic` |
| No | Yes | `media-playback-start-symbolic` |
| Yes | Yes | `system-run-symbolic` (subtasks take precedence) |

## Sidebar Status Display

The sidebar shows each workspace with up to 8 sections:

| Section | Content | Source |
|---------|---------|--------|
| Workspace name | Editable title | User input |
| Notifications | Unread count | Agent hooks |
| Status pills | Agent status (Running/Idle/Needs input) | Agent hooks |
| Latest log | Most recent log entry | Agent hooks |
| Progress bar | Task completion percentage | Agent hooks |
| Git branch + directory | Current branch and cwd | Shell integration |
| Listening ports | TCP ports in use | Port scanner (`/proc/net/tcp`) |
| Column dots | Column position indicator | Internal |

For details on extending the status system, see [Status System](./status-system.md).

## Pane Hierarchy

```
Window
  └── Workspace (horizontal strip you scroll through)
       └── Column (vertical stack)
            └── PaneGroup
                 └── Pane (individual terminal)
```

- **Windows** contain multiple workspaces as tabs in a sidebar
- **Workspaces** are horizontal strips of columns you scroll through (niri-inspired)
- **Columns** are vertical stacks; each has an animated width and can be stacked or tabbed
- **Panes** are individual terminal instances, each with its own PTY

## Socket IPC

`seance ctl` communicates with the running instance over a Unix domain socket. Every GUI action has a CLI equivalent:

```bash
seance ctl ping                    # Health check
seance ctl tree                    # Full hierarchy
seance ctl split                   # Create new pane
seance ctl send "command\n"        # Send input to a pane
seance ctl read-screen --lines 50  # Read terminal output
```

All commands support JSON output via `--json`.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/main.zig` | Entry point, environment setup |
| `src/app.zig` | GTK application initialization, plugin auto-install |
| `src/ghostty_bridge.zig` | C FFI bridge to libghostty |
| `src/pane.zig` | Terminal pane lifecycle |
| `src/session.zig` | Agent session tracking |
| `src/sidebar.zig` | Agent status display |
| `src/socket_server.zig` | `seance ctl` IPC server |
| `src/ctl.zig` | CLI client and hook dispatch |
| `src/keybinds.zig` | Keyboard shortcuts |
| `src/config.zig` | Configuration management |

## Further Reading

- [Integration Approaches](./integration-plugins.md) — how each integration type works
- [Lifecycle Events](./lifecycle-events.md) — the unified hook system
- [Plugin System](./plugin-system.md) — auto-install and version tracking
- [Building from Source](./building.md) — build instructions and dependencies
