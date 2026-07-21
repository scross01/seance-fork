// Séance plugin for OpenCode
// Copy to ~/.config/opencode/plugins/seance-opencode.ts
// @seance-version 4

export const SeancePlugin = async ({ $ }) => {
  const socket = process.env.SEANCE_SOCKET_PATH;
  if (!socket) return {};
  if (process.env.SEANCE_OPENCODE_HOOKS_DISABLED === "1") return {};

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
    await $`echo '${shEscape(payload)}' | ${seanceBin} ctl opencode-hook ${event} >/dev/null`;
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
      const eventSessionId = event.properties?.sessionID ?? event.properties?.info?.id;
      switch (event.type) {
        case "session.created":
          if (!currentSessionId) {
            currentSessionId = eventSessionId;
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
          } else if (eventSessionId && eventSessionId !== currentSessionId) {
            const parentID = event.properties?.info?.parentID;
            if (parentID && parentID === currentSessionId) {
              if (!childSessions.has(eventSessionId)) {
                childSessions.add(eventSessionId);
                subagentCount++;
                await updateCounts();
              }
            }
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
          } else if (childSessions.has(eventSessionId)) {
            childSessions.delete(eventSessionId);
            subagentCount = Math.max(0, subagentCount - 1);
            await updateCounts();
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
