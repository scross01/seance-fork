// @seance-version 40

const INFRA_AGENTS = new Set([
  "main",
  "summary",
  "title",
  "checkpoint-writer",
  "dream",
  "distill",
  "compaction",
]);

export default {
  id: "seance-mimocode",
  server: async ({ $ }) => {
    const socket = process.env.SEANCE_SOCKET_PATH;
    if (!socket) return {};
    if (process.env.SEANCE_MIMOCODE_HOOKS_DISABLED === "1") return {};

    const seanceBin = process.env.SEANCE_OPENCODE_BIN ?? "seance";
    const surfaceId = process.env.SEANCE_SURFACE_ID;
    const workspaceId = process.env.SEANCE_WORKSPACE_ID;
    let currentSessionId: string | undefined;
    let subagentCount = 0;
    let backgroundCount = 0;
    const childActors: Set<string> = new Set();
    const backgroundActors: Set<string> = new Set();
    const shEscape = (s: string) => s.replace(/'/g, "'\\''");
    // One server process per pane launch: its cwd is the pane's launch directory.
    const cwd = process.cwd();

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
        background_count: backgroundCount,
      });
      await $`echo '${shEscape(payload)}' | ${seanceBin} ctl subagent-update >/dev/null`;
    }

    async function adoptSession(sessionId: string | undefined) {
      if (!sessionId || currentSessionId) return;
      currentSessionId = sessionId;
      await hook("session-start", { cwd });
      await hook("prompt-submit");
    }

    return {
      "session.pre": async (input: { sessionID: string }) => {
        if (input.sessionID === currentSessionId) {
          await hook("prompt-submit");
        }
      },

      "session.post": async (input: {
        sessionID: string;
        outcome: "completed" | "error" | "cancelled";
        finalText?: string;
      }) => {
        if (input.sessionID !== currentSessionId) return;
        if (input.outcome === "error") {
          childActors.clear();
          backgroundActors.clear();
          subagentCount = 0;
          backgroundCount = 0;
          await updateCounts();
          await hook("session-end");
          currentSessionId = undefined;
          return;
        }
        const text = typeof input.finalText === "string" ? input.finalText.trim() : "";
        if (text) {
          await hook("stop", { cwd, message: text.slice(0, 500) });
        } else {
          await hook("stop", { cwd });
        }
      },

      "actor.postStop": {
        // The default matcher also excludes general/build/explore, which are
        // real subagents Séance must count, so we match explicitly instead.
        matcher: {
          mode: "subagent",
          agentType: { excludeOnly: [...INFRA_AGENTS] },
        },
        run: async (input: { actorID: string }) => {
          if (!childActors.has(input.actorID)) return;
          childActors.delete(input.actorID);
          subagentCount = Math.max(0, subagentCount - 1);
          if (backgroundActors.delete(input.actorID)) {
            backgroundCount = Math.max(0, backgroundCount - 1);
          }
          await updateCounts();
          await hook("prompt-submit");
        },
      },

      event: async ({ event }: { event: any }) => {
        const props = event.properties ?? {};
        const eventSessionId = props.sessionID;
        switch (event.type) {
          case "session.created":
            await adoptSession(eventSessionId);
            break;

          case "session.updated":
            await adoptSession(eventSessionId);
            break;

          case "permission.asked":
            if (!eventSessionId || eventSessionId === currentSessionId) {
              const permType = props.permission ?? "unknown";
              const patterns = props.patterns;
              const detail =
                Array.isArray(patterns) && patterns.length > 0
                  ? `${permType}: ${patterns.join(", ")}`
                  : String(permType);
              await hook("notification", { message: detail });
            }
            break;

          case "actor.registered":
            if (
              props.mode === "subagent" &&
              typeof props.agent === "string" &&
              !INFRA_AGENTS.has(props.agent) &&
              props.actorID &&
              !childActors.has(props.actorID)
            ) {
              childActors.add(props.actorID);
              subagentCount++;
              if (props.background === true) {
                backgroundActors.add(props.actorID);
                backgroundCount++;
              }
              await updateCounts();
              await hook("prompt-submit");
            }
            break;
        }
      },

      "tool.execute.before": async (input: { tool: string; sessionID: string }) => {
        if (!input.sessionID || input.sessionID === currentSessionId) {
          await hook("pre-tool-use", { tool_name: input.tool });
        }
      },

      "tool.execute.after": async (input: { tool: string; sessionID: string }) => {
        if (!input.sessionID || input.sessionID === currentSessionId) {
          await hook("post-tool-use", { tool_name: input.tool });
        }
      },
    };
  },
};
