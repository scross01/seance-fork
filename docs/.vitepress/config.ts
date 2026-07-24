import { defineConfig } from 'vitepress'

export default defineConfig({
  base: '/seance-fork/',
  title: 'Séance-fork',
  description: 'Terminal multiplexer for AI coding agents',
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/fork.svg' }],
    ['meta', { property: 'og:title', content: 'Séance-fork: terminal multiplexer for AI coding agents' }],
    ['meta', { property: 'og:description', content: 'Linux-native terminal multiplexer that auto-tracks Claude Code, Codex, OpenCode, and more.' }],
    ['meta', { property: 'og:image', content: '/seance-fork/og.png' }],
  ],
  themeConfig: {
    logo: '/fork.svg',
    siteTitle: 'Séance-fork',
    nav: [
      { text: 'Guide', link: '/guide/installation' },
      { text: 'Agents', link: '/agents/overview' },
      { text: 'Developer', link: '/dev/architecture' },
      { text: 'Reference', link: '/reference/features' },
    ],
    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Installation', link: '/guide/installation' },
            { text: 'Quick Start', link: '/guide/quickstart' },
            { text: 'Configuration', link: '/guide/configuration' },
            { text: 'Keybindings', link: '/guide/keybindings' },
            { text: 'Sidebar', link: '/guide/sidebar' },
            { text: 'CLI Reference', link: '/guide/cli' },
          ],
        },
      ],
      '/agents/': [
        {
          text: 'Agent Integrations',
          items: [
            { text: 'Overview', link: '/agents/overview' },
            { text: 'Claude Code', link: '/agents/claude-code' },
            { text: 'Codebuff', link: '/agents/codebuff' },
            { text: 'Codex', link: '/agents/codex' },
            { text: 'Freebuff', link: '/agents/freebuff' },
            { text: 'Hermes Agent', link: '/agents/hermes' },
            { text: 'Kilo Code', link: '/agents/kilo' },
            { text: 'MiMo Code', link: '/agents/mimocode' },
            { text: 'Mistral Vibe', link: '/agents/vibe' },
            { text: 'OpenCode', link: '/agents/opencode' },
            { text: 'Pi Agent', link: '/agents/pi' },
            { text: 'Poolside Agent CLI', link: '/agents/poolside' },
            { text: 'Adding New Agents', link: '/agents/adding-agents' },
          ],
        },
      ],
      '/dev/': [
        {
          text: 'Developer',
          items: [
            { text: 'Architecture', link: '/dev/architecture' },
            { text: 'Lifecycle Events', link: '/dev/lifecycle-events' },
            { text: 'Integration Approaches', link: '', items: [
              { text: 'Plugin-Based', link: '/dev/integration-plugins' },
              { text: 'Hook-Based', link: '/dev/integration-hooks' },
              { text: 'Built-in Wrapper', link: '/dev/integration-wrapper' },
              { text: 'Session Log Monitoring', link: '/dev/integration-inotifywait' },
            ]},
            { text: 'Plugin System', link: '/dev/plugin-system' },
            { text: 'Status System', link: '/dev/status-system' },
            { text: 'Building from Source', link: '/dev/building' },
          ],
        },
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Feature Matrix', link: '/reference/features' },
            { text: 'seance ctl', link: '/reference/seance-ctl' },
          ],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/scross01/seance-fork' },
    ],
    search: {
      provider: 'local',
    },
    footer: {
      message: 'MIT Licensed',
      copyright: 'Built with Zig, GTK4, and libghostty',
    },
  },
})
