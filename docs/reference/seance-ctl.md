# seance ctl

CLI reference for the Séance socket API. All commands communicate with the running Séance instance over a Unix domain socket.

```
seance ctl [global-flags] <command> [args...]
```

## Global Flags

| Flag | Description |
|------|-------------|
| `--socket PATH` | Override the Unix socket path (default: `$SEANCE_SOCKET_PATH`) |
| `--json` | Output results as JSON |
| `--workspace N` | Specify workspace context by ID |
| `--surface N` | Specify surface/pane context by ID |

## System Commands

### ping

Health check. Returns `pong` if the server is running.

```bash
seance ctl ping
```

### identify

Show the current pane, group, workspace, and window context.

```bash
seance ctl identify
```

### capabilities

List all supported API methods.

```bash
seance ctl capabilities
```

### tree

Print the full hierarchy: windows > workspaces > groups > surfaces.

```bash
seance ctl tree
```

## Window Commands

### list-windows

List all open windows.

```bash
seance ctl list-windows
```

### new-window

Create a new window.

```bash
seance ctl new-window
```

### close-window

Close a window. Defaults to the active window.

```bash
seance ctl close-window [INDEX]
```

## Workspace Commands

### list-workspaces

List all workspaces, optionally filtered by window.

```bash
seance ctl list-workspaces [--window N]
```

### new-workspace

Create a new workspace with an optional title.

```bash
seance ctl new-workspace [--title TITLE]
```

### select-workspace

Focus/switch to a workspace by ID.

```bash
seance ctl select-workspace ID
```

### close-workspace

Close a workspace by ID.

```bash
seance ctl close-workspace ID
```

### rename-workspace

Rename a workspace.

```bash
seance ctl rename-workspace ID TITLE
```

### reorder-workspace

Reorder a workspace. Supports `--index`, `--before ID`, or `--after ID`.

```bash
seance ctl reorder-workspace ID --index N
seance ctl reorder-workspace ID --before OTHER_ID
seance ctl reorder-workspace ID --after OTHER_ID
```

### move-workspace

Move a workspace to another window.

```bash
seance ctl move-workspace ID --window INDEX
```

### last-workspace

Switch to the last-active workspace.

```bash
seance ctl last-workspace
```

## Column Commands

### move-column

Swap a column's position within its workspace.

```bash
seance ctl move-column --direction left|right [--workspace N]
```

### resize-column

Resize the active column.

```bash
seance ctl resize-column --wider|--narrower|--maximize
```

## Surface (Pane) Commands

### list-surfaces

List all panes, optionally filtered by workspace.

```bash
seance ctl list-surfaces [--workspace N]
```

### split

Create a new pane. Default direction is vertical (side-by-side).

```bash
seance ctl split [--direction vertical|horizontal]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `surface_id` | ID of the newly created pane |

### close-surface

Close a pane by ID.

```bash
seance ctl close-surface ID
```

### send

Send text input to a pane.

```bash
seance ctl send "TEXT" [--surface N]
```

Include `\n` to execute commands.

### send-key

Send a key event to a pane.

```bash
seance ctl send-key KEY [--surface N]
```

Supported keys: `enter`, `ctrl+c`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, etc.

### read-screen

Read terminal output from a pane. Default: last 50 lines.

```bash
seance ctl read-screen [--lines N] [--surface N]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `text` | Visible terminal text (last N lines) |
| `shell_state` | `"prompt"` (idle), `"running"` (command in progress), or `"unknown"` |
| `cursor_row` | Current cursor row position |
| `cursor_col` | Current cursor column position |
| `rows` | Terminal height in rows |
| `cols` | Terminal width in columns |

### expel-pane

Move a pane to a new or adjacent column.

```bash
seance ctl expel-pane --direction left|right [--surface N]
```

### resize-row

Resize pane height in a stacked column.

```bash
seance ctl resize-row --taller|--shorter [--surface N]
```

### reorder-surface

Reorder a tab within a column. Supports `--index`, `--before ID`, or `--after ID`.

```bash
seance ctl reorder-surface ID --index N
seance ctl reorder-surface ID --before OTHER_ID
seance ctl reorder-surface ID --after OTHER_ID
```

### last-pane

Switch to the last-focused pane.

```bash
seance ctl last-pane [--workspace N]
```

## Notification Commands

### notify

Send a desktop notification.

```bash
seance ctl notify --title "TITLE" --body "BODY" [--subtitle S] [--workspace N] [--surface N]
```

### list-notifications

List all notifications.

```bash
seance ctl list-notifications
```

### clear-notifications

Clear all notifications.

```bash
seance ctl clear-notifications
```

## Browser Commands

### browser-open

Open a URL in a new browser panel.

```bash
seance ctl browser-open URL
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `panel_id` | ID of the newly created browser panel |

### browser-navigate

Navigate an existing browser panel to a URL.

```bash
seance ctl browser-navigate URL [--panel ID]
```

### browser-reload

Reload the current page in a browser panel.

```bash
seance ctl browser-reload [--panel ID]
```

### browser-back

Navigate back in browser history.

```bash
seance ctl browser-back [--panel ID]
```

### browser-forward

Navigate forward in browser history.

```bash
seance ctl browser-forward [--panel ID]
```

### browser-get-url

Get the current URL of a browser panel.

```bash
seance ctl browser-get-url [--panel ID]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `url` | Current page URL |

### browser-list

List all open browser panels.

```bash
seance ctl browser-list
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `panels` | Array of browser panel objects |
| `panels[].id` | Panel ID |
| `panels[].url` | Current URL |

### browser-get-title

Get the page title of a browser panel.

```bash
seance ctl browser-get-title [--panel ID]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `title` | Current page title |

### browser-get-zoom

Get the zoom level of a browser panel.

```bash
seance ctl browser-get-zoom [--panel ID]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `zoom_level` | Current zoom level (1.0 = 100%) |

### browser-set-zoom

Set the zoom level of a browser panel.

```bash
seance ctl browser-set-zoom LEVEL [--panel ID]
```

### browser-is-loading

Check if a browser panel is currently loading.

```bash
seance ctl browser-is-loading [--panel ID]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `loading` | `true` if loading, `false` otherwise |

### browser-get-progress

Get the estimated load progress of a browser panel.

```bash
seance ctl browser-get-progress [--panel ID]
```

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `progress` | Load progress from 0.0 to 1.0 |

### browser-eval

Evaluate JavaScript in a browser panel and return the result.

```bash
seance ctl browser-eval SCRIPT [--panel ID]
```

Evaluates the script synchronously (pumps the glib main loop until the result is ready, up to 5 seconds).

With `--json`, returns:

| Field | Description |
|-------|-------------|
| `result` | JSON-serialized result of the JavaScript expression |

### browser-close

Close a browser panel.

```bash
seance ctl browser-close [--panel ID]
```

## JSON Output Schemas

### read-screen

```json
{
  "text": "string",
  "shell_state": "prompt | running | unknown",
  "cursor_row": 0,
  "cursor_col": 0,
  "rows": 24,
  "cols": 80
}
```

### identify

```json
{
  "window_index": 0,
  "workspace_id": 1,
  "workspace_index": 0,
  "pane_group_id": 5,
  "surface_id": 12,
  "browser_panel_id": null
}
```

When the focused panel is a browser, `surface_id` is `null` and `browser_panel_id` contains the browser panel ID.

### split

```json
{
  "surface_id": "string"
}
```

## Examples

### Run a command in a separate pane

```bash
# Create a pane
SURFACE_ID=$(seance ctl --json split | python3 -c "import sys,json; print(json.load(sys.stdin)['surface_id'])")

# Run a command
seance ctl send "make test\n" --surface $SURFACE_ID

# Poll until complete
seance ctl --json read-screen --surface $SURFACE_ID

# Read the final output
seance ctl read-screen --surface $SURFACE_ID --lines 200

# Clean up
seance ctl close-surface $SURFACE_ID
```

### Organize work across workspaces

```bash
# Create a workspace for tests
WS_ID=$(seance ctl --json new-workspace --title "tests" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Switch to it
seance ctl select-workspace $WS_ID

# Create panes within it
seance ctl split --direction vertical

# Switch back to previous workspace
seance ctl last-workspace
```

### Read shell state before acting

```bash
# Check if the shell is idle before sending input
STATE=$(seance ctl --json read-screen --surface $SURFACE_ID | python3 -c "import sys,json; print(json.load(sys.stdin)['shell_state'])")

if [ "$STATE" = "prompt" ]; then
  seance ctl send "npm install\n" --surface $SURFACE_ID
fi
```

### Open a URL and read page content

```bash
# Open a URL in the browser
PANEL_ID=$(seance ctl --json browser-open "https://docs.example.com" | python3 -c "import sys,json; print(json.load(sys.stdin)['panel_id'])")

# Wait for the page to load
while [ "$(seance ctl --json browser-is-loading --panel $PANEL_ID | python3 -c "import sys,json; print(json.load(sys.stdin)['loading'])")" = "true" ]; do
  sleep 0.5
done

# Read the page title
seance ctl browser-get-title --panel $PANEL_ID

# Extract text content via JavaScript
seance ctl browser-eval "document.body.innerText" --panel $PANEL_ID

# Clean up
seance ctl browser-close --panel $PANEL_ID
```
