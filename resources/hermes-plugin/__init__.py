import atexit
import collections
import json
import os
import subprocess
import threading
import time

# The host owns process-wide signal policy (SIGCHLD in particular); this
# plugin never mutates it. Every child spawned below is awaited and reaped
# individually by a single owned worker, so unrelated host children keep
# their real exit statuses.

_MAX_QUEUE = 64
_MAX_PAYLOAD = 1024 * 1024
_CHILD_TIMEOUT = 10.0
_FLUSH_TIMEOUT = 2.0

_items = collections.deque()
_cond = threading.Condition()
_delivering = False
_worker = None
_worker_lock = threading.Lock()
_atexit_registered = False


def _enabled():
    """Check if seance integration is active for this session."""
    return bool(os.environ.get("SEANCE_SURFACE_ID")) and \
        os.environ.get("SEANCE_HERMES_HOOKS_DISABLED") != "1"


def _emit(event, payload):
    # fail-open: never break the agent
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
        data = json.dumps(payload).encode()
    except Exception:
        return
    if len(data) > _MAX_PAYLOAD:
        return  # oversized payloads are dropped, never written
    with _cond:
        if len(_items) >= _MAX_QUEUE:
            return  # bound kept: drop rather than block the agent thread
        _items.append((event, data))
        _cond.notify()
    _ensure_worker()


def _ensure_worker():
    global _worker, _atexit_registered
    with _worker_lock:
        if _worker is None or not _worker.is_alive():
            _worker = threading.Thread(target=_worker_main,
                                       name="seance-hermes-hook", daemon=True)
            _worker.start()
        if not _atexit_registered:
            atexit.register(_flush, _FLUSH_TIMEOUT)
            _atexit_registered = True


def _worker_main():
    # One worker, FIFO: at most one owned child at a time, so queued
    # lifecycle events are delivered in emission order.
    global _delivering
    while True:
        with _cond:
            while not _items:
                _cond.wait()
            event, data = _items.popleft()
            _delivering = True
        try:
            _deliver(event, data)
        except Exception:
            pass  # fail-open: emission errors never escape to the agent
        finally:
            with _cond:
                _delivering = False
                _cond.notify_all()


def _deliver(event, data):
    proc = subprocess.Popen(
        ["seance", "ctl", "hermes-hook", event],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        try:
            proc.stdin.write(data)
            proc.stdin.close()
        except Exception:
            # Broken pipe: the child exited before reading. Close and move
            # on; the wait below still reaps it.
            try:
                proc.stdin.close()
            except Exception:
                pass
        try:
            proc.wait(timeout=_CHILD_TIMEOUT)
        except subprocess.TimeoutExpired:
            # Slow or unreachable bridge: kill and reap our own child only.
            proc.kill()
            try:
                proc.wait(timeout=_CHILD_TIMEOUT)
            except Exception:
                pass
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=1.0)
        except Exception:
            pass


def _flush(timeout=_FLUSH_TIMEOUT):
    """Best-effort drain of queued/in-flight deliveries before exit."""
    with _cond:
        _cond.wait_for(lambda: not _items and not _delivering, timeout)


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
