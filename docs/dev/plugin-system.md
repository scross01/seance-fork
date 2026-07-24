# Plugin System

This document describes Séance's auto-install mechanism for agent integrations and version tracking.

## Overview

Séance auto-installs agent integrations on startup. The mechanism varies by integration type:

- **TypeScript plugins** — copied to agent config directories
- **Python plugins** — installed as directories with manifest files
- **Shell hooks** — injected into JSON configuration files
- **TOML config hooks** — appended to TOML configuration files
- **Built-in wrappers** — no installation needed (wrapper scripts in `resources/bin/`)
- **Session log monitors** — no installation needed (wrapper scripts with inotifywait)

For detailed documentation on each integration approach, see:
- [Plugin-Based Integration](./integration-plugins.md)
- [Hook-Based Integration](./integration-hooks.md)
- [Built-in Wrapper Integration](./integration-wrapper.md)
- [Session Log Monitoring](./integration-inotifywait.md)

## Auto-Install Mechanism

### TypeScript Plugins

1. **Check if agent is installed** — verify config directory exists (e.g., `~/.config/opencode/`)
2. **Read bundled plugin** — from `{prefix}/share/seance/{name}-plugin.ts`
3. **Compare version and content** — extract `@seance-version` from bundled and installed plugins
4. **Write atomically** — if outdated or missing, write to a `.tmp` file then rename

### Python Plugins (Hermes)

1. Check if `~/.hermes/` exists
2. Create `~/.hermes/plugins/seance/` directory
3. Write `plugin.yaml` manifest and `__init__.py` hook registration

### Shell Hooks (Claude Code)

1. Read `~/.claude/settings.json`
2. Parse the `hooks` array
3. Add new hook entries if not present
4. Write back the modified JSON

### TOML Config (Vibe)

1. Check if `~/.vibe/hooks.toml` exists
2. If not, create with Séance hooks
3. If exists, check for `"Auto-installed by"` marker
4. If marker present, already installed — skip
5. If marker missing, append Séance hooks after existing content

## Version Tracking

Each TypeScript plugin embeds a version as a comment:

```typescript
// @seance-version 13
```

This version is extracted by `extractVersion()` in `src/app.zig` and compared against the installed version. If the bundled version is newer, the plugin is reinstalled.

Current plugin versions:

| Agent | Plugin Version |
|-------|----------------|
| OpenCode | `@seance-version 13` |
| Kilo Code | `@seance-version 13` |
| MiMo Code | `@seance-version 37` |

## Wrapper Scripts

Every agent integration includes a wrapper script in `resources/bin/` that intercepts agent launches inside Séance terminals. The wrapper:

1. **Discovers the real binary** — skips the wrapper directory to find the actual agent executable
2. **Passes through if not in Séance** — if `SEANCE_SURFACE_ID` is not set, runs the agent directly
3. **Exports PID** — sets `SEANCE_<AGENT>_PID` for process tracking
4. **Launches the agent** — runs as a child process (non-exec)
5. **Fires session-end on exit** — uses `trap ... EXIT` to ensure cleanup even on crash

| Wrapper | Agent | PID Env Var | Hook Command |
|---------|-------|-------------|--------------|
| `resources/bin/claude` | Claude Code | `SEANCE_CLAUDE_PID` | `claude-hook` |
| `resources/bin/codebuff` | Codebuff | `SEANCE_CODEBUFF_PID` | `codebuff-hook` |
| `resources/bin/codex` | Codex | `SEANCE_CODEX_PID` | `codex-hook` |
| `resources/bin/freebuff` | Freebuff | `SEANCE_FREEBUFF_PID` | `freebuff-hook` |
| `resources/bin/hermes` | Hermes Agent | `SEANCE_HERMES_PID` | `hermes-hook` |
| `resources/bin/kilo` | Kilo Code | `SEANCE_KILO_PID` | `kilo-hook` |
| `resources/bin/mimo` | MiMo Code | `SEANCE_MIMOCODE_PID` | `mimocode-hook` |
| `resources/bin/opencode` | OpenCode | `SEANCE_OPENCODE_PID` | `opencode-hook` |
| `resources/bin/pi` | Pi Agent | `SEANCE_PI_PID` | `pi-hook` |
| `resources/bin/pool` | Poolside Agent CLI | `SEANCE_POOL_PID` | `pool-hook` |
| `resources/bin/vibe` | Mistral Vibe | `SEANCE_VIBE_PID` | `vibe-hook` |

## Config Toggles

Each agent integration can be toggled in `~/.config/seance/config.toml`:

```toml
# Agent integrations
opencode-hooks = true
kilo-hooks = true
mimocode-hooks = true
codex-hooks = true
pi-hooks = true
pool-hooks = true
codebuff-hooks = true
freebuff-hooks = true
vibe-hooks = true
hermes-hooks = true
```

Or via the Settings UI: **Settings → Terminal → Agent Integration**.
