# Hermes Agent Integration

Implementation details for Séance's Hermes Agent support. Unlike other agent integrations, Hermes uses a **Python plugin** rather than TypeScript or TOML config hooks.

## Architecture Difference from Other Agents

Hermes has a Python plugin system whose callbacks fire from shared core — covering CLI, TUI, gateway, desktop, and dashboard surfaces. This was the motivation for the plugin approach: the earlier shell-hooks design (plan 031) injected `hooks:` into `~/.hermes/config.yaml`, but that mechanism is only registered on the CLI surface. The TUI backend (`tui_gateway/server.py`) never calls `register_from_config`, so shell hooks silently did nothing there.

| Agent | Hook mechanism | Install target | Bundled artifact |
|-------|---------------|----------------|------------------|
| Claude | Shell hooks | `~/.claude/settings.json` | *(wrapper only)* |
| OpenCode | TS plugin | `~/.config/opencode/plugins/` | `opencode-plugin.ts` |
| Kilo Code | TS plugin | `~/.config/kilo/plugins/` | `kilo-plugin.ts` |
| MiMo Code | TS plugin | `~/.config/mimocode/plugins/` | `mimocode-plugin.ts` |
| Vibe | TOML config | `~/.vibe/hooks.toml` | `vibe-hooks.toml` |
| **Hermes** | **Python plugin** | **`~/.hermes/plugins/seance/`** | **`hermes-plugin/`** |

## Plugin Contract

A Hermes plugin is a directory under `~/.hermes/plugins/<key>/` containing:

1. `plugin.yaml` — manifest with `name`, `version`, `hooks:` list
2. `__init__.py` — exposes `def register(ctx)` that calls `ctx.register_hook(event, callback)`

Plugins are gated by `plugins.enabled` in `~/.hermes/config.yaml`. The install function adds `seance` to this list; the remove function strips it.

## Hook Event Mapping

Hermes hook events map to Séance commands as follows:

| Hermes hook | Fires from | Séance command | Notes |
|-------------|-----------|----------------|-------|
| `on_session_start` | `agent/conversation_loop.py` | `session-start` | Plugin also sends `cwd` |
| `pre_llm_call` | `agent/turn_context.py` | `prompt-submit` | |
| `pre_tool_call` | `model_tools.py` | `pre-tool-use` | |
| `post_tool_call` | `model_tools.py` | `post-tool-use` | |
| `post_llm_call` | `agent/turn_finalizer.py` | `llm-complete` | Hermes-specific: sets "Idle" + completion notification |
| `pre_approval_request` | `tools/approval.py` | `approval-request` | Hermes-specific: shows "Pending approval: \<cmd\>" |
| `post_approval_response` | `tools/approval.py` | `approval-response` | No-op (status set by next pre_tool_use) |
| `on_session_end` | session finalize | `session-end` | |
| `on_session_reset` | `gateway/slash_commands.py` (`/reset`, `/new`) | `interrupt` | Hermes-specific: resets stuck "Running" → "Idle" |

**Key difference**: Other agents use `stop` for completion and `notification` for user prompts. Hermes fires `llm-complete` and `approval-request` as separate events, so `ctl.zig` has Hermes-specific handlers for these.

## The `clarify` Tool

Hermes has a `clarify` tool (user-question tool) that surfaces through `pre_tool_call` with `tool_name == "clarify"`. The `agentHookPreToolUse` handler special-cases this:

```zig
if (eql(tn, "clarify") or eql(tn, "AskUserQuestion")) {
    // Extract question text, set "Waiting for user input..." status,
    // emit focus-suppressed notification with the actual question
}
```

This matches how Claude/OpenCode/Kilo/MiMo handle their `AskUserQuestion` tool.

## The `session_key` vs `session_id` Mapping

Hermes approval hooks pass `session_key` (not `session_id`) in their kwargs. The plugin maps this:

```python
ctx.register_hook("pre_approval_request", lambda **k: _emit("approval-request", {
    "session_id": k.get("session_key"),  # mapped to session_id for ctl.zig
    "command": k.get("command"),
}))
```

The `ctl.zig` handlers expect `session_id` in the JSON payload, so the plugin translates the field name.

## Interrupt / Reset Handling

When a Hermes turn is interrupted (e.g. Ctrl-C cancel-generation), status could get stuck on "Running":

- `post_llm_call` → `llm-complete` (the hook that sets "Idle") is gated by
  `if final_response and not interrupted` in `agent/turn_finalizer.py`, so it
  **does not fire** on interrupt.
- The wrapper's `trap ... EXIT` → `session-end` also can't help: when Hermes
  absorbs SIGINT and keeps the TUI alive, the child never exits, so the trap
  never runs.

The reliable signal we have is **`on_session_reset`**, fired by
`gateway/slash_commands.py` on `/reset` and `/new`. The plugin maps it to a new
`interrupt` event:

```python
ctx.register_hook("on_session_reset", lambda **k: _emit("interrupt", {
    "session_id": k.get("session_id") or k.get("new_session_id"),
}))
```

`cmdAgentHook` dispatches `interrupt` to `agentHookInterrupt` (Hermes-only), which
sets status "Idle" at priority 5 — matching `agentHookLlmComplete`.

**Coverage**: this resets "Idle" on `/reset` and `/new`. A raw Ctrl-C
cancel-generation *without* a `/reset` is still uncovered, because Hermes fires
no hook for that path. Closing that gap would require a Hermes-core change
(firing `post_llm_call` on interrupt) — tracked separately.

## Plugin as Thin Shim

The plugin is deliberately minimal — it does not reimplement status logic. Each callback translates to a `seance ctl hermes-hook <event>` subprocess call with the same JSON-on-stdin payload. All status tracking, session management, and notification logic lives in `ctl.zig`, shared with other agents.

```python
def _emit(event, payload):
    # Inject workspace_id/surface_id from pane env, then:
    proc = subprocess.Popen(
        ["seance", "ctl", "hermes-hook", event],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    proc.stdin.write(json.dumps(payload).encode())
    proc.stdin.close()
```

The plugin is fail-open: any exception is swallowed so a broken or absent Séance never breaks the agent.

## The Wrapper Script

`resources/bin/hermes` intercepts `hermes` invocations inside Séance terminals. Unlike the earlier shell-hooks design, it does **not** edit `~/.hermes/config.yaml`. It only:

1. Discovers the real `hermes` binary (skipping the wrapper dir)
2. Passes through if not inside Séance, hooks disabled, or socket unreachable
3. Exports `SEANCE_HERMES_PID` for process tracking
4. Launches hermes (non-exec) and fires `session-end` on exit

## Notification Parity

Hermes achieves the same notification behavior as other agents through its specific handlers:

- **Completion** (`agentHookLlmComplete`): emits "Completed in \<project\>" notification, focus-suppressed — matches `agentHookStop` used by other agents.
- **Input request** (`agentHookApprovalRequest` / clarify branch): emits notification with the actual question or command as body, focus-suppressed — matches `agentHookNotification` used by other agents.

The `has_notification_hook = false` on `hermes_agent` is correct, not an oversight — parity is achieved via these Hermes-specific handlers.

## `clear_status_on_end = false`

Unlike all other agents, Hermes sets `clear_status_on_end = false`. This is because:

- Other agents use `stop` / `notification` hooks that set "Idle" status, and `session-end` clears it (the session is truly over).
- Hermes fires `post_llm_call` → `llm-complete` to set "Idle" after each turn, but the session stays alive for the next prompt. If `clear_status_on_end` were true, `on_session_end` would wipe the "Idle" status in TUI mode where the session persists between turns.

The wrapper's `trap ... EXIT` fires `session-end` when hermes actually exits, but the handler does **not** clear status (since `clear_status_on_end = false` and no override is implemented). This means the sidebar status persists after Hermes exits in TUI mode — which is acceptable because TUI sessions typically outlive individual agent processes.

## What's Missing vs Other Agents

| Feature | Claude | OpenCode | Kilo | MiMoCode | Vibe | Hermes |
|---------|--------|----------|------|----------|------|--------|
| TS plugin | No | Yes | Yes | Yes | N/A | N/A |
| Python plugin | No | No | No | No | No | **Yes** |
| Notification hook | Yes | Yes | Yes | Yes | No | **No** (via llm-complete/approval-request) |
| AskUser detection | Yes | Yes | Yes | Yes | No | **Yes** (clarify tool) |
| Approval detection | No | No | No | No | No | **Yes** |
| Session dir tracking | No | Yes | Yes | No | No | **No** |
| clear_status_on_end | Yes | Yes | Yes | Yes | Yes | **No** |
| Status key mode | session | surface | surface | surface | surface | **surface** |
| Config file editing | Yes | No | No | No | Yes | **No** |
