// Séance plugin for MiMo Code
// Copy to ~/.config/mimocode/plugins/seance-mimocode.ts
// @seance-version 37

export const SeancePlugin = async ({ $ }) => {
  const socket = process.env.SEANCE_SOCKET_PATH;
  if (!socket) return {};
  if (process.env.SEANCE_MIMOCODE_HOOKS_DISABLED === "1") return {};

  const binDir = process.env.SEANCE_BIN_DIR;
  const seanceBin = binDir
    ? binDir.replace(/\/share\/bin$/, "/bin/seance")
    : "seance";

  const surfaceId = process.env.SEANCE_SURFACE_ID;
  const workspaceId = process.env.SEANCE_WORKSPACE_ID;
  let currentSessionId: string | undefined;
  let sessionIdle = false;
  let permissionPending = false;
  let childSessions: Set<string> = new Set();
  let subagentCount = 0;
  const shEscape = (s: string) => s.replace(/'/g, "'\\''");

  async function hook(event: string, extra: Record<string, unknown> = {}) {
    const payload = JSON.stringify({
      session_id: currentSessionId,
      workspace_id: workspaceId,
      surface_id: surfaceId,
      subagent_count: subagentCount,
      ...extra,
    });
    await $`echo '${shEscape(payload)}' | ${seanceBin} ctl mimocode-hook ${event} >/dev/null`;
  }

  async function updateCounts() {
    const payload = JSON.stringify({
      workspace_id: workspaceId,
      subagent_count: subagentCount,
      background_count: 0,
    });
    await $`echo '${shEscape(payload)}' | ${seanceBin} ctl subagent-update >/dev/null`;
  }

  return {
    event: async ({ event }) => {
      const eventSessionId = event.properties?.sessionID;
      switch (event.type) {
        case "session.created":
          if (!currentSessionId) {
            currentSessionId = event.properties.sessionID;
            sessionIdle = false;
            await hook("session-start");
            await hook("prompt-submit");
          }
          break;

        case "session.updated":
          if (!currentSessionId && eventSessionId) {
            currentSessionId = eventSessionId;
            sessionIdle = false;
            childSessions.clear();
            subagentCount = 0;
            await hook("session-start");
            await hook("prompt-submit");
          }
          break;

        case "session.idle":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            if (permissionPending) {
              permissionPending = false;
            } else {
              sessionIdle = true;
              await hook("stop");
            }
          }
          break;

        case "session.error":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            childSessions.clear();
            subagentCount = 0;
            await updateCounts();
            await hook("session-end");
            currentSessionId = undefined;
          } else if (childSessions.has(eventSessionId)) {
            childSessions.delete(eventSessionId);
            subagentCount = Math.max(0, subagentCount - 1);
            await updateCounts();
          }
          break;

        case "session.status":
          if (!eventSessionId || eventSessionId === currentSessionId) {
            if (event.properties.status.type === "busy") {
              sessionIdle = false;
              permissionPending = false;
              await hook("prompt-submit");
            }
          }
          break;

        case "permission.asked":
          if (!sessionIdle && (!eventSessionId || eventSessionId === currentSessionId)) {
            permissionPending = true;
            const permType = event.properties?.permission ?? "unknown";
            const patterns = event.properties?.patterns;
            const detail = Array.isArray(patterns) && patterns.length > 0
              ? `${permType}: ${patterns.join(", ")}`
              : String(permType);
            await hook("notification", {
              message: detail,
            });
          }
          break;

        case "permission.replied":
          permissionPending = false;
          break;

        case "actor.registered":
          {
            const mode = event.properties?.mode;
            const agent = event.properties?.agent;
            const actorID = event.properties?.actorID;
            if (mode === "subagent" && agent !== "checkpoint-writer" && agent !== "compaction") {
              if (actorID && !childSessions.has(actorID)) {
                childSessions.add(actorID);
                subagentCount++;
                await updateCounts();
              }
            }
          }
          break;

        case "actor.status":
          {
            const actorID = event.properties?.actorID;
            const status = event.properties?.status;
            if (status === "idle" && actorID && childSessions.has(actorID)) {
              childSessions.delete(actorID);
              subagentCount = Math.max(0, subagentCount - 1);
              await updateCounts();
            }
          }
          break;
      }
    },

    "tool.execute.before": async (input: { tool: string; sessionID: string; callID: string }) => {
      if (!input.sessionID || input.sessionID === currentSessionId) {
        await hook("pre-tool-use", { tool_name: input.tool });
      }
    },

    "tool.execute.after": async (input: { tool: string; sessionID: string; callID: string; args: any }) => {
      if (!input.sessionID || input.sessionID === currentSessionId) {
        await hook("post-tool-use", { tool_name: input.tool });
      }
    },
  };
};
