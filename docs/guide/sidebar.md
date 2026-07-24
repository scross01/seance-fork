# Sidebar

The sidebar displays workspace information and agent status in real time. Each workspace shows its current state, including agent activity, git branch, directory, and listening ports.

## Sidebar Sections

Each workspace row in the sidebar contains up to 8 sections:

### 1. Workspace Name

The workspace title, editable via the command palette or `seance ctl rename-workspace`.

### 2. Notifications

Unread notifications for the workspace. Click to view details.

### 3. Status Metadata Pills

Agent status indicators showing what's running in the workspace:

| Status | Meaning | Icon |
|--------|---------|------|
| **Running** | Agent is processing a prompt or running a tool | `camera-flash-symbolic` |
| **Idle** | Agent finished its turn, waiting for input | `pause-symbolic` |
| **Needs input** | Agent is waiting for permission or user input | `bell-outline-symbolic` |

Multiple agents can have independent status in the same workspace. Pills are sorted by priority and can be expanded/collapsed when there are more than 3 entries.

### 4. Latest Log Entry

The most recent log message from agents in the workspace. Logs are cleared when the workspace is closed.

### 5. Progress Bar

A progress indicator when agents report task completion percentage. Shows a labeled progress bar with percentage.

### 6. Git Branch + Directory

Shows the current git branch and working directory of the focused pane:

- **Git branch** — detected from shell integration or by walking up to `.git/HEAD`
- **Directory** — the pane's current working directory
- **Dirty indicator** — shows if there are uncommitted changes

### 7. Listening Ports

TCP ports listening inside the workspace's panes. Detected via `/proc/net/tcp` on Linux, attributed to panes via `SEANCE_PANEL_ID` environment variable.

Ports are scanned every 10 seconds. Standard ports (22, 53, 631, 5353) are excluded from display.

### 8. Column Indicator Dots

Visual indicator showing the number and position of columns in the workspace.

## Status Updates

Agent status updates come from two sources:

### 1. Agent Hooks

When an agent fires a lifecycle event, the plugin/hook calls `seance ctl <agent>-hook <event>`, which updates the workspace metadata:

```bash
# Agent starts working
seance ctl opencode-hook prompt-submit

# Agent finishes
seance ctl opencode-hook stop

# Agent needs permission
seance ctl opencode-hook notification
```

### 2. Shell Integration

The shell integration script reports git branch and dirty status automatically when you change directories or run git commands.

## Notifications

When an agent needs your attention — a permission request, a question, or a completed task — Séance sends a desktop notification. Clicking the notification focuses the relevant terminal.

Notifications are:
- **Focus-suppressed** — don't steal focus when your terminal is active
- **Tracked** — unread count shown in the sidebar
- **Clickable** — click to jump to the relevant pane

## Configuration

Sidebar behavior can be configured in `~/.config/seance/config.toml`:

```toml
# Show agent status pills
show_status = true

# Show git branch and directory
show_branch = true

# Show listening ports
show_ports = true

# Show log entries
show_logs = true

# Show progress bars
show_progress = true
```

Or via the Settings UI: **Settings → Sidebar**.

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Focus sidebar | `Ctrl+Shift+S` |
| Navigate up/down | `Up`/`Down` or `Ctrl+P`/`Ctrl+N` |
| Select workspace | `Enter` |
| Close workspace | `Delete` or `Ctrl+Shift+W` |
