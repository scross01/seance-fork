// Séance plugin for MiMo Code
// Copy to ~/.config/mimocode/plugins/seance-mimocode.ts
// @seance-version 9

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
  let statusSessionId: string | undefined;
  const shEscape = (s: string) => s.replace(/'/g, "'\\''");

  async function hook(event: string, extra: Record<string, unknown> = {}) {
    const payload = JSON.stringify({
      session_id: currentSessionId,
      workspace_id: workspaceId,
      surface_id: surfaceId,
      ...extra,
    });
    await $`echo '${shEscape(payload)}' | ${seanceBin} ctl mimocode-hook ${event} >/dev/null`;
  }

  return {
    event: async ({ event }) => {
      const eventSessionId = event.properties?.sessionID;

      switch (event.type) {
        case "session.created":
          if (currentSessionId) {
            await hook("session-end");
          }
          currentSessionId = event.properties.sessionID;
          await hook("session-start");
          break;
        case "session.idle":
          if (!eventSessionId || eventSessionId === currentSessionId || eventSessionId === statusSessionId) {
            await hook("stop");
          }
          break;
        case "session.error":
          if (!eventSessionId || eventSessionId === currentSessionId || eventSessionId === statusSessionId) {
            await hook("session-end");
            currentSessionId = undefined;
            statusSessionId = undefined;
          }
          break;
        case "session.status":
          if (eventSessionId && eventSessionId !== currentSessionId && !statusSessionId) {
            statusSessionId = eventSessionId;
          }
          if (!eventSessionId || eventSessionId === currentSessionId || eventSessionId === statusSessionId) {
            if (event.properties.status.type === "busy") {
              await hook("prompt-submit");
            } else if (event.properties.status.type === "idle") {
              await hook("stop");
            }
          }
          break;
        case "permission.asked":
          await hook("notification", {
            message: "MiMo Code needs your permission",
          });
          break;
      }
    },
    "tool.execute.before": async (input) => {
      await hook("pre-tool-use", { tool_name: input.tool });
    },
    "tool.execute.after": async (input) => {
      await hook("post-tool-use", { tool_name: input.tool });
    },
  };
};
