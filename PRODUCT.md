# Product

<!-- impeccable:product-schema 1 -->

## Platform

linux-desktop

Native GTK4/libadwaita desktop application for Linux (X11 and Wayland). Not web, iOS, Android, or adaptive; the schema's four values do not cover native Linux desktop, so the truthful value is recorded here.

## Users

Linux developers running multiple AI coding agents in parallel. Their job: monitor live agent status (working, waiting for permission, idle) across many concurrent sessions, respond to permission prompts and completions without watching every pane, and orchestrate agents programmatically. They typically work on GNOME or scrolling tiling WMs (niri and similar) and run long, linear agent sessions.

## Product Purpose

Séance-fork is a scrolling terminal multiplexer that tracks AI coding agents. Panes are arranged in a horizontal strip (layout model borrowed from niri); agent sessions inside panes are auto-detected and their status surfaced live in the sidebar, with desktop notifications and unread tracking for permission requests and completions.

Success means: it remains the maintainer's daily driver. Outside adoption is welcome but not a design driver.

## Positioning

The tracking superset of Séance: it stays compatible with no1msd/seance and merges upstream regularly, while offering the widest auto-detected agent coverage of any Linux agent multiplexer (12 agents, zero config) and the only in-app browser panel. Both are co-headline differentiators; neither outranks the other.

## Operating Context

- Long-running, multi-agent sessions on a Linux desktop; panes accumulate and are scrolled through horizontally rather than tiled.
- Notification-driven workflow: permission prompts and task completions arrive as desktop notifications with unread tracking, so the user can leave agents unattended.
- Scripting context: `seance ctl` over a Unix socket exposes every action with JSON output; AI agents themselves drive the multiplexer via the bundled skill file (`skills/seance-skill.md`).
- Agent setup rituals the product performs on the user's behalf: wrapper scripts for Claude Code/Codex/Pi, auto-installed plugins for OpenCode/Kilo/MiMo/Hermes, TOML hooks for Vibe, a status-line callback for Antigravity (with `settings.json.seance-backup` preserved). Codex requires a one-time `/hooks` review per hook-definition change.
- Distributed as an AppImage (requires host `libfuse2` and GPU drivers) and built from source with Zig 0.16.x.

## Capabilities and Constraints

Confirmed functionality: auto-detection and live status tracking for Claude Code, Codex, Pi, OpenCode, Kilo Code, MiMo Code, Mistral Vibe, Hermes Agent, Poolside, Antigravity CLI, Codebuff, and Freebuff; scrolling pane layout with workspaces, tabs within columns, session persistence across restarts, command palette, focus-follows-mouse, fullscreen; WebKitGTK in-app browser panels with dev tools, JS eval, session restore, and ctl commands; full `seance ctl` IPC with JSON output.

Technical constraints: Linux only (X11/Wayland); GTK4 + libadwaita; desktop OpenGL 4.3+ (no GLES, no Vulkan); GPU terminal rendering via libghostty (Ghostty as a library, patched fork at `no1msd/ghostty` branch `seance-patches`); Zig 0.16.x; `inotify-tools` required for Poolside/Codebuff/Freebuff status monitoring.

Terminology: pane, workspace, column, sidebar status (working / waiting for permission / idle, surfaced as "Needs input"), `seance ctl`.

Integration behavior future work must preserve: tracking never silently rewrites user configuration — original files are backed up, existing config/auth/history stay in place, and every integration has a Settings toggle plus a `config.toml` opt-out under `[behavior]`. Disabled integrations are respected.

Known tracking limits: remote `opencode attach` and `--pure` launches are untracked; Antigravity tracking covers only the active TUI's reported state.

## Brand Commitments

- Name: **Séance-fork** is the durable brand, recorded as binding.
- Attribution: always credit Séance by no1msd as the original; the fork presents itself as a community superset, never a rival or replacement.
- Tagline: "A scrolling terminal multiplexer that tracks your AI coding agents."
- Logo: `resources/icons/hicolor/scalable/apps/com.seance-fork.app.svg`.
- License: MIT.
- Inspirations acknowledged publicly: Ghostty (terminal emulation), cmux and niri (layout/interaction model).

## Evidence on Hand

- `demo.gif` — product demo animation used in the README.
- `docs/` — VitePress documentation site, including a maintained comparison table against Séance (orig), Limux, PrettyMux, and Better Agent Terminal (`docs/index.md`).
- GitHub Releases with AppImage builds (`seance-*-x86_64.AppImage`).
- `skills/seance-skill.md` — agent-facing reference for the `seance ctl` API.
- Per-agent documentation under `docs/agents/`.

No testimonials, benchmarks, press, or customer proof exist. Future work must not fabricate any.

## Product Principles

1. **Superset, never rival.** Compatibility with upstream Séance is a feature; additions layer on top and merge cleanly.
2. **Zero-config tracking.** Open a supported agent in a pane and it is tracked. Adding an agent is a hook config, never a rewrite or special-casing of a favored agent.
3. **Consent in integration.** Auto-installed hooks and plugins preserve existing config, keep backups, and are always opt-out via Settings or `config.toml`.
4. **Scriptable parity.** Every GUI action has a `seance ctl` equivalent with JSON output, so humans and agents share one control surface.
5. **Linux-native, telemetry-free.** GTK4/libadwaita and GPU rendering are identity, not implementation detail. No telemetry, ever.
