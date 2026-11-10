# Codebuff Integration

Séance integrates with [Codebuff](https://codebuff.com) through session log monitoring using `inotifywait`. Codebuff doesn't have a native hook system, so Séance watches for file changes in its session log directory to detect agent activity.

## How It Works

1. **Wrapper script** intercepts `codebuff` launches inside Séance terminals
2. **Background monitor** resolves *this launch's* `log.jsonl` — the recent log whose records carry the CLI's own process id — then watches that single file with `inotifywait`
3. **Activity detection** — when the owned log grows, status changes to "Running"
4. **Idle detection** — when the owned log stops growing for 5 seconds, status changes to "Idle"
5. **Session end** — wrapper fires `session-end` on exit via trap

## Status Detection

| State | How Detected |
|-------|--------------|
| **Running** | The launch-owned log grows (an appended record) |
| **Idle** | The owned log is unchanged for 5 seconds; also the fallback when no owned log is found |
| **Needs input** | Not supported — shows "Running" instead |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently. Each pane watches only its own launch log, so another Codebuff or Freebuff session writing to the same project tree does not mark it Running.
- **Session tracking** — tracks session lifecycle from start to end

## Requirements

- **`inotify-tools`** must be installed: `sudo apt install inotify-tools` (Ubuntu/Debian) or `sudo pacman -S inotify-tools` (Arch)

## Configuration

Toggle integration on or off in `config.toml`:

```toml
codebuff-hooks = true
```

## Limitations

- **Heuristic-based** — activity is "this launch's log grew", not actual agent state. A write doesn't necessarily mean the agent is "working".
- **Attribution depends on the log schema** — discovery matches the `pid` field Codebuff's JSON records carry. If that field disappears or changes, the monitor falls back to lifecycle-only tracking (Idle, session-end on exit) rather than watching the shared tree.
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
2. Resolves its launch log: recent `log.jsonl` files under the manicode projects tree, matched against the wrapper's descendant PIDs (the npm launcher spawns the real CLI binary as a child), for up to 30 seconds
3. If no log is attributable, publishes "Idle" once and keeps lifecycle-only tracking (`session-end` on exit) instead of watching the shared tree
4. Loops while the parent process is alive (`kill -0 $$`), watching that one file
5. Compares file sizes on each wake: growth is activity, so an idle timeout is not mistaken for a write
6. On growth: if current status is not "Running", sends `prompt-submit`
7. On 5 seconds without growth: if current status is "Running", sends `prompt-submit` with `{"status":"Idle"}`
8. Re-discovers once if the owned log disappears, then stops without attributing global activity
9. Cleans up its state file and watcher on exit, HUP, TERM or INT

### Event Mapping

| Trigger | Seance Hook | UI Status |
|---|---|---|
| Session start | `prompt-submit` | Running |
| Owned log grows | `prompt-submit` | Running |
| No growth for 5s | `prompt-submit` (`{"status":"Idle"}`) | Idle |
| Process exit | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `codebuff`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `codebuff-hooks = true` in `config.toml`.
- **File:** one launch-owned `log.jsonl` (the log's `pid` records must match a wrapper descendant)
- **Idle timeout:** 5 seconds
- **Discovery deadline:** 30 seconds
- **State file:** `mktemp "${TMPDIR:-/tmp}/codebuff-status-XXXXXX"`, removed on exit, HUP, TERM and INT
