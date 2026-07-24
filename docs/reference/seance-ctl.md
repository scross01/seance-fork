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
