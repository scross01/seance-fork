# Browser Panel

Séance includes an in-app browser panel powered by WebKitGTK. Open documentation, dashboards, or any URL alongside your agent without leaving the terminal.

## Opening a Browser Panel

| Action | Shortcut |
|--------|----------|
| New browser panel | `Ctrl+Alt+B` |
| New browser tab | `Ctrl+Alt+E` |
| Command palette | **New Browser Panel** or **New Browser Tab** |

A new browser panel opens in its own column to the right of the active pane. The URL bar displays the current page with a styled readout — domain in normal color, path and scheme dimmed.

## URL Bar

Click the styled URL display to switch to edit mode. Type a URL and press Enter to navigate. Click elsewhere or press Escape to return to the styled display.

The URL bar accepts any scheme that WebKit supports. Séance allows `http`, `https`, and `about` URLs (including `localhost` and private network addresses for local development); `file:`, `data:`, `javascript:`, and `blob:` URLs are rejected.

## Navigation

| Action | Shortcut |
|--------|----------|
| Back | `Ctrl+Shift+Alt+Left` |
| Forward | `Ctrl+Shift+Alt+Right` |
| Reload | `Ctrl+R` |
| Focus URL bar | `Ctrl+L` |

## Browser Focus Mode

Press `Ctrl+Alt+F` to toggle browser focus mode. When active, all keystrokes pass through directly to the browser page — useful for interacting with web apps, filling forms, or using page-level shortcuts. Press `Ctrl+Alt+F` again to return to normal mode where Séance keybindings are active.

## Zoom

`Ctrl+=` to zoom in, `Ctrl+-` to zoom out, `Ctrl+0` to reset. Zoom works in both terminal panes and browser panels — the same keys control font size in terminals and page zoom in the browser.

## Tabs

Browser panels support multiple tabs, like a tabbed browser within a single column. Use `Ctrl+Alt+E` to open a new tab in the current browser column, or `Ctrl+Shift+L` to switch between tabbed and stacked layout modes.

## TLS Certificates

When a page fails TLS verification (self-signed certificates, local CAs), Séance shows a dialog with the hostname and error details. Click **Proceed Anyway** to temporarily bypass the certificate check for that session. The override resets when you navigate away.

## Developer Tools

Press `Ctrl+Shift+I` or use the **Developer Tools** command palette entry to open the WebKit inspector. This provides a full DOM inspector, JavaScript console, network monitor, and rendering debug tools — identical to browser dev tools.

## Dim Unfocused Panes

When `dim-unfocused-panes` is enabled (default), unfocused browser panels are dimmed to 80% opacity, making it easy to see which panel is active. See [Configuration](./configuration.md) for the setting.

## Configuration

Two settings in `~/.config/seance/config.toml` affect browser behavior:

```toml
[behavior]
open-url-in-browser = false    # open URLs in-app instead of system browser
dim-unfocused-panes = true     # dim unfocused terminal and browser panes
```

When `open-url-in-browser` is enabled and an agent opens a URL, Séance looks for an existing browser panel to the right of the source terminal. If one exists, the URL loads there. If not, a new browser column is created next to the source terminal.

## Command Palette

The command palette (**Ctrl+Shift+P**) includes these browser commands:

| Command | Description |
|---------|-------------|
| New Browser Panel | Open a new browser column |
| New Browser Tab | Open a tab in the current browser column |
| Developer Tools | Open the WebKit inspector |

## Layout

Browser panels participate in the same column layout as terminal panes. You can:

- **Move columns** with `Ctrl+Shift+A` / `Ctrl+Shift+D`
- **Resize columns** with `Ctrl+Shift+=` / `Ctrl+Shift+-`
- **Expel** a browser panel to an adjacent column
- **Stack** multiple browser panels in a single column with `Ctrl+Shift+L`

Browser panels appear in the same scrolling strip as terminal panes — scroll to find them alongside your agent sessions.

## Limitations

- Browser panels are not listed by `seance ctl list-surfaces` (use `seance ctl browser-list` instead)
- Session restore recreates browser panels with their last URL, but page state (form inputs, scroll position) is not preserved
- WebGL and hardware-accelerated rendering are available but depend on your GPU and driver
