# Built-in Wrapper Integration

Built-in wrapper integrations use wrapper scripts that intercept agent launches and leverage the agent's native hook system to forward lifecycle events to Séance. This approach works for agents with simple, well-defined hook systems that can be handled entirely by the Zig backend.

## How It Works

1. A wrapper script intercepts agent launches inside Séance terminals
2. The wrapper exports `SEANCE_<AGENT>_PID` for process tracking
3. The agent's native hook system calls back to `seance ctl <agent>-hook` directly
4. `ctl.zig` handles the hook commands without needing a plugin

## Wrapper Script Lifecycle

Every wrapper script follows the same pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Find the real binary, skipping seance wrappers
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_AGENT=""
# ... search PATH for the real binary ...

# 2. Pass-through conditions
if [[ -z "${SEANCE_SURFACE_ID:-}" ]]; then
    exec "$REAL_AGENT" "$@"  # Not inside Séance
fi

# 3. Export PID
export SEANCE_<AGENT>_PID=$$

# 4. Session-end cleanup trap
_cleanup() {
    timeout 0.5 "$REAL_SEANCE" ctl <agent>-hook session-end <<'EOF' >/dev/null 2>&1 &
{}
EOF
}
trap _cleanup EXIT

# 5. Set initial "Running" status
seance ctl <agent>-hook prompt-submit <<'EOF' >/dev/null 2>&1 || true
{}
EOF

# 6. Launch agent (no exec — wrapper must survive for cleanup)
"$REAL_AGENT" "$@"
rc=$?
exit $rc
```

## Key Design Decisions

### No Exec

The wrapper uses `"$REAL_AGENT" "$@"` instead of `exec "$REAL_AGENT" "$@"`. This ensures the wrapper process survives to:
- Fire `session-end` on exit via the trap
- Clean up background processes (e.g., inotifywait monitors)
- Handle signals gracefully

### Pass-Through Conditions

The wrapper passes through to the real binary if:
- `SEANCE_SURFACE_ID` is not set (not running inside Séance)
- `SEANCE_<AGENT>_HOOKS_DISABLED` is set to `1`
- The Séance socket is unreachable (health check with 0.75s timeout)
- The subcommand is a config/login/management command that doesn't need tracking

### PID Export

The wrapper exports `SEANCE_<AGENT>_PID=$$` so Séance can track the agent's process. This PID is used for:
- Process lifecycle monitoring
- Cache cleanup on session end
- Parent-child relationship tracking

## Supported Agents

| Agent | Wrapper | PID Env Var | Hook Command |
|-------|---------|-------------|--------------|
| Claude Code | `resources/bin/claude` | `SEANCE_CLAUDE_PID` | `claude-hook` |
| Codex | `resources/bin/codex` | `SEANCE_CODEX_PID` | `codex-hook` |
| Pi Agent | `resources/bin/pi` | `SEANCE_PI_PID` | `pi-hook` |

## Why Built-in

These agents have simple, well-defined hook systems that can be handled entirely by the Zig backend. A plugin would add unnecessary complexity — the wrapper script plus `ctl.zig` dispatch is sufficient.

### Codex

Similar to Claude Code's hook system. Supports `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`.

### Pi Agent

Has an extensive extension system with many lifecycle events. Séance's built-in integration handles the core events: `session_start`, `agent_start`, `tool_call`, `tool_result`, `agent_end`, `session_shutdown`.

## Event Flow

```
Agent Launch → Wrapper Interception → PID Export → Agent Native Hooks → seance ctl <agent>-hook → Sidebar UI
```

1. User runs the agent inside a Séance terminal
2. Wrapper script intercepts the launch
3. Wrapper exports PID and sets up cleanup trap
4. Agent starts and fires native hooks during its lifecycle
5. Hooks call `seance ctl <agent>-hook <event>` directly
6. `ctl.zig` receives the command and updates the sidebar

## Advantages

- **No plugin required** — works with agents that have native hook systems
- **Minimal overhead** — just a wrapper script and `ctl.zig` dispatch
- **Reliable** — uses the agent's own hook system, not file monitoring

## Limitations

- **Agent-specific** — each agent's hook system is different; the wrapper must be tailored
- **Limited event data** — native hooks may provide less context than plugins
- **Maintenance burden** — wrapper must be updated if the agent's hook system changes
