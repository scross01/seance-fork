// Séance plugin for OpenCode V2
// Copy to ~/.config/opencode/plugins/seance-opencode.ts
// @seance-version 17

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
    // V2 launches run --standalone per pane: the setup location is the pane's
    // launch directory, and process.cwd() agrees when the ctx shape drifts.
    const cwd = ctx.location?.directory ?? process.cwd();
    let currentSessionId;
    let sessionIdle = false;
    let permissionPending = false;
    let childSessions = new Set();
    let peerSessions = new Set();
    let completedSessions = new Set();
    let executing = new Set();
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
            peerSessions.clear();
            completedSessions.clear();
            executing.clear();
            subagentCount = 0;
            await hook("session-start", { cwd });
            await hook("prompt-submit");
          } else if (eventSessionId && eventSessionId !== currentSessionId) {
            // V2 subagents carry parentID; any other session is an independent
            // session sharing this window's single status (V1 counted every
            // second session as a subagent).
            if (payload.parentID) await trackChildSession(eventSessionId);
            else peerSessions.add(eventSessionId);
          }
          break;

        case "session.execution.started": {
          let adopted = false;
          if (!currentSessionId && eventSessionId) {
            currentSessionId = eventSessionId;
            sessionIdle = false;
            childSessions.clear();
            peerSessions.clear();
            completedSessions.clear();
            executing.clear();
            subagentCount = 0;
            await hook("session-start", { cwd });
            await hook("prompt-submit");
            adopted = true;
          }
          const execId = eventSessionId ?? currentSessionId;
          if (!execId || childSessions.has(execId)) break;
          if (executing.size === 0) {
            sessionIdle = false;
            permissionPending = false;
            if (!adopted) await hook("prompt-submit");
          }
          executing.add(execId);
          break;
        }

        case "session.execution.succeeded":
        case "session.execution.failed":
        case "session.execution.interrupted":
          if (eventSessionId && childSessions.has(eventSessionId)) {
            await untrackChildSession(eventSessionId);
            break;
          }
          if (eventSessionId) executing.delete(eventSessionId);
          if (executing.size > 0) break;
          if (permissionPending) {
            permissionPending = false;
            break;
          }
          sessionIdle = true;
          await hook("stop", { cwd });
          break;

        case "session.deleted":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            childSessions.clear();
            peerSessions.clear();
            completedSessions.clear();
            executing.clear();
            subagentCount = 0;
            await updateCounts();
            await hook("session-end");
            currentSessionId = undefined;
          } else {
            const wasExecuting = peerSessions.delete(eventSessionId) && executing.delete(eventSessionId);
            await untrackChildSession(eventSessionId);
            if (wasExecuting && executing.size === 0) {
              sessionIdle = true;
              await hook("stop", { cwd });
            }
          }
          break;

        case "permission.asked":
          if (!sessionIdle) {
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
      if (!event.sessionID || event.sessionID === currentSessionId || peerSessions.has(event.sessionID)) {
        await hook("pre-tool-use", { tool_name: event.tool });
      }
    });
    await ctx.tool.hook("execute.after", async (event) => {
      if (!event.sessionID || event.sessionID === currentSessionId || peerSessions.has(event.sessionID)) {
        await hook("post-tool-use", { tool_name: event.tool });
      }
    });

    return () => controller.abort();
  },
});
