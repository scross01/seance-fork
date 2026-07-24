# CLI Reference

Séance provides a CLI tool (`seance ctl`) for controlling the terminal multiplexer programmatically over a Unix domain socket. This is useful for scripting, automation, and AI agent integrations.

## Usage

```bash
seance ctl [global-flags] <command> [args...]
```

## Global Flags

| Flag | Description |
|------|-------------|
| `--socket PATH` | Override the Unix socket path |
| `--json` | Output results as JSON |
| `--workspace N` | Specify workspace context by ID |
| `--surface N` | Specify surface/pane context by ID |

## System Commands

```bash
seance ctl ping                    # Health check (returns "pong")
seance ctl identify                # Show current pane, group, workspace, window
seance ctl capabilities            # List all supported API methods
seance ctl tree                    # Full hierarchy: windows > workspaces > groups > surfaces
```

## Window Commands

```bash
seance ctl list-windows            # List all open windows
seance ctl new-window              # Create a new window
seance ctl close-window [INDEX]    # Close a window (default: active)
```

## Workspace Commands

```bash
seance ctl list-workspaces [--window N]       # List workspaces
seance ctl new-workspace [--title TITLE]      # Create a new workspace
seance ctl select-workspace ID                # Switch to a workspace
seance ctl close-workspace ID                 # Close a workspace
seance ctl rename-workspace ID TITLE          # Rename a workspace
seance ctl reorder-workspace ID --index N     # Reorder (also: --before ID, --after ID)
seance ctl move-workspace ID --window INDEX   # Move workspace to another window
seance ctl last-workspace                     # Switch to last-active workspace
```

## Column Commands

```bash
seance ctl move-column --direction left|right [--workspace N]    # Swap column position
seance ctl resize-column --wider|--narrower|--maximize           # Resize active column
```

## Surface (Pane) Commands

```bash
seance ctl list-surfaces [--workspace N]                  # List all panes
seance ctl split [--direction vertical|horizontal]        # Create new pane (default: vertical)
seance ctl close-surface ID                               # Close a pane
seance ctl send "TEXT" [--surface N]                       # Send text input to a pane
seance ctl send-key KEY [--surface N]                      # Send key (enter, ctrl+c, tab, etc.)
seance ctl read-screen [--lines N] [--surface N]          # Read terminal output (default: 50 lines)
seance ctl expel-pane --direction left|right [--surface N] # Move pane to adjacent column
seance ctl resize-row --taller|--shorter [--surface N]    # Resize pane height in stacked column
seance ctl reorder-surface ID --index N                   # Reorder tab (also: --before ID, --after ID)
seance ctl last-pane [--workspace N]                      # Switch to last-focused pane
```

## Notification Commands

```bash
seance ctl notify --title "TITLE" --body "BODY" [--subtitle S] [--workspace N] [--surface N]
seance ctl list-notifications           # List all notifications
seance ctl clear-notifications          # Clear all notifications
```

## JSON Output

Use `--json` with any command to get structured output.

### read-screen JSON

```bash
seance ctl --json read-screen [--surface N]
```

| Field | Description |
|-------|-------------|
| `text` | Visible terminal text (last N lines) |
| `shell_state` | `"prompt"` (idle), `"running"` (command in progress), or `"unknown"` |
| `cursor_row` | Current cursor row position |
| `cursor_col` | Current cursor column position |
| `rows` | Terminal height in rows |
| `cols` | Terminal width in columns |

### split JSON

```bash
seance ctl --json split [--direction vertical|horizontal]
```

| Field | Description |
|-------|-------------|
| `surface_id` | ID of the newly created pane |

## Layout

Séance uses a **horizontal scrolling column** layout. Adding a pane never shrinks existing ones — you scroll to see more.

**Hierarchy:** Window > Workspace > Column > PaneGroup > Pane

- **Windows** contain multiple workspaces as tabs in a sidebar
- **Workspaces** are horizontal strips of columns you scroll through
- **Columns** are vertical stacks with animated width; can be **stacked** (all visible) or **tabbed** (one pane + tab bar)
- **Panes** are individual terminal instances, each with its own PTY

Each pane has identifying environment variables: `SEANCE_PANEL_ID`, `SEANCE_WORKSPACE_ID`, `SEANCE_SURFACE_ID`.
