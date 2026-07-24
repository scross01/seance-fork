---
layout: home

hero:
  name: Séance-fork
  text: Terminal multiplexer for AI coding agents
  tagline: GPU-accelerated rendering via libghostty. Scrolling layout from niri. Auto-detects and tracks every agent session — zero config needed.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/installation
    - theme: alt
      text: View on GitHub
      link: https://github.com/scross01/seance-fork
    - theme: alt
      text: Releases
      link: https://github.com/scross01/seance-fork/releases

features:
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="9"/></svg>
    title: Real-time agent status
    details: Running, waiting for permission, idle — live in the sidebar. Desktop notifications on permission prompts and completions.
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7h18M7 12h14M3 17h18"/></svg>
    title: Scrolling pane layout
    details: A horizontal strip you scroll through, borrowed from niri. Long, linear agent sessions fit better than tiling grids.
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    title: Scriptable over a socket
    details: Every GUI action has a seance ctl equivalent. JSON output, Unix socket. Agents can drive the multiplexer themselves.
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L4 6l8 4 8-4-8-4z"/><path d="M4 12l8 4 8-4"/><path d="M4 18l8 4 8-4"/></svg>
    title: Zero-config hook injection
    details: Open a supported agent and it's tracked. The multiplexer injects hooks into each session without touching your dotfiles.
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/></svg>
    title: GPU-accelerated rendering
    details: Built on Ghostty as a library. Fast, correct terminal rendering with ligatures, Unicode, and full GPU acceleration.
  - icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 7l-8 8-4-4"/><rect x="3" y="3" width="18" height="18" rx="3"/></svg>
    title: And the essentials
    details: Workspaces, session persistence, tabs within columns, command palette, focus-follows-mouse, blur and transparency.
---

<style>
/* ── Match VitePress container width ── */
.comparison-section,
.attribution-section,
.install-section {
  max-width: 1152px;
  margin: 0 auto;
  padding: 60px 24px 0;
}

/* ── Section headings ── */
.section-eyebrow {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.14em;
  color: var(--vp-c-brand-1);
  margin-bottom: 12px;
}

.section-title {
  font-size: clamp(24px, 3.5vw, 36px);
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.2;
  margin: 0 0 40px;
}

/* ── Comparison table ── */
.comparison-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-size: 15px;
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-border);
  border-radius: 12px;
  overflow: hidden;
}

.comparison-table thead {
  background: var(--vp-c-bg-alt);
}

.comparison-table th {
  padding: 16px 14px;
  text-align: left;
  font-weight: 600;
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--vp-c-text-2);
  border-bottom: 1px solid var(--vp-c-border);
  vertical-align: bottom;
  width: 14.4%;
}

.comparison-table th.col-feature {
  width: 28%;
  text-transform: none;
  letter-spacing: 0;
  font-size: 13px;
}

.comparison-table th a {
  color: inherit;
  text-decoration: none;
  border-bottom: 1px dashed var(--vp-c-divider);
}

.comparison-table th a:hover {
  border-bottom-color: currentColor;
}

.comparison-table th.col-fork {
  color: var(--vp-c-brand-1);
}

.dark .comparison-table th.col-fork {
  color: #F9A825;
}

.comparison-table tbody td:nth-child(3) {
  background: var(--vp-c-brand-soft);
}

.comparison-table td {
  padding: 11px 14px;
  border-bottom: 1px solid var(--vp-c-border);
}

.comparison-table td:not(:first-child) {
  text-align: center;
}

.comparison-table td:first-child {
  font-weight: 500;
}

.comparison-note {
  margin: 20px 0 0;
  font-size: 13px;
  line-height: 1.65;
  color: var(--vp-c-text-2);
}

.comparison-note a {
  color: var(--vp-c-brand-1);
  text-decoration: none;
}

.comparison-note a:hover {
  text-decoration: underline;
}

.comparison-table tr:last-child td {
  border-bottom: none;
}

.comparison-table .check {
  color: #22c55e;
  font-weight: 700;
}

.comparison-table .dash {
  color: var(--vp-c-text-3);
}

/* ── Attribution ── */
.attribution-card {
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-border);
  border-radius: 12px;
  padding: 40px;
  text-align: center;
}

.attribution-card h3 {
  font-size: 20px;
  margin: 0 0 12px;
  letter-spacing: -0.01em;
}

.attribution-card p {
  color: var(--vp-c-text-2);
  margin: 0 auto 20px;
  max-width: 560px;
  line-height: 1.65;
  font-size: 15px;
}

/* ── Install ── */
.install-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
}

.install-card {
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-border);
  border-radius: 12px;
  padding: 24px;
}

.install-card h4 {
  margin: 0 0 14px;
  font-size: 12px;
  color: var(--vp-c-text-2);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.install-link {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  margin: 0 0 12px;
  font-size: 14px;
  font-weight: 600;
  color: var(--vp-c-brand-1);
  text-decoration: none;
  border-bottom: 1px solid transparent;
  transition: border-color 0.2s;
}

.install-link:hover {
  border-bottom-color: var(--vp-c-brand-1);
}

@media (max-width: 768px) {
  .install-grid {
    grid-template-columns: 1fr;
  }
}
</style>

<div class="install-section">
  <div class="section-eyebrow">Install</div>
  <h2 class="section-title">Linux. GTK4, libadwaita, OpenGL 4.3+.</h2>
  <div class="install-grid">
    <div class="install-card">
      <h4>AppImage</h4>
      <a class="install-link" href="https://github.com/scross01/seance-fork/releases/latest">
        &darr; Download the latest AppImage
      </a>
      <div class="vp-doc">
        <div class="language-bash active"><pre><span class="line"><span class="pfx">$ </span>chmod +x seance-*-x86_64.AppImage</span>
<span class="line"><span class="pfx">$ </span>./seance-*-x86_64.AppImage</span></pre></div>
      </div>
    </div>
    <div class="install-card">
      <h4>From source</h4>
      <div class="vp-doc">
        <div class="language-bash active"><pre><span class="line"><span class="pfx">$ </span>git clone --recursive https://github.com/scross01/seance-fork.git</span>
<span class="line"><span class="pfx">$ </span>cd seance-fork && make build</span></pre></div>
      </div>
    </div>
  </div>
</div>

<div class="comparison-section">
  <div class="section-eyebrow">What's different</div>
  <h2 class="section-title">Séance-fork vs. other Linux agent terminals</h2>
  <table class="comparison-table">
    <thead>
      <tr>
        <th class="col-feature">Feature</th>
        <th><a href="https://github.com/no1msd/seance" title="Original Séance by no1msd">Séance (orig)</a></th>
        <th class="col-fork">Séance-fork</th>
        <th><a href="https://github.com/am-will/limux">Limux</a></th>
        <th><a href="https://github.com/patcito/prettymux">PrettyMux</a></th>
        <th><a href="https://github.com/tony1223/better-agent-terminal">Better Agent Terminal</a></th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>Scrolling pane layout</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>GPU rendering (libghostty)</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Scriptable control socket</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Windows / macOS builds</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
      </tr>
      <tr>
        <td>Claude Code</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
      </tr>
      <tr>
        <td>Codex</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
      </tr>
      <tr>
        <td>Gemini CLI</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Codebuff</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Freebuff</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Hermes Agent</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Kilo Code</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>MiMo Code</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Mistral Vibe</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>OpenCode</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Pi Agent</td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
      <tr>
        <td>Poolside Agent CLI</td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="check">&#10003;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
        <td><span class="dash">&mdash;</span></td>
      </tr>
    </tbody>
  </table>
  <p class="comparison-note">
    Séance-fork auto-detects every agent above with zero config.
    <a href="https://github.com/am-will/limux">Limux</a> ships hooks for Codex, Claude Code, and Gemini CLI;
    <a href="https://github.com/tony1223/better-agent-terminal">Better Agent Terminal</a> builds Claude Code and Codex in directly.
    <a href="https://github.com/patcito/prettymux">PrettyMux</a> exposes a generic agent-status socket any agent can call, but ships no
    built-in auto-detection, so it isn't checked for specific agents. The others all use split or tabbed
    pane layouts rather than a scrolling strip. Better Agent Terminal is a Tauri/webview app (xterm.js),
    not GPU-rendered, and is driven by a remote WebSocket server instead of a local control socket.
  </p>
</div>

<div class="attribution-section">
  <div class="attribution-card">
    <h3>Built on the work of no1msd</h3>
    <p>
      Séance-fork is a community fork of
      <a href="https://github.com/no1msd/seance">Séance by no1msd</a>.
      The original project laid the groundwork for a Linux-native AI agent multiplexer —
      we're grateful for that foundation and continue to maintain compatibility with its core features.
    </p>
    <a class="VPButton medium alt" href="https://github.com/no1msd/seance">Original Séance &rarr;</a>
  </div>
</div>
