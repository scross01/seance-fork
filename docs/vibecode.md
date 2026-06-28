# Mistral Vibe Integration Notes

Implementation details and gotchas not obvious from the code.

## Architecture Difference from Other Agents

OpenCode, Kilo Code, and MiMoCode use **TypeScript plugins** loaded by the agent process. Vibe uses **config-based hooks** (`hooks.toml`). This changes the integration surface:

| Agent | Hook mechanism | Install target | Bundled artifact |
|-------|---------------|----------------|------------------|
| OpenCode | TS plugin | `~/.config/opencode/plugins/` | `opencode-plugin.ts` |
| Kilo Code | TS plugin | `~/.config/kilo/plugins/` | `kilo-plugin.ts` |
| MiMo Code | TS plugin | `~/.config/mimocode/plugins/` | `mimocode-plugin.ts` |
| **Vibe** | **TOML config** | **`~/.vibe/hooks.toml`** | **`vibe-hooks.toml`** |

The `installVibeHooks()` function in `src/app.zig` appends to existing `hooks.toml` files rather than overwriting, since users may have their own hooks defined there. It checks for the `"Auto-installed by"` marker to avoid duplicate installs.

## Hook Event Mapping

Vibe's hook events don't map 1:1 to Séance's internal commands. The mapping requires understanding what each side means:

| Vibe hook event | Séance command | Why |
|----------------|---------------|-----|
| `before_tool` | `pre-tool-use` | Sets status to the tool being used (e.g., "Reading file.ts") |
| `after_tool` | `post-tool-use` | Resets status to "Running" |
| `post_agent_turn` | **`stop`** | Sets status to "Idle" and emits completion notification |
| *(process exit)* | `session-end` | Handled by wrapper script, clears session entirely |

**Critical**: `post_agent_turn` maps to `stop`, NOT `session-end`. The `session-end` command destroys the session record. `post_agent_turn` means the turn ended but the session is still alive — the user may send another prompt. Using `session-end` here would lose session state between turns.

## Experimental Hooks Must Be Enabled

Vibe's hooks are experimental. The wrapper script (`resources/bin/vibe`) sets:
```bash
export VIBE_ENABLE_EXPERIMENTAL_HOOKS=1
```

Without this, hooks silently do nothing — Vibe won't error, it just won't call them. This is the most likely cause of "hooks not working" during testing.

## Session Boundary Inference

Vibe has no explicit `SessionStart` or `SessionEnd` hook events. Séance infers boundaries:

- **Session start**: First hook event after the wrapper exports `SEANCE_VIBE_PID`
- **Session end**: Wrapper script fires `seance ctl vibe-hook session-end` after Vibe exits
- **Turn boundaries**: `post_agent_turn` = turn done, first `before_tool` after that = new turn

The wrapper script is essential for session-end detection. Without it, a crashed or force-killed Vibe process would leave stale session state.

## No Permission Detection

Vibe has no `AskUser` or equivalent permission event. When Vibe prompts the user for permission (e.g., to run a destructive command), Séance cannot detect this state. The sidebar will show "Running" instead of "Waiting for Permission".

This is acceptable because Vibe handles its own permission prompts in the terminal UI. The only impact is the sidebar status accuracy.

## No Notification Forwarding

Vibe has no notification hook type. Desktop notifications from Vibe cannot be forwarded through Séance's notification system. Vibe's own notification mechanism (if any) operates independently.

## Hooks.toml Append Behavior

The install function uses an append strategy rather than overwrite:

1. If `~/.vibe/hooks.toml` doesn't exist → create with Séance hooks
2. If it exists and contains `"Auto-installed by"` → already installed, skip
3. If it exists without the marker → append Séance hooks after existing content

This preserves user-authored hooks. The tradeoff is that upgrading Séance won't update the hooks template — the marker check only prevents duplicate initial installs.

## Wrapper Script Differences

The Vibe wrapper differs from other agents in one way: it sets `VIBE_ENABLE_EXPERIMENTAL_HOOKS=1`. Other wrappers don't need to enable features that are off by default.

The wrapper does NOT set `VIBE_HOOKS_CONFIG` or similar — Vibe auto-discovers `~/.vibe/hooks.toml` by convention.

## What's Missing vs Other Agents

| Feature | Claude | OpenCode | Kilo | MiMoCode | Vibe |
|---------|--------|----------|------|----------|------|
| TS plugin | No | Yes | Yes | Yes | N/A |
| Notification hook | Yes | Yes | Yes | Yes | **No** |
| AskUser detection | Yes | Yes | Yes | Yes | **No** |
| Session dir tracking | No | Yes | Yes | No | **No** |
| Status key mode | session | surface | surface | surface | surface |

Session dir tracking (`session_dir_env`) is unused for Vibe because Vibe doesn't expose a session directory path via environment variables.
