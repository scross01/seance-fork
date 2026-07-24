# Session Log Monitoring (inotifywait)

Session log monitoring is used for agents that don't have native hook systems. Instead of intercepting lifecycle events, Séance watches for file changes in the agent's session log directory using `inotifywait` to infer agent activity.

## How It Works

1. A wrapper script intercepts agent launches inside Séance terminals
2. The wrapper starts a background monitor process
3. The monitor watches the agent's session log directory using `inotifywait`
4. When files are modified, the monitor detects activity and reports "Running" status
5. When no activity is detected for a timeout period, the monitor reports "Idle" status
6. The wrapper fires `session-end` on exit via a trap

## The inotifywait Approach

`inotifywait` is a Linux-specific tool that watches for file system events without polling. It uses the kernel's inotify subsystem to efficiently detect file modifications.

### Why inotifywait

Some agents don't expose lifecycle events through a plugin API or hook system. The only way to detect activity is by monitoring their session log files. `inotifywait` provides:
- **Efficient monitoring** — kernel-level event notification, no polling
- **Low overhead** — minimal CPU and memory usage
- **Real-time detection** — events fire immediately when files are modified

### Limitations

- **Heuristic-based** — activity detection is based on file modification, not actual agent state. A file write doesn't necessarily mean the agent is "working".
- **Latency** — there's a built-in idle timeout (typically 5 seconds) before status changes from "Running" to "Idle".
- **Linux-specific** — `inotifywait` is Linux-only. This approach won't work on other platforms.
- **Requires `inotify-tools`** — the package must be installed on the system.

## Monitor Implementation

The background monitor process follows this pattern:

```bash
_start_status_monitor() {
    local log_dir="<agent-log-directory>"
    local file_pattern="<file-pattern>"
    local idle_timeout=5

    (
        local state_file
        state_file=$(mktemp /tmp/<agent>-status-XXXXXX)
        echo "Running" > "$state_file"

        while kill -0 $$ 2>/dev/null; do
            # Wait for IN_MODIFY events with timeout
            if timeout "$idle_timeout" inotifywait -r -q -e modify \
                --include "$file_pattern" "$log_dir" >/dev/null 2>&1; then
                # Activity detected
                local current_status
                current_status=$(cat "$state_file" 2>/dev/null || echo "Idle")
                if [[ "$current_status" != "Running" ]]; then
                    echo "Running" > "$state_file"
                    seance ctl <agent>-hook prompt-submit <<'EOF' >/dev/null 2>&1 || true
{"status":"Running"}
EOF
                fi
            else
                # Timeout — no activity
                local current_status
                current_status=$(cat "$state_file" 2>/dev/null || echo "Idle")
                if [[ "$current_status" == "Running" ]]; then
                    echo "Idle" > "$state_file"
                    seance ctl <agent>-hook stop <<'EOF' >/dev/null 2>&1 || true
{"status":"Idle"}
EOF
                fi
            fi
        done
        rm -f "$state_file"
    ) &
    _STATUS_MONITOR_PID=$!
}
```

### State Machine

| Current State | Event | Action | New State |
|---------------|-------|--------|-----------|
| Idle | File modification | Send `prompt-submit` | Running |
| Running | File modification | (no change) | Running |
| Running | Timeout (5s) | Send `stop` | Idle |
| Idle | Timeout (5s) | (no change) | Idle |

### Cleanup

The monitor process:
1. Runs in a subshell with `&` to detach from the wrapper
2. Stores its PID in `_STATUS_MONITOR_PID`
3. Loops while the parent process is alive (`kill -0 $$`)
4. Cleans up temp state file on exit
5. Is killed by the wrapper's cleanup trap on exit

## Session Log Directories

| Agent | Log Directory | File Pattern |
|-------|---------------|--------------|
| Poolside | `~/.local/state/poolside/trajectories` | `*.ndjson` |
| Codebuff | *(agent-specific)* | `*.jsonl` |
| Freebuff | *(agent-specific)* | `*.jsonl` |

## Supported Agents

| Agent | Wrapper | PID Env Var | Hook Command |
|-------|---------|-------------|--------------|
| Poolside Agent CLI | `resources/bin/pool` | `SEANCE_POOL_PID` | `pool-hook` |
| Codebuff | `resources/bin/codebuff` | `SEANCE_CODEBUFF_PID` | `codebuff-hook` |
| Freebuff | `resources/bin/freebuff` | `SEANCE_FREEBUFF_PID` | `freebuff-hook` |

## Event Flow

```
Agent Launch → Wrapper Interception → Start Monitor → File Changes → inotifywait → Status Updates → Sidebar UI
```

1. User runs the agent inside a Séance terminal
2. Wrapper script intercepts the launch
3. Wrapper starts background monitor process
4. Agent writes to session log files during execution
5. `inotifywait` detects file modifications
6. Monitor sends `prompt-submit` (activity) or `stop` (idle) hooks
7. Sidebar reflects the current status

## Requirements

- **Linux** — `inotifywait` is Linux-specific
- **`inotify-tools`** package — must be installed
  - Ubuntu/Debian: `sudo apt install inotify-tools`
  - Arch: `sudo pacman -S inotify-tools`

## Advantages

- **Works with any agent** — no native hook system required
- **Non-invasive** — doesn't modify agent configuration files
- **Real-time** — detects activity as it happens

## Limitations

- **Heuristic** — file modification doesn't always mean the agent is "working"
- **Latency** — 5-second idle timeout before status changes
- **No permission detection** — can't detect when the agent needs user input
- **No notification support** — can't forward desktop notifications
- **Linux-only** — won't work on macOS or Windows
