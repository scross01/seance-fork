# Quick Start

This guide walks you through your first session with Séance.

## Launching Séance

Run `seance` from your terminal or click the application icon. You'll see a full-screen GTK4 window with a scrolling pane layout.

## Running Your First Agent

Séance auto-detects supported AI coding agents. Open a pane and start one:

1. Press **Ctrl+Shift+Enter** to open a new column with a terminal pane.
2. Run your agent:

```bash
claude
```

or

```bash
opencode
```

3. The sidebar (right side) shows the agent status immediately — a colored dot indicates whether the agent is **working**, **idle**, or **waiting**.

That's it. Séance tracks the agent lifecycle automatically — no configuration needed.

## Navigating Panes

Séance uses a **scrolling layout** — panes are arranged in a horizontal strip you scroll through.

| Action | Shortcut |
|---|---|
| Focus left pane | `Ctrl+Shift+Left` |
| Focus right pane | `Ctrl+Shift+Right` |
| New column | `Ctrl+Shift+Enter` |
| Close pane | `Ctrl+Shift+X` |
| Move column left/right | `Ctrl+Shift+A` / `Ctrl+Shift+D` |

You can also **scroll** with the mouse wheel or trackpad to move between panes.

## Understanding the Sidebar

The sidebar on the right shows all active agent sessions. Each entry has a status indicator:

- **Running** — the agent is actively processing (green dot)
- **Waiting** — the agent needs your input or permission (yellow dot)
- **Idle** — the agent has finished its task (gray dot)

Click any entry to jump to that pane.

Toggle the sidebar with **Ctrl+Shift+B**.

## Notifications

Séance surfaces important events as desktop notifications:

- **Permission prompts** — when an agent needs approval for a tool call or command
- **Task completions** — when an agent finishes a task
- **Unread indicators** — panes with new activity show an unread badge

Jump to the next unread pane with **Ctrl+Shift+U**.

Open the notification panel with **Ctrl+Shift+I**.

## Workspaces

Workspaces let you organize agents by project or task.

| Action | Shortcut |
|---|---|
| New workspace | `Ctrl+Alt+N` |
| Close workspace | `Ctrl+Alt+W` |
| Switch workspace | `Ctrl+Page Up/Down` |
| Jump to workspace 1-9 | `Alt+1` through `Alt+9` |

## Command Palette

Press **Ctrl+Shift+P** to open the command palette. From here you can access any action — open settings, rename workspaces, toggle layout mode, and more.

## What's Next

- **Configuration** — customize keybindings, appearance, and agent settings
- **Keybindings** — full list of keyboard shortcuts
- **Agent Integrations** — set up specific agents like Claude Code, OpenCode, or Kilo
