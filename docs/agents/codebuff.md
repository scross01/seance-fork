# Codebuff Integration

Séance integrates with [Codebuff](https://codebuff.com) through session log monitoring using `inotifywait`. Codebuff doesn't have a native hook system, so Séance watches for file changes in its session log directory to detect agent activity.

## How It Works

1. **Wrapper script** intercepts `codebuff` launches inside Séance terminals
2. **Background monitor** watches the Codebuff session log directory for `.jsonl` file changes using `inotifywait`
3. **Activity detection** — when files are modified, status changes to "Running"
4. **Idle detection** — when no activity for 5 seconds, status changes to "Idle"
5. **Session end** — wrapper fires `session-end` on exit via trap

## Status Detection

| State | How Detected |
|-------|--------------|
| **Running** | `inotifywait` detects file modification in session log directory |
| **Idle** | No file modifications for 5 seconds (timeout) |
| **Needs input** | Not supported — shows "Running" instead |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Session tracking** — tracks session lifecycle from start to end

## Requirements

- **`inotify-tools`** must be installed: `sudo apt install inotify-tools` (Ubuntu/Debian) or `sudo pacman -S inotify-tools` (Arch)

## Configuration

Toggle integration on or off in `config.toml`:

```toml
codebuff-hooks = true
```

## Limitations

- **Heuristic-based** — activity detection is based on file modification, not actual agent state. A file write doesn't necessarily mean the agent is "working".
- **Latency** — there's a 5-second idle timeout before status changes from "Running" to "Idle".
- **No notification support** — Codebuff doesn't emit permission request events.
- **No permission detection** — when Codebuff prompts for permission, the sidebar shows "Running" instead of "Waiting for input".

---

## For Contributors

### Integration Approach

Codebuff uses **session log monitoring** with `inotifywait` — a Linux-specific tool that watches for file system events without polling.

**Why inotifywait:** Codebuff doesn't expose lifecycle events through a plugin API or hook system. The only way to detect activity is by monitoring its session log files.

### How the Monitor Works

The wrapper script starts a background process that:

1. Initializes status to "Running" (matches the initial `prompt-submit` hook)
2. Loops while the parent process is alive (`kill -0 $$`)
3. Waits for `IN_MODIFY` events on `*.jsonl` files in the session log directory
4. On activity: if current status is not "Running", sends `prompt-submit` hook
5. On timeout (5 seconds): if current status is "Running", sends `stop` hook
6. Cleans up temp state file on exit

### Event Mapping

| Trigger | Seance Hook | UI Status |
|---|---|---|
| Session start | `prompt-submit` | Running |
| File modification detected | `prompt-submit` | Running |
| No activity for 5s | `stop` | Idle |
| Process exit | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `codebuff`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `codebuff-hooks = true` in `config.toml`.
- **File pattern:** `*.jsonl`
- **Idle timeout:** 5 seconds
