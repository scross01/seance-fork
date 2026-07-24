# Configuration

Séance is configured via a TOML file at:

```
~/.config/seance/config.toml
```

On first run, Séance creates this file with all defaults. You can also reload config at any time with **Ctrl+Shift+,**.

The default config shipped with the source is at `src/default_config.toml`.

## Sections

### Font

```toml
[font]
family = "Monospace"
size = 13.0
```

### Colors

```toml
[colors]
theme = ""                    # ghostty theme name (empty = use ghostty's own theme)
background-opacity = 1.0
```

### Window

```toml
[window]
width = 1200
height = 800
decoration-mode = "auto"      # "auto" (GNOME=CSD, else=SSD), "csd", or "ssd"
```

### Sidebar

```toml
[sidebar]
position = "left"             # "left" or "right"
width = 200
visible = true
show-notification-text = true  # latest notification text below workspace title
show-status = true             # custom status metadata pills
show-logs = true               # most recent log message
show-progress = true           # active progress indicator
show-branch = true             # git branch and working directory
show-ports = true              # detected listening ports
```

### Terminal

```toml
[terminal]
scrollback-lines = 10000
cursor-shape = "block"        # "block", "ibeam", "underline"
cursor-blink = true
```

### Behavior

```toml
[behavior]
bell-notification = true
desktop-notifications = true
focus-follows-mouse = false
confirm-close-window = true
```

#### Agent Integration Toggles

Séance has built-in hooks for AI coding agents. Each toggle enables event tracking, lifecycle notifications, and sidebar status for that agent. Set to `false` to disable.

```toml
[behavior]
claude-code-hooks = true
codex-hooks = true
opencode-hooks = true
kilo-hooks = true
mimocode-hooks = true
pi-hooks = true
vibe-hooks = true
hermes-hooks = true
pool-hooks = true
codebuff-hooks = true
freebuff-hooks = true
```

### Notifications

```toml
[notifications]
sound = "default"             # "default", "none", or path to .wav/.ogg file
```

### Keybinds

Customize keyboard shortcuts in the `[keybinds]` section. Use keybind strings like `"ctrl+shift+p"`, or `"unset"` to disable.

```toml
[keybinds]
command_palette = "ctrl+shift+p"
open_folder = "ctrl+shift+o"
reload_config = "ctrl+shift+comma"
```

See [Keybindings](./keybindings.md) for the full default mapping.

### Socket

```toml
[socket]
path = ""                     # override the Unix socket path (auto-detected by default)
```
