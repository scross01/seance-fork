# Vibe Integration

Séance integrates with [Mistral Vibe](https://github.com/mistralai/mistral-vibe) through TOML config hooks. Unlike other agents that use TypeScript plugins, Vibe uses a simpler config-based approach.

## How It Works

1. **Hooks auto-install** on Séance startup — appends to `~/.vibe/hooks.toml`
2. **Wrapper script** intercepts `vibe` launches, tracks PID, and fires `session-end` on exit
3. **Vibe calls hooks** during tool execution and turn completion

## Hook Event Mapping

| Vibe Hook Event | Séance Command | What It Shows |
|-----------------|----------------|---------------|
| `before_tool` | `pre-tool-use` | Running |
| `after_tool` | `post-tool-use` | Running |
| `post_agent_turn` | `stop` | Idle |
| *(process exit)* | `session-end` | (cleared) |

**Important:** `post_agent_turn` maps to `stop`, not `session-end`. The turn ended but the session is still alive — the user may send another prompt.

## Session Boundaries

Vibe has no explicit session start/end hooks. Séance infers boundaries:

- **Session start**: first hook event after the wrapper launches
- **Session end**: wrapper fires `session-end` after Vibe exits
- **Turn boundaries**: `post_agent_turn` = turn done, next `before_tool` = new turn

## Configuration

Toggle integration on or off in `config.toml`:

```toml
vibe-hooks = true
```

## Limitations

- **No notification support** — Vibe has no notification hook type. Desktop notifications from Vibe can't be forwarded through Séance.
- **No permission detection** — Vibe has no `AskUser` equivalent. When Vibe prompts for permission, the sidebar shows "Running" instead of "Waiting for Permission".
- **Experimental hooks required** — the wrapper script sets `VIBE_ENABLE_EXPERIMENTAL_HOOKS=1`. Without this, hooks silently do nothing.
- **No session directory** — Vibe doesn't expose session directory information.

---

## For Contributors

### Integration Approach

Vibe uses a **config-based approach** instead of a TypeScript plugin:

1. **TOML config hooks** — Séance appends hook definitions to `~/.vibe/hooks.toml`. Uses an **append strategy** (not overwrite), checking for an `"Auto-installed by"` marker to avoid duplicate installs and preserve user-authored hooks.
2. **Wrapper script** (`resources/bin/vibe`) — intercepts `vibe` launches, sets `VIBE_ENABLE_EXPERIMENTAL_HOOKS=1` (required for hooks to function), exports `SEANCE_VIBE_PID`, and fires `session-end` on exit.

No TypeScript plugin or Python plugin is involved — Vibe's hook system is configured entirely through TOML.

### Event Mapping

| Vibe Hook Event | Seance Hook | UI Status |
|---|---|---|
| `before_tool` | `pre-tool-use` | Running |
| `after_tool` | `post-tool-use` | Running |
| `post_agent_turn` | `stop` | Idle |
| (process exit) | `session-end` | (cleared) |

**Inferred boundaries:**
- First hook event after wrapper launch = `session-start`
- Wrapper exit = `session-end`
- `post_agent_turn` = turn boundary

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `vibe`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `vibe-hooks = true` in `config.toml`.
- **Append strategy.** The install function appends to `~/.vibe/hooks.toml` and checks for the `"Auto-installed by"` marker to avoid duplicates. User-authored hooks above the marker are preserved.
- **Wrapper special case.** The Vibe wrapper is the only one that sets an additional environment variable (`VIBE_ENABLE_EXPERIMENTAL_HOOKS=1`) beyond the standard PID export.

### Upstream Framework Events

**Source:** [github.com/mistralai/mistral-vibe](https://github.com/mistralai/mistral-vibe/blob/main/README.md)

Vibe has a simpler hook system focused on tool execution:

| Event | Description | Séance Handles? |
|-------|-------------|-----------------|
| `before_tool` | Before tool execution | Yes |
| `after_tool` | After tool execution | Yes |
| `post_agent_turn` | Agent turn completed | Yes |

**Note:** Vibe has no explicit session start/end hooks. Séance infers boundaries from hook activity and wrapper exit.

### Missing Event Coverage

Events that Vibe can emit but Séance does not currently handle:

| Event | Potential Use for Séance |
|-------|--------------------------|
| `pre_tool` | Tool execution tracking |
| `post_tool` | Tool completion tracking |
| `post_agent` | Agent turn completion |

**Impact:** Vibe has limited hook support compared to other agents. Séance's built-in integration covers the basics.
