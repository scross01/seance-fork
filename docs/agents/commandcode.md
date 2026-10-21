# Command Code Integration

Séance integrates with [Command Code](https://commandcode.ai) through its own
hooks harness. Command Code reads hooks from `~/.commandcode/settings.json`,
and Séance merges its handlers into that file while preserving everything else
you have configured.

## How It Works

1. **Wrapper script** intercepts `cmd` launches inside Séance terminals
2. **Hooks** are installed in `~/.commandcode/settings.json` for `SessionStart`,
   `PreToolUse`, `PostToolUse`, and `Stop`
3. **Status updates** — a tool call shows the tool and its target in the
   sidebar; the end of a turn returns the pane to "Idle"
4. **Session end** — Command Code has no `SessionEnd` event, so the wrapper
   fires `session-end` on exit via a trap

## Status Detection

| State | How Detected |
|-------|--------------|
| **Running** | `PreToolUse` / `PostToolUse` — the sidebar shows the tool and its target |
| **Idle** | `Stop` — the assistant finished its turn |
| **Needs input** | Not supported — shows "Running" instead |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Tool descriptions** — the sidebar reads "Running git status", "Reading
  hosts", "Writing out.txt" rather than raw tool names
- **Non-blocking** — the hooks only report status; they never deny a tool call
  and never interrupt a turn

## Configuration

Toggle integration on or off in `config.toml`:

```toml
commandcode-hooks = true
```

Or in **Settings → Integrations → Command Code Integration**.

Turning it off removes Séance's handlers from `~/.commandcode/settings.json`
and leaves the rest of the file intact.

## Limitations

- **No "Needs input" state** — Command Code's hooks do not report permission
  prompts, so a waiting session still shows "Running".
- **No subagent or session counts** — the hook payload carries no counts, so
  the sidebar shows no session or subagent pills. Tracking them needs a
  Command Code mod, not hooks.
- **No `SessionEnd` event** — Command Code has no session-end hook, so cleanup
  relies on the wrapper's `EXIT` trap. A `cmd` killed with `SIGKILL` leaves a
  stale "Running" status until the next event.
- **User scope only** — Séance writes to `~/.commandcode/settings.json`. A
  project-scoped `.commandcode/settings.json` takes precedence over it for
  that project and can shadow the user-scope handlers.
- **Only four tools are tracked** — the matcher is `SHELL|READ|WRITE|EDIT`, so
  Command Code's other tools (`SEARCH`, `GLOB`, `LIST`, `TASK_*`, `WEB_*`)
  do not update the sidebar description. The `Stop` event still fires, so the
  turn still ends in "Idle".
- **`seance` must be on `PATH`** — the hook command is
  `seance ctl commandcode-hook <event>`. If the `seance` binary is not
  resolvable from the pane, the hook exits quietly and nothing is tracked.
  This matches every other hook-based agent here (Claude Code, Pool, Codex
  all invoke `seance` by name); it works in a normal install, where `seance`
  is on `PATH`.

---

## For Contributors

### Integration Approach

Command Code exposes a Claude-Code-style hooks harness, so the integration
follows the same shape as the other hook-based agents: a wrapper script plus
hook entries in the agent's own settings file.

**Why the settings file, not a plugin:** Command Code's hooks are configured
in `settings.json`, not in a plugin directory. Séance therefore merges into
that file rather than installing a plugin.

### Event Mapping

| Trigger | Séance Hook | UI Status |
|---|---|---|
| Session start | `session-start` | (registered) |
| Tool call | `pre-tool-use` | Running + tool description |
| Tool finished | `post-tool-use` | Running |
| Turn finished | `stop` | Idle + completion notification |
| Process exit | `session-end` | (cleared) |

### Hook Schema

Command Code nests handlers under each event. A *HookDefinition* selects the
tools it applies to; a *HookEntry* is the handler that runs.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "SHELL|READ|WRITE|EDIT",
        "hooks": [
          { "type": "command", "command": "seance ctl commandcode-hook pre-tool-use", "timeout": 10 }
        ]
      }
    ]
  }
}
```

The matcher is a **case-insensitive regex tested against the tool's display
name** — `SHELL`, `READ`, `WRITE`, `EDIT` — not against the canonical tool id.
`SessionStart` and `Stop` carry no tool, so they must **omit** the matcher: a
matcher there never matches and the hook silently never fires.

The canonical tool ids in the payload are `shell_command`, `read_file`,
`write_file`, and `edit_file`; `tool_input` uses `command` for shell calls,
`absolute_path` for reads, and `file_path` for writes and edits.

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `commandcode`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false` — Command Code has no `Notification` event.
- `has_ask_user_handling` is `false` — there is no ask-user event either.
- **Response body:** `{}`. Command Code parses hook stdout as JSON and logs a
  warning for anything it cannot parse, so the response must be valid JSON.
  A non-JSON body such as `OK` warns on every single tool call.
- **Config toggle:** `commandcode-hooks = true` in `config.toml`.
- **Hooks file:** `~/.commandcode/settings.json`
- **Wrapper:** `resources/bin/cmd`, installed to `share/seance/bin/cmd`
- **Env var:** `SEANCE_COMMANDCODE_HOOKS_DISABLED=1` is set in panes when the
  integration is off, so the wrapper passes through without tracking a session.

### Idempotency

Séance owns its handlers, not the file. Installing is idempotent: an event
that already carries a `seance ctl commandcode-hook` handler is left alone, so
toggling the setting off and on cannot duplicate entries. Removing keeps every
handler you added, including ones that share a definition with ours, and
deletes the file if nothing but Séance's handlers was in it.

### Writing a file you do not own

`~/.commandcode/settings.json` belongs to the user, and Command Code writes it
too — `cmd mods add` persists a mod source there. The merger therefore:

- **skips the write entirely** when the file already says what Séance would
  write, so a launch does not rewrite the file for nothing;
- **takes an advisory lock** (`settings.json.seance.lock`) so two Séance
  instances cannot interleave;
- **re-reads the file before renaming the new content into place** and gives
  up if it changed in the meantime, so a concurrent Command Code write is
  never clobbered;
- **keeps the pre-Séance file once**, as `settings.json.seance-backup`;
- **preserves the file's permissions**, and never writes through a symlink.
