// Séance plugin for OpenCode V2
// Copy to ~/.config/opencode/plugins/seance-opencode.ts
// @seance-version 15

import { Plugin } from "@opencode/plugin";
import { execFile } from "node:child_process";

export default Plugin.define({
  id: "seance",
  async setup(ctx) {
    const socket = process.env.SEANCE_SOCKET_PATH;
    if (!socket) return;
    if (process.env.SEANCE_OPENCODE_HOOKS_DISABLED === "1") return;

    const env = { ...process.env };
    const seanceBin = env.SEANCE_OPENCODE_BIN ?? "seance";

    const surfaceId = env.SEANCE_SURFACE_ID;
    const workspaceId = env.SEANCE_WORKSPACE_ID;
    let currentSessionId;
    let sessionIdle = false;
    let permissionPending = false;
    let childSessions = new Set();
    let completedSessions = new Set();
    let subagentCount = 0;

    function send(args, payload) {
      return new Promise((resolve) => {
        const child = execFile(seanceBin, args, {
          env, timeout: 750, killSignal: "SIGKILL", maxBuffer: 4096,
        }, (error) => resolve(!error));
        child.stdin.on("error", () => {});
        // No shell interpolation: payload is plain JSON on stdin.
        child.stdin.end(payload);
      });
    }

    async function hook(event, extra = {}) {
      await send(["ctl", "opencode-hook", event], JSON.stringify({
        session_id: currentSessionId,
        workspace_id: workspaceId,
        surface_id: surfaceId,
        subagent_count: subagentCount,
        ...extra,
      }));
    }

    async function updateCounts() {
      await send(["ctl", "subagent-update"], JSON.stringify({
        workspace_id: workspaceId,
        subagent_count: subagentCount,
        background_count: 0,
      }));
    }

    async function trackChildSession(eventSessionId) {
      if (completedSessions.has(eventSessionId)) return;
      if (!childSessions.has(eventSessionId)) {
        childSessions.add(eventSessionId);
        subagentCount++;
        await updateCounts();
        if (!sessionIdle) {
          await hook("prompt-submit");
        }
      }
    }

    async function untrackChildSession(eventSessionId) {
      if (childSessions.has(eventSessionId)) {
        childSessions.delete(eventSessionId);
        completedSessions.add(eventSessionId);
        subagentCount = Math.max(0, subagentCount - 1);
        await updateCounts();
        if (!sessionIdle) {
          await hook("prompt-submit");
        }
      }
    }

    async function handleEvent(event) {
      const payload = event.data ?? {};
      const eventSessionId = payload.sessionID ?? payload.form?.sessionID;

      switch (event.type) {
        case "session.created":
          if (!currentSessionId) {
            currentSessionId = eventSessionId;
            sessionIdle = false;
            childSessions.clear();
            completedSessions.clear();
            subagentCount = 0;
            await hook("session-start");
            await hook("prompt-submit");
          } else if (eventSessionId && eventSessionId !== currentSessionId) {
            await trackChildSession(eventSessionId);
          }
          break;

        case "session.execution.started":
          if (!currentSessionId && eventSessionId) {
            currentSessionId = eventSessionId;
            sessionIdle = false;
            childSessions.clear();
            completedSessions.clear();
            subagentCount = 0;
            await hook("session-start");
            await hook("prompt-submit");
          } else if (!eventSessionId || eventSessionId === currentSessionId) {
            sessionIdle = false;
            permissionPending = false;
            await hook("prompt-submit");
          }
          break;

        case "session.execution.succeeded":
        case "session.execution.failed":
        case "session.execution.interrupted":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            if (permissionPending) {
              permissionPending = false;
            } else {
              sessionIdle = true;
              await hook("stop");
            }
          } else {
            await untrackChildSession(eventSessionId);
          }
          break;

        case "session.deleted":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            childSessions.clear();
            completedSessions.clear();
            subagentCount = 0;
            await updateCounts();
            await hook("session-end");
            currentSessionId = undefined;
          } else {
            await untrackChildSession(eventSessionId);
          }
          break;

        case "permission.asked":
          if (!sessionIdle && (!eventSessionId || eventSessionId === currentSessionId)) {
            permissionPending = true;
            const permType = payload.action ?? "unknown";
            const resources = payload.resources;
            const detail = Array.isArray(resources) && resources.length > 0
              ? permType + ": " + resources.join(", ")
              : String(permType);
            await hook("notification", { message: detail });
          }
          break;

        case "permission.replied":
          permissionPending = false;
          break;
      }
    }

    const handled = new Set([
      "session.created", "session.deleted",
      "session.execution.started", "session.execution.succeeded",
      "session.execution.failed", "session.execution.interrupted",
      "permission.asked", "permission.replied",
    ]);
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (!handled.has(event.type)) continue;
        await handleEvent(event).catch(() => {});
      }
    })().catch(() => {});

    await ctx.tool.hook("execute.before", async (event) => {
      if (!event.sessionID || event.sessionID === currentSessionId) {
        await hook("pre-tool-use", { tool_name: event.tool });
      }
    });
    await ctx.tool.hook("execute.after", async (event) => {
      if (!event.sessionID || event.sessionID === currentSessionId) {
        await hook("post-tool-use", { tool_name: event.tool });
      }
    });

    return () => controller.abort();
  },
});
