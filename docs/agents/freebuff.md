# Freebuff Integration

Séance integrates with [Freebuff](https://freebuff.com) through session log monitoring using `inotifywait`. Freebuff doesn't have a native hook system, so Séance discovers the session's own `log.jsonl` and watches that file for agent-step markers.

## How It Works

1. **Wrapper script** intercepts `freebuff` launches inside Séance terminals
2. **Background monitor** discovers this session's own `chats/<timestamp>/log.jsonl` (Freebuff writes a fresh timestamped chat directory per launch) and watches that single file with `inotifywait`
3. **Activity detection** — when a `Start agent` / `[message-queue] Processing` marker line is appended, status changes to "Running"
4. **Idle detection** — when no marker activity for 5 seconds (the CLI's
   debug/telemetry writes don't count), status changes to "Idle"; a
   `[chat-runtime] Freebuff session over` line flips to "Idle" immediately
5. **Session end** — wrapper fires `session-end` on exit via trap

## Status Detection

| State | How Detected |
|-------|--------------|
| **Running** | A `Start agent` or `[message-queue] Processing` marker line appended to the session log |
| **Idle** | No marker activity for 5 seconds (timeout), or a `[chat-runtime] Freebuff session over` line |
| **Needs input** | Not supported — shows "Running" instead |

## Features

- **Per-surface status** — each terminal pane tracks its own agent status independently
- **Session tracking** — tracks session lifecycle from start to end

## Requirements

- **`inotify-tools`** must be installed: `sudo apt install inotify-tools` (Ubuntu/Debian) or `sudo pacman -S inotify-tools` (Arch)
- **`ps`** (procps) is used to match the session log to this pane; present on any standard Linux system

## Configuration

Toggle integration on or off in `config.toml`:

```toml
freebuff-hooks = true
```

## Limitations

- **Heuristic-based** — activity detection parses the session log's agent-step markers (`Start agent`, `[message-queue] Processing`, `session over`), not raw file mtimes; unrelated writes (debug/telemetry lines) don't count as activity. Detection is still heuristic overall: the log format is an unversioned internal detail of the Freebuff CLI, so a CLI update could change the markers.
- **Latency** — there's a 5-second idle timeout before status changes from "Running" to "Idle".
- **No notification support** — Freebuff doesn't emit permission request events.
- **No permission detection** — when Freebuff prompts for permission, the sidebar shows "Running" instead of "Waiting for input".

---

## For Contributors

### Integration Approach

Freebuff uses **session log monitoring** with `inotifywait` — a Linux-specific tool that watches for file system events without polling.

**Why inotifywait:** Freebuff doesn't expose lifecycle events through a plugin API or hook system. The only way to detect activity is by monitoring its session log file.

### How the Monitor Works

The wrapper script starts a background process with two phases:

**Discover phase** (bounded poll, 30s deadline):

1. Every 0.25s, look for recent `log.jsonl` candidates (mtime within 5s)
   under `~/.config/manicode/projects/`, spanning the current project's
   `chats/` dir and any other project, sorted newest first
2. Accept a candidate only when its tail lines carry the `"pid"` field of one of the wrapper's descendant processes. Freebuff logs `pid` on every line, and the wrapper's descendants include the CLI — even through the npm launcher, which spawns the real binary as a grandchild. This ties the log to *this pane*: a sibling pane's freshly-written log can never be claimed (two panes in the same project each watch their own per-launch chat dir)
3. The 30s deadline covers the npm launcher's pre-flight (fingerprint, update check), which can take ~16s before the CLI writes its first log line
4. If nothing is found by the deadline: fire Idle once and exit the monitor (the wrapper's EXIT trap still guarantees `session-end`)

**Watch phase** (single file):

1. Initialize state to `Idle` (the wrapper's initial `prompt-submit` already set Running)
2. Loop while the parent wrapper is alive (`kill -0 $$`)
3. `inotifywait -q -e modify -t <idle_timeout> <logfile>` on the single resolved file — no `-r`, no `--include`
4. On each wake (event or idle timeout), read lines appended since the
   last byte offset (`wc -c` + `tail -c +N`) and parse markers:

   | Log line contains | Effect |
   |---|---|
   | `Start agent ` or `[message-queue] Processing` | Running (fires `prompt-submit {"status":"Running"}` if not already Running) |
   | `[chat-runtime] Freebuff session over` | Idle immediately |
   | `End agent` alone | no state change (agents chain back-to-back; flipping on End would flicker) |
   | unrelated lines (debug/telemetry) | no state change (fixes false-Running) |

5. Idle is decided on every wake by **time since the last marker**: 5s
   without one flips a Running status to Idle. Raw writes never extend
   the Running state — the CLI emits debug lines (e.g. `fileNameTruncation
   took a while`) indefinitely, so event silence alone would never
   produce an Idle
6. If the watched file vanished (shouldn't happen — pino appends, no rotation): re-discover once, then give up
7. A TERM/INT/HUP trap reaps the watch child and state file; the wrapper's EXIT trap kills the monitor on session end

### Event Mapping

| Trigger | Seance Hook | UI Status |
|---|---|---|
| Session start (wrapper) | `prompt-submit` | Running |
| `Start agent` / `[message-queue] Processing` line appended | `prompt-submit {"status":"Running"}` | Running |
| No log activity for 5s | `prompt-submit {"status":"Idle"}` | Idle |
| `[chat-runtime] Freebuff session over` line | `prompt-submit {"status":"Idle"}` | Idle |
| Process exit (wrapper trap) | `session-end` | (cleared) |

### Key Implementation Details

- **Status mode:** Per-surface. Status key prefix `freebuff`, mode `surface`.
- `clear_status_on_end` is `true`.
- `has_notification_hook` is `false`.
- **Config toggle:** `freebuff-hooks = true` in `config.toml`.
- **File pattern:** `log.jsonl` — one active file per launch under `chats/<ISO-8601 timestamp>/`, not a directory tree.
- **Idle timeout:** 5 seconds since the last marker (not since the last file write)
- **State file:** if the monitor's temp state file is deleted externally it
  is recreated as Running, so the next timeout can still flip the sidebar
  to Idle instead of erroring; status transitions retry once if the socket
  call fails.
- **Log path ownership:** verified by the `"pid"` field in log lines against the wrapper's descendant PIDs (`ps` walk), not by path guessing.
