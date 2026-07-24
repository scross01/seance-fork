# Séance-fork Documentation Site

## [S1] Problem

The project has a single-page `docs/index.html` and several agent-specific markdown files (`docs/mimocode.md`, `docs/vibecode.md`, etc.). There is no structured documentation site — users must rely on the README and scattered markdown files. The goal is to create a comprehensive static docs site published at `https://scross01.github.io/seance-fork` covering user guides, developer docs, agent integration references, and a feature matrix.

## [S2] Solution overview

Replace the existing `docs/index.html` with a VitePress static site. The site uses a Blue + Gold dual theme derived from the `fork.svg` icon, deploys via GitHub Actions to GitHub Pages, and organizes content into four sections: Guide (user docs), Agents (per-agent integration), Dev (architecture/technical), and Reference (feature matrix, CLI reference).

## [S3] Static site generator

**VitePress** (Vue-powered, Markdown-native). Reasons:
- Fast cold builds and HMR for local dev
- Built-in local search, dark mode, responsive layout
- Markdown-native with Vue component support for interactive elements
- Active ecosystem, well-maintained

## [S4] Deployment

**GitHub Actions + Pages.** A workflow file `.github/workflows/docs.yml` builds VitePress on push to `main` and deploys the `docs/.vitepress/dist` output to GitHub Pages. The site is served at `https://scross01.github.io/seance-fork` (base path `/seance-fork/`).

## [S5] Theme and branding

Colors derived from `docs/fork.svg`:

| Role | Color | Source |
|------|-------|--------|
| Primary accent | `#50c6f7` | Inner W radial gradient start |
| Primary deep | `#1d8cc4` | Inner W radial gradient end |
| Secondary accent | `#F5D547` | Outer ring gradient start |
| Secondary mid | `#F9A825` | Outer ring gradient mid |
| Secondary deep | `#F57C00` | Outer ring gradient end |
| Background | `#0a0d12` | Existing landing page |
| Surface | `#0f141b` | Existing landing page |
| Card | `#141a22` | Existing landing page |
| Border | `rgba(80, 198, 247, 0.14)` | Existing landing page |
| Text | `#e6ebf2` | Existing landing page |
| Text dim | `#8a96a8` | Existing landing page |

Dark theme only (no light mode toggle) — matches the terminal aesthetic.

## [S6] Site structure

```
docs/
├── .vitepress/
│   ├── config.ts
│   └── theme/
│       ├── index.ts
│       └── custom.css
├── index.md                    # Landing page
├── guide/
│   ├── installation.md
│   ├── quickstart.md
│   ├── configuration.md
│   ├── keybindings.md
│   └── cli.md
├── agents/
│   ├── overview.md
│   ├── claude-code.md
│   ├── opencode.md
│   ├── kilo.md
│   ├── mimocode.md
│   ├── vibe.md
│   ├── hermes.md
│   └── adding-agents.md
├── dev/
│   ├── architecture.md
│   ├── lifecycle-events.md
│   ├── plugin-system.md
│   └── building.md
├── reference/
│   ├── features.md
│   └── seance-ctl.md
├── og.png
├── fork.svg
├── demo.mp4
└── demo.gif
```

## [S7] Navigation structure

- **Guide** → installation, quickstart, configuration, keybindings, CLI reference
- **Agents** → overview, per-agent pages, adding new agents
- **Developer** → architecture, lifecycle events, plugin system, building from source
- **Reference** → feature matrix, full CLI reference

Top nav bar with these four sections. Sidebar within each section.

## [S8] Landing page

Adapts existing `index.html` content into VitePress markdown:
- Hero: "Run AI coding agents in parallel. Without losing the thread."
- Tagline and description
- CTA buttons (GitHub, Install, Releases)
- Demo video embed
- Feature grid (6 cards: agent status, scrolling layout, scriptable, hook injection, GPU rendering, basics)
- Installation quick-start (Arch, Nix, AppImage, source)
- Footer with links

## [S9] Content sources

| Target page | Source |
|-------------|--------|
| `agents/mimocode.md` | `docs/mimocode.md` (rewrite for user-facing) |
| `agents/vibe.md` | `docs/vibecode.md` (rewrite for user-facing) |
| `agents/hermes.md` | `docs/hermes-agent.md` (rewrite for user-facing) |
| `dev/lifecycle-events.md` | `docs/lifecycle-events.md` (adapt as-is) |
| `reference/seance-ctl.md` | `skills/seance-skill.md` (adapt as reference) |
| `dev/architecture.md` | New, based on README + AGENTS.md |
| `guide/*` | New, based on README installation/features sections |
| `reference/features.md` | New, feature matrix table from lifecycle-events.md |

## [S10] Scope constraints

- No i18n (English only)
- No versioning (single version matching main branch)
- No blog/changelog section
- No API docs generation (manual markdown)
- Content is concise and task-oriented for user docs, detailed for dev docs
