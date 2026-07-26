# Browser Internals

This document describes how the in-app browser panel works internally — the WebKit integration, IPC API, URL routing, and session persistence.

## Architecture

Browser panels are a first-class pane type alongside terminal panes. The core `Panel` union in `src/panel.zig` defines:

```zig
pub const Panel = union(PanelType) {
    terminal: *Pane,
    webkit: *WebPanel,
};
```

A `WebPanel` wraps a `WebKitWebView` and provides URL management, navigation history, focus routing, and stacked layout support. Browser panels live inside `PaneGroup` containers alongside terminal panes — they participate in the same column layout, tab system, and scrolling strip.

```
Column
  └── PaneGroup
       ├── Panel.terminal (*Pane)    — terminal with PTY
       └── Panel.webkit (*WebPanel)  — WebKit web view
```

## Key Source Files

| File | Purpose |
|------|---------|
| `src/web_panel.zig` | WebPanel struct, URL bar, WebKit settings, TLS handling, focus routing |
| `src/panel.zig` | Panel union type with `asTerminal()` / `asWebPanel()` dispatch |
| `src/pane_group.zig` | PaneGroup: panel storage, tab management, stacked layout |
| `src/workspace.zig` | Column management, `addBrowserColumn()`, URL routing heuristic |
| `src/socket_server.zig` | 14 `browser.*` IPC methods |
| `src/ctl.zig` | 14 `browser-*` CLI commands |
| `src/keybinds.zig` | Browser keybindings, focus mode toggle |
| `src/window.zig` | Theme-matching background color, dim unfocused panes |

## WebKit Settings

Séance configures WebKit with dev-friendly defaults in `src/web_panel.zig`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `enable-developer-extras` | `1` | Enables WebKit inspector (`Ctrl+Shift+I`) |
| `enable-javascript` | `1` | Standard JS execution |
| `enable-local-storage` | `1` | Persist data across page reloads |
| `enable-indexeddb` | `1` | Client-side database storage |
| `enable-webgl` | `1` | Hardware-accelerated 3D graphics |
| `enable-webaudio` | `1` | Audio processing API |
| `enable-media-stream` | `1` | Camera/microphone access (for WebRTC) |
| `enable-mock-devices` | `1` | Allow mock capture devices in dev |
| `enable-clipboard` | `1` | Cut/copy/paste from page context |
| `enable-fullscreen` | `1` | Fullscreen API support |
| `enable-modal-dialogs` | `1` | `alert()`, `confirm()`, `prompt()` |
| `enable-dns-prefetching` | `1` | Faster navigation via DNS pre-resolution |

The TLS errors policy is set to `WEBKIT_TLS_ERRORS_POLICY_FAIL` by default. When a `load-failed-with-tls-errors` signal fires, Séance temporarily switches to `IGNORE`, shows a confirmation dialog, and restores `FAIL` on `WEBKIT_LOAD_FINISHED`.

## URL Routing

When an agent opens a URL (detected via `ghostty_bridge.zig`), the routing heuristic in `src/ghostty_bridge.zig` determines where it opens:

1. **Find source terminal** — the pane group that fired the `open_url` action
2. **Scan right** — look for an existing browser panel in columns to the right of the source
3. **Navigate nearest** — if found, load the URL in that browser panel
4. **Create new** — if no browser exists to the right, call `addBrowserColumnRightOf(col_idx, url)` to create a new browser column immediately right of the source terminal

This ensures agent-opened URLs appear next to the agent that requested them, preserving spatial context.

## Focus Routing

Browser panels track focus independently from terminal panes. The `WebPanel` struct has a `FocusFn` callback type:

```zig
pub const FocusFn = *const fn (*anyopaque, *WebPanel) callconv(.c) void;
```

When a browser panel gains focus, it calls `focus_cb(focus_data, self)` passing the specific `*WebPanel` that was clicked. This allows `workspace.onBrowserEntryFocus()` to find the correct column by **pointer identity** — not by scanning for "the first webkit column."

This is critical for multi-browser setups where multiple browser columns exist. Clicking the URL bar in browser column 3 focuses column 3, not column 1.

## Session Persistence

Browser panels are saved and restored via the session file (`~/.config/seance/session.json`). On save, each browser panel's URL is written as a `"webkit"` panel type with its URL. On restore, `session.restoreGroupPanels()` type-checks the first panel in each group — if it's a webkit panel, it replaces any existing terminal panel with a browser column loading the saved URL.

Only the URL is persisted. Page state (form inputs, scroll position, JavaScript state) is not preserved across sessions.

## Theme Matching

Browser panel backgrounds are synchronized with the terminal theme. When a theme loads (`loadThemeCss()` in `src/window.zig`), `panel.updateBackgroundColor()` is called for each webkit panel. It parses the `window_bg` hex color from the resolved theme and calls `webkit_web_view_set_background_color()` with a matching `GdkRGBA` value.

This ensures browser panels blend visually with terminal panes — no white flash on dark themes.

## Socket IPC API

All browser operations are available over the Unix domain socket via `seance ctl` or direct JSON-RPC.

### Methods

| Method | Parameters | Returns | Description |
|--------|-----------|---------|-------------|
| `browser.open` | `url` | `panel_id` | Open URL in new browser column |
| `browser.navigate` | `panel_id`, `url` | `url` | Navigate existing panel |
| `browser.reload` | `panel_id` | `{}` | Reload current page |
| `browser.back` | `panel_id` | `{}` | Navigate back |
| `browser.forward` | `panel_id` | `{}` | Navigate forward |
| `browser.get_url` | `panel_id` | `url` | Get current page URL |
| `browser.list` | — | `panels[]` | List all browser panels |
| `browser.get_title` | `panel_id` | `title` | Get page title |
| `browser.get_zoom` | `panel_id` | `zoom_level` | Get zoom level |
| `browser.set_zoom` | `panel_id`, `level` | `zoom_level` | Set zoom level |
| `browser.is_loading` | `panel_id` | `loading` | Check if page is loading |
| `browser.get_progress` | `panel_id` | `progress` | Get load progress (0.0–1.0) |
| `browser.eval` | `panel_id`, `script` | `result` | Evaluate JavaScript |
| `browser.close` | `panel_id` | `{}` | Close browser panel |

### JavaScript Evaluation

`browser.eval` evaluates JavaScript synchronously from the CLI. It calls `webkit_web_view_evaluate_javascript()` (async GIO API), then pumps the glib main loop until the callback fires (up to 5 seconds). The result is returned as a JSON value via `jsc_value_to_json()`.

```bash
seance ctl browser-eval "document.title" --panel 42
```

This is useful for agents that need to read page content, extract data, or interact with web apps programmatically.

## CLI Commands

All 14 socket methods have corresponding CLI commands. See [CLI Reference](../guide/cli.md#browser-commands) for usage.

| Command | Maps to |
|---------|---------|
| `browser-open URL` | `browser.open` |
| `browser-navigate URL` | `browser.navigate` |
| `browser-reload` | `browser.reload` |
| `browser-back` | `browser.back` |
| `browser-forward` | `browser.forward` |
| `browser-get-url` | `browser.get_url` |
| `browser-list` | `browser.list` |
| `browser-get-title` | `browser.get_title` |
| `browser-get-zoom` | `browser.get_zoom` |
| `browser-set-zoom LEVEL` | `browser.set_zoom` |
| `browser-is-loading` | `browser.is_loading` |
| `browser-get-progress` | `browser.get_progress` |
| `browser-eval SCRIPT` | `browser.eval` |
| `browser-close` | `browser.close` |

## Surface Type Safety

Terminal-specific IPC methods (`send`, `send-key`, `read-screen`, etc.) safely handle browser panels. They use `findPaneById()` which returns `null` for browser panel IDs, producing a clean `"not_found"` error.

Column-level operations (`expel-pane`, `resize-row`) work with browser panels — `focusColumnContainingPane()` matches both terminal pane IDs and browser panel IDs via `findPaneById()` or `findPanelById()`.

`system.identify` reports `"browser_panel_id"` when the focused panel is a browser, alongside `"surface_id": null`.
