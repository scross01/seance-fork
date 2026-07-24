---
layout: page
---

<style>
/* ── Layout ── */
.page-wrap {
  max-width: 1100px;
  margin: 0 auto;
  padding: 0 24px;
}

/* ── Hero ── */
.hero-section {
  padding: 100px 0 60px;
  text-align: center;
}
.hero-badge {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  background: rgba(245, 213, 71, 0.08);
  border: 1px solid rgba(245, 213, 71, 0.2);
  border-radius: 999px;
  padding: 6px 18px;
  font-size: 13px;
  color: #F9A825;
  margin-bottom: 28px;
  letter-spacing: 0.02em;
}
.hero-badge::before {
  content: '';
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #F9A825;
}
.hero-section h1 {
  font-size: clamp(40px, 6vw, 72px);
  line-height: 1.05;
  letter-spacing: -0.03em;
  font-weight: 800;
  margin: 0 0 24px;
}
.hero-section h1 .brand-name {
  display: block;
  background: linear-gradient(135deg, #F5D547 0%, #F9A825 35%, #50c6f7 65%, #1d8cc4 100%);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}
.hero-sub {
  font-size: 20px;
  color: var(--vp-c-text-2);
  margin: 0 auto 40px;
  line-height: 1.6;
  max-width: 640px;
  text-wrap: pretty;
}
.hero-actions {
  display: flex;
  justify-content: center;
  flex-wrap: wrap;
  gap: 14px;
  margin-bottom: 56px;
}

/* ── Demo video ── */
.demo-wrap {
  max-width: 860px;
  margin: 0 auto;
}
.demo-frame {
  position: relative;
  background: #0c0f14;
  border: 1px solid rgba(80, 198, 247, 0.12);
  border-radius: 16px;
  padding: 12px;
  box-shadow:
    0 0 0 1px rgba(80, 198, 247, 0.05) inset,
    0 40px 100px rgba(0,0,0,.5),
    0 0 120px rgba(80, 198, 247, 0.04);
}
.demo-frame .titlebar {
  height: 28px;
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 0 12px 12px;
}
.demo-frame .dot {
  width: 11px;
  height: 11px;
  border-radius: 50%;
  background: #2a2f38;
}
.demo-frame video,
.demo-frame img {
  display: block;
  width: 100%;
  height: auto;
  border-radius: 10px;
  background: #000;
}

/* ── Section chrome ── */
.section {
  padding: 80px 0;
}
.section + .section {
  border-top: 1px solid var(--vp-c-border);
}
.section-eyebrow {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.14em;
  color: var(--vp-c-brand-1);
  margin-bottom: 14px;
}
.section-title {
  font-size: clamp(28px, 4vw, 40px);
  font-weight: 700;
  letter-spacing: -0.025em;
  line-height: 1.15;
  margin: 0 0 56px;
  max-width: 600px;
  text-wrap: balance;
}

/* ── Feature cards ── */
.features-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 20px;
}
.feature-card {
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-border);
  border-radius: 14px;
  padding: 32px 28px;
  transition: border-color 0.2s, box-shadow 0.2s;
}
.feature-card:hover {
  border-color: rgba(80, 198, 247, 0.25);
  box-shadow: 0 8px 32px rgba(0,0,0,.2);
}
.feature-icon {
  width: 40px;
  height: 40px;
  border-radius: 10px;
  background: rgba(80, 198, 247, 0.1);
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 20px;
  color: var(--vp-c-brand-1);
}
.feature-icon svg {
  width: 20px;
  height: 20px;
}
.feature-card h3 {
  margin: 0 0 10px;
  font-size: 17px;
  font-weight: 600;
  letter-spacing: -0.01em;
}
.feature-card p {
  margin: 0;
  color: var(--vp-c-text-2);
  font-size: 14.5px;
  line-height: 1.65;
}

/* ── Comparison ── */
.comparison-wrap {
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-border);
  border-radius: 16px;
  overflow: hidden;
}
.comparison-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 15px;
}
.comparison-table thead {
  background: rgba(80, 198, 247, 0.05);
}
.comparison-table th {
  padding: 18px 28px;
  text-align: left;
  font-weight: 600;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--vp-c-text-2);
  border-bottom: 1px solid var(--vp-c-border);
}
.comparison-table th.col-original {
  color: #6b7280;
}
.comparison-table th.col-fork {
  color: #F9A825;
}
.comparison-table td {
  padding: 14px 28px;
  border-bottom: 1px solid rgba(80, 198, 247, 0.06);
  vertical-align: middle;
}
.comparison-table tr:last-child td {
  border-bottom: none;
}
.comparison-table .check {
  color: #22c55e;
  font-weight: 700;
  font-size: 16px;
}
.comparison-table .dash {
  color: var(--vp-c-text-3);
}
.comparison-table td.feature-name {
  font-weight: 500;
}

/* ── Attribution ── */
.attribution-card {
  background: linear-gradient(135deg, rgba(245, 213, 71, 0.04) 0%, rgba(80, 198, 247, 0.04) 100%);
  border: 1px solid var(--vp-c-border);
  border-radius: 16px;
  padding: 48px;
  text-align: center;
}
.attribution-card h3 {
  font-size: 22px;
  margin: 0 0 14px;
  letter-spacing: -0.01em;
}
.attribution-card p {
  color: var(--vp-c-text-2);
  margin: 0 auto 24px;
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
  border-radius: 14px;
  padding: 24px;
}
.install-card h4 {
  margin: 0 0 14px;
  font-size: 13px;
  color: var(--vp-c-text-2);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

/* ── Responsive ── */
@media (max-width: 768px) {
  .features-grid {
    grid-template-columns: 1fr;
  }
  .install-grid {
    grid-template-columns: 1fr;
  }
  .comparison-wrap {
    overflow-x: auto;
  }
  .attribution-card {
    padding: 32px 24px;
  }
}
</style>

<div class="page-wrap">

<!-- ─── Hero ─── -->
<section class="hero-section">
  <h1>
    <span class="brand-name">Séance-fork</span>
  </h1>
  <p class="hero-sub">
    A Linux-native terminal multiplexer that runs AI coding agents in parallel.
    Built on Séance with expanded agent support.
    GPU-accelerated, scriptable, zero-config.
  </p>
  <div class="hero-actions">
    <a class="vp-button brand" href="/seance-fork/guide/installation">Get Started</a>
    <a class="vp-button alt" href="https://github.com/scross01/seance-fork">View on GitHub</a>
    <a class="vp-button alt" href="https://github.com/scross01/seance-fork/releases">Releases</a>
  </div>
  <div class="demo-wrap">
    <div class="demo-frame">
      <div class="titlebar">
        <div class="dot"></div><div class="dot"></div><div class="dot"></div>
      </div>
      <video autoplay muted loop playsinline preload="metadata" poster="./demo-poster.jpg">
        <source src="./demo.mp4" type="video/mp4">
        <img src="./demo.gif" alt="Séance-fork in action">
      </video>
    </div>
  </div>
</section>

<!-- ─── Features ─── -->
<section class="section">
  <div class="section-eyebrow">What it does</div>
  <h2 class="section-title">A multiplexer that understands what's running inside it.</h2>
  <div class="features-grid">
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="9"/></svg>
      </div>
      <h3>Real-time agent status</h3>
      <p>Running, waiting for permission, idle — live in the sidebar. Desktop notifications on permission prompts and completions.</p>
    </div>
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7h18M7 12h14M3 17h18"/></svg>
      </div>
      <h3>Scrolling pane layout</h3>
      <p>A horizontal strip you scroll through, borrowed from niri. Long, linear agent sessions fit better than tiling grids.</p>
    </div>
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
      </div>
      <h3>Scriptable over a socket</h3>
      <p>Every GUI action has a <code>seance ctl</code> equivalent. JSON output, Unix socket. Agents can drive the multiplexer themselves.</p>
    </div>
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L4 6l8 4 8-4-8-4z"/><path d="M4 12l8 4 8-4"/><path d="M4 18l8 4 8-4"/></svg>
      </div>
      <h3>Zero-config hook injection</h3>
      <p>Open a supported agent and it's tracked. The multiplexer injects hooks into each session without touching your dotfiles.</p>
    </div>
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/></svg>
      </div>
      <h3>GPU-accelerated rendering</h3>
      <p>Built on Ghostty as a library. Fast, correct terminal rendering with ligatures, Unicode, and full GPU acceleration.</p>
    </div>
    <div class="feature-card">
      <div class="feature-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 7l-8 8-4-4"/><rect x="3" y="3" width="18" height="18" rx="3"/></svg>
      </div>
      <h3>And the essentials</h3>
      <p>Workspaces, session persistence, tabs within columns, command palette, focus-follows-mouse, blur and transparency.</p>
    </div>
  </div>
</section>

<!-- ─── Comparison ─── -->
<section class="section">
  <div class="section-eyebrow">What's different</div>
  <h2 class="section-title">Original Séance vs. Séance-fork</h2>
  <div class="comparison-wrap">
    <table class="comparison-table">
      <thead>
        <tr>
          <th>Feature</th>
          <th class="col-original">Original Séance</th>
          <th class="col-fork">Séance-fork</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="feature-name">Scrolling panes</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">GPU rendering</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Scriptable socket</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Claude Code</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Codebuff</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Codex</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Freebuff</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Hermes Agent</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Kilo Code</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">MiMo Code</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Mistral Vibe</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">OpenCode</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Pi Agent</td>
          <td><span class="check">&#10003;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
        <tr>
          <td class="feature-name">Poolside Agent CLI</td>
          <td><span class="dash">&mdash;</span></td>
          <td><span class="check">&#10003;</span></td>
        </tr>
      </tbody>
    </table>
  </div>
</section>

<!-- ─── Attribution ─── -->
<section class="section">
  <div class="attribution-card">
    <h3>Built on the work of no1msd</h3>
    <p>
      Séance-fork is a community fork of
      <a href="https://github.com/no1msd/seance">Séance by no1msd</a>.
      The original project laid the groundwork for a Linux-native AI agent multiplexer —
      we're grateful for that foundation and continue to maintain compatibility with its core features.
    </p>
    <a class="vp-button alt" href="https://github.com/no1msd/seance">Original Séance &rarr;</a>
  </div>
</section>

<!-- ─── Install ─── -->
<section class="section">
  <div class="section-eyebrow">Install</div>
  <h2 class="section-title">Linux. GTK4, libadwaita, OpenGL 4.3+.</h2>
  <div class="install-grid">
    <div class="install-card">
      <h4>AppImage</h4>
      <div class="vp-doc">
        <div class="language-bash active"><pre><span class="line"><span class="pfx">$ </span>chmod +x seance-*-x86_64.AppImage</span>
<span class="line"><span class="pfx">$ </span>./seance-*-x86_64.AppImage</span></pre></div>
      </div>
    </div>
    <div class="install-card">
      <h4>From source</h4>
      <div class="vp-doc">
        <div class="language-bash active"><pre><span class="line"><span class="pfx">$ </span>git clone --recursive https://github.com/scross01/seance-fork.git</span>
<span class="line"><span class="pfx">$ </span>cd seance && zig build</span></pre></div>
      </div>
    </div>
  </div>
</section>

</div>
