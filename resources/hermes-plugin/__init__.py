import json
import os
import signal
import subprocess


# Tell the kernel to auto-reap finished children so they don't become zombies.
signal.signal(signal.SIGCHLD, signal.SIG_IGN)


def _enabled():
    """Check if seance integration is active for this session."""
    return bool(os.environ.get("SEANCE_SURFACE_ID")) and \
        os.environ.get("SEANCE_HERMES_HOOKS_DISABLED") != "1"


def _emit(event, payload):
    # ponytail: fire-and-forget subprocess; batch/async only if profiling shows overhead
    if not _enabled():
        return
    payload = dict(payload or {})
    for k, env in (("workspace_id", "SEANCE_WORKSPACE_ID"),
                   ("surface_id", "SEANCE_SURFACE_ID")):
        v = os.environ.get(env)
        if v:
            try:
                payload[k] = int(v)
            except ValueError:
                pass
    try:
        # Use Popen for fire-and-forget to avoid blocking the event thread.
        # start_new_session=True ensures the child doesn't hold the parent's
        # terminal or signal group, so slow/unreachable socket stalls at most
        # one hook call, not the entire agent loop.
        proc = subprocess.Popen(
            ["seance", "ctl", "hermes-hook", event],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        # Write payload in background; ignore EPIPE if child already exited.
        try:
            proc.stdin.write(json.dumps(payload).encode())
            proc.stdin.close()
        except Exception:
            pass
    except Exception:
        pass  # fail-open: never break the agent


def register(ctx):
    ctx.register_hook("on_session_start", lambda **k: _emit("session-start", {
        "session_id": k.get("session_id"),
        "cwd": os.getcwd(),
    }))
    ctx.register_hook("pre_llm_call", lambda **k: _emit("prompt-submit", {
        "session_id": k.get("session_id"),
    }))
    ctx.register_hook("pre_tool_call", lambda **k: _emit("pre-tool-use", {
        "session_id": k.get("session_id"),
        "tool_name": k.get("tool_name") or k.get("function_name"),
        "tool_input": k.get("args") or k.get("function_args"),
    }))
    ctx.register_hook("post_tool_call", lambda **k: _emit("post-tool-use", {
        "session_id": k.get("session_id"),
    }))
    ctx.register_hook("post_llm_call", lambda **k: _emit("llm-complete", {
        "session_id": k.get("session_id"),
        "assistant_response": k.get("assistant_response"),
    }))
    ctx.register_hook("pre_approval_request", lambda **k: _emit("approval-request", {
        "session_id": k.get("session_key"),
        "command": k.get("command"),
    }))
    ctx.register_hook("post_approval_response", lambda **k: _emit("approval-response", {
        "session_id": k.get("session_key"),
        "choice": k.get("choice"),
    }))
    ctx.register_hook("on_session_end", lambda **k: _emit("session-end", {
        "session_id": k.get("session_id"),
    }))
    ctx.register_hook("on_session_reset", lambda **k: _emit("interrupt", {
        "session_id": k.get("session_id") or k.get("new_session_id"),
    }))
