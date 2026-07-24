# Status System

This document describes how Séance's status system works and how to extend it.

## Overview

The status system tracks agent activity and displays it in the sidebar. It consists of:

1. **Workspace Metadata** — stores status, logs, progress, and subagent counts
2. **Socket API** — receives status updates from agent integrations
3. **Sidebar UI** — displays status in real time

## Workspace Metadata

Each workspace has a `WorkspaceMetadata` struct that stores:

```zig
pub const WorkspaceMetadata = struct {
    status_entries: [16]StatusEntry = .{0} ** 16,
    status_count: usize = 0,
    log_entries: [8]LogEntry = .{0} ** 8,
    log_count: usize = 0,
    progress: ProgressState = .{},
    subagent_count: u32 = 0,
    background_count: u32 = 0,
};
```

### Status Entries

Each status entry has:
- **key** — agent identifier (e.g., "opencode", "claude")
- **value** — status string (e.g., "Running", "Idle", "Needs input")
- **priority** — sort order (higher = shown first)
- **is_agent** — whether this is an agent status
- **display_name** — human-readable name for the sidebar

### Log Entries

Log entries have:
- **message** — log text
- **level** — log level (info, warning, error)
- **timestamp** — when the log was created

### Progress State

Progress tracking has:
- **active** — whether progress is being tracked
- **value** — progress percentage (0.0 to 1.0)
- **label** — optional label for the progress bar

## Socket API

Status updates are sent via the Unix socket API:

### Set Status

```json
{
  "method": "workspace.set_status",
  "params": {
    "workspace_id": 123,
    "key": "opencode",
    "value": "Running",
    "priority": 5,
    "is_agent": true,
    "display_name": "OpenCode"
  }
}
```

### Clear Status

```json
{
  "method": "workspace.clear_status",
  "params": {
    "workspace_id": 123,
    "key": "opencode"
  }
}
```

### Set Progress

```json
{
  "method": "workspace.set_progress",
  "params": {
    "workspace_id": 123,
    "value": 0.75,
    "label": "Processing..."
  }
}
```

### Append Log

```json
{
  "method": "workspace.append_log",
  "params": {
    "workspace_id": 123,
    "message": "Tool execution completed",
    "level": "info"
  }
}
```

### Update Subagent Counts

```json
{
  "method": "workspace.set_subagent_counts",
  "params": {
    "workspace_id": 123,
    "subagent_count": 3,
    "background_count": 1
  }
}
```

## Status Priority

Status entries are sorted by priority (higher values shown first). Default priorities:

| Priority | Agent Type |
|----------|------------|
| 10 | Permission requests ("Needs input") |
| 5 | Active work ("Running") |
| 0 | Idle state |
| -1 | Background tasks |

## Extending the Status System

### Adding a New Status Key

To add a new status key for your agent:

1. **Choose a key name** — use your agent's name (e.g., "myagent")
2. **Set up the integration** — plugin, hook, or monitor that fires events
3. **Call the API** — send `workspace.set_status` with your key

Example plugin code:
```typescript
// When agent starts working
await hook("prompt-submit", {
  status: "Running",
  display_name: "My Agent"
});

// When agent finishes
await hook("stop", {
  status: "Idle"
});
```

### Adding Progress Tracking

To show a progress bar in the sidebar:

1. **Calculate progress** — determine completion percentage
2. **Call the API** — send `workspace.set_progress`

Example:
```bash
seance ctl myagent-hook progress <<EOF
{"value": 0.75, "label": "Processing 3/4 items"}
EOF
```

### Adding Log Entries

To show log messages in the sidebar:

1. **Format the message** — keep it concise (shown in 1-2 lines)
2. **Call the API** — send `workspace.append_log`

Example:
```bash
seance ctl myagent-hook log <<EOF
{"message": "Completed index rebuild", "level": "info"}
EOF
```

### Adding Subagent Tracking

To track subagents in the sidebar:

1. **Detect subagents** — monitor for subagent spawns/completions
2. **Maintain counts** — track subagent_count and background_count
3. **Call the API** — send `workspace.set_subagent_counts`

The sidebar will automatically show activity indicators based on the counts.

## Sidebar Display Logic

The sidebar renders workspace rows with these sections:

1. **Workspace name** — always shown
2. **Notifications** — shown if unread notifications exist
3. **Status pills** — shown if status_count > 0
   - Sorted by priority (highest first)
   - Limited to 3 visible entries (expandable)
4. **Latest log** — shown if log_count > 0
5. **Progress bar** — shown if progress.active is true
6. **Git branch + directory** — shown if branch or cwd is available
7. **Listening ports** — shown if ports_len > 0
8. **Column dots** — always shown

## Testing

### Unit Tests

Status system tests are in `src/workspace.zig`:

```bash
zig build test -Dtest-filter=WorkspaceMetadata
```

### E2E Tests

Status updates can be tested via the socket API:

```bash
# Set status
seance ctl --json workspace.set_status <<EOF
{"workspace_id": 1, "key": "test", "value": "Running", "priority": 5}
EOF

# Verify status appears in sidebar
seance ctl --json tree
```
