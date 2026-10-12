// Séance inline plugin for OpenCode V2
// Injected per launch through OPENCODE_CONFIG_CONTENT by resources/bin/opencode
// @seance-version 15

import { Plugin } from "@opencode/plugin";
import { execFile } from "node:child_process";
import { basename } from "node:path";

// OpenCode invokes event hooks concurrently. Keep lifecycle changes and socket
// writes ordered; an integration failure must never reject an agent/tool hook.
export default Plugin.define({
  id: "seance-inline",
  async setup(ctx) {
    const env = { ...process.env };
    const binary = env.SEANCE_OPENCODE_BIN;
    if (!binary || !env.SEANCE_SOCKET_PATH || !env.SEANCE_SURFACE_ID ||
        !env.SEANCE_WORKSPACE_ID || env.SEANCE_OPENCODE_HOOKS_DISABLED === "1") return;
    const directory = ctx.location.directory;

    const sessions = new Map();
    let queue = Promise.resolve();
    let lastState;
    let disposed = false;

    function enqueue(action) {
      queue = queue.then(action).catch(() => {});
      return queue;
    }

    function hook(command, payload = {}) {
      return new Promise((resolve) => {
        const child = execFile(binary, ["ctl", "opencode-hook", command], {
          env, timeout: 750, killSignal: "SIGKILL", maxBuffer: 4096,
        }, (error) => resolve(!error));
        child.stdin.on("error", () => {});
        // No shell interpolation: model text, paths and quotes are just JSON.
        child.stdin.end(JSON.stringify(payload));
      });
    }

    function session(id) {
      if (!sessions.has(id)) sessions.set(id, {
        busy: false, pending: new Set(), parent: undefined, error: null,
      });
      return sessions.get(id);
    }

    async function identify(id, state) {
      if (state.parent !== undefined) return;
      try {
        const result = await ctx.session.get({ sessionID: id, signal: AbortSignal.timeout(750) });
        if (result.data) state.parent = result.data.parentID ?? null;
      } catch {}
      // If the lookup fails, still track activity but don't claim this is a
      // completed top-level task. Resumed sessions need no session.created event.
    }

    async function publish(notice) {
      const all = [...sessions.values()];
      const state = all.some((s) => s.pending.size) ? "Needs input" :
        all.some((s) => s.busy) ? "Running" : "Idle";
      const notices = notice ? [{ notice }] : [];
      for (const [id, s] of sessions) {
        if (s.completion && !hasActiveDescendant(id)) notices.push({ notice: s.completion, session: s });
      }
      if (!notices.length && state === lastState) return;
      if (!notices.length) notices.push({});
      for (const item of notices) {
        const payload = { state };
        if (item.notice) {
          payload.title = String(item.notice.title).slice(0, 100);
          payload.message = String(item.notice.message ?? "").slice(0, 200);
        }
        if (await hook("state", payload)) {
          lastState = state;
          if (item.session) item.session.completion = undefined;
        }
      }
    }

    function hasActiveDescendant(root) {
      for (const [id, s] of sessions) {
        if (!s.busy && !s.pending.size) continue;
        let ancestor = id;
        const seen = new Set();
        while (ancestor !== null) {
          if (ancestor === root || seen.has(ancestor)) return true;
          seen.add(ancestor);
          ancestor = sessions.get(ancestor)?.parent;
          // Unknown ancestry must not announce completion ahead of a child.
          if (ancestor === undefined) return true;
        }
      }
      return false;
    }

    async function idle(id, state) {
      const wasBusy = state.busy;
      state.busy = false;
      state.pending.clear();
      if (wasBusy) {
        await identify(id, state);
        if (state.parent === null) {
          if (state.error?.name !== "MessageAbortedError") {
            state.completion = state.error ? {
              title: "OpenCode error",
              message: state.error.data?.message ?? state.error.message ?? state.error.name ?? "Task failed",
            } : {
              title: `Completed${directory ? ` in ${basename(directory)}` : ""}`,
            };
          }
        }
      }
      await publish();
    }

    async function event({ type, data: p = {} }) {
      if (disposed) return;
      const id = p.sessionID ?? p.form?.sessionID;
      if (!id) return;
      const state = session(id);
      switch (type) {
        case "session.created":
          state.parent = p.parentID ?? null;
          return;
        case "session.deleted":
          sessions.delete(id);
          return publish();
        case "session.execution.started":
          if (!state.busy) {
            state.error = null;
            state.completion = undefined;
          }
          state.busy = true;
          return publish();
        case "session.execution.succeeded":
          return idle(id, state);
        case "session.execution.failed":
          state.error = p.error ?? { message: "Task failed" };
          return idle(id, state);
        case "session.execution.interrupted":
          state.error = { name: "MessageAbortedError" };
          return idle(id, state);
        case "permission.asked": {
          if (!p.id || state.pending.has(p.id)) return;
          state.pending.add(p.id);
          const message = `Permission required: ${p.action ?? "tool"}${p.resources?.length ? ` (${p.resources.join(", ")})` : ""}`;
          return publish({ title: "OpenCode", message: message.slice(0, 200) });
        }
        case "form.created": {
          if (!p.form?.id || state.pending.has(p.form.id)) return;
          state.pending.add(p.form.id);
          const message = p.form.title || "OpenCode needs your input";
          return publish({ title: "OpenCode", message: message.slice(0, 200) });
        }
        case "permission.replied":
          state.pending.delete(p.requestID);
          return publish();
        case "form.replied":
        case "form.cancelled":
          state.pending.delete(p.id);
          return publish();
      }
    }

    await publish(); // Show a newly launched, waiting TUI without a completion alert.
    const controller = new AbortController();
    void (async () => {
      for await (const e of ctx.event.subscribe({ signal: controller.signal })) {
        if (!/^(session\.(created|deleted)|session\.execution\.(started|succeeded|failed|interrupted)|permission\.(asked|replied)|form\.(created|replied|cancelled))$/.test(e.type))
          continue;
        await enqueue(() => event(e));
      }
    })().catch(() => {});
    return () => {
      controller.abort();
      return enqueue(async () => {
        disposed = true;
        await hook("session-end");
      });
    };
  },
});
