---
name: Séance-fork
description: A scrolling terminal multiplexer that tracks your AI coding agents.
colors:
  accent-blue: "#1e78e4"
  accent-fg: "#f6f5f4"
  notify-blue: "#51a1ff"
  window-bg-dark: "#222226"
  window-fg-dark: "#ffffff"
  window-bg-light: "#fafafa"
  window-fg-light: "#241f31"
  border-subtle: "rgba(94, 92, 100, 0.15)"
  tab-red: "#c01c28"
  tab-green: "#2ec27e"
  tab-yellow: "#f5c211"
  tab-blue: "#1e78e4"
  tab-purple: "#9841bb"
  tab-cyan: "#0ab9dc"
  tab-white: "#c0bfbc"
typography:
  headline:
    fontFamily: "Cantarell, system-ui, sans-serif"
    fontSize: "0.95em"
    fontWeight: 700
  title:
    fontFamily: "Cantarell, system-ui, sans-serif"
    fontSize: "0.85em"
    fontWeight: 600
  body:
    fontFamily: "Cantarell, system-ui, sans-serif"
    fontSize: "0.88em"
    fontWeight: 400
  label:
    fontFamily: "Cantarell, system-ui, sans-serif"
    fontSize: "0.68em"
    fontWeight: 400
  micro:
    fontFamily: "Cantarell, system-ui, sans-serif"
    fontSize: "0.62em"
    fontWeight: 600
  terminal:
    fontFamily: "Monospace"
    fontSize: "11px"
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
  full: "50%"
spacing:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  xl: "16px"
components:
  badge-unread:
    backgroundColor: "{colors.accent-blue}"
    textColor: "{colors.accent-fg}"
    rounded: "{rounded.full}"
    size: "18px"
  sidebar-row:
    textColor: "{colors.window-fg-dark}"
    padding: "10px 12px 10px 15px"
  sidebar-row-selected:
    backgroundColor: "color-mix(in srgb, {colors.window-bg-dark} 65%, {colors.accent-blue})"
    textColor: "{colors.window-fg-dark}"
    padding: "10px 12px 10px 15px"
  command-palette:
    backgroundColor: "{colors.window-bg-dark}"
    rounded: "{rounded.lg}"
    padding: "4px"
  status-icon:
    textColor: "{colors.window-fg-dark}"
    size: "16px"
---

# Design System: Séance-fork

## Overview

**Creative North Star: "The Familiar"**

Séance-fork is a spirit companion that watches your agents and knocks when one needs you. The interface is the quiet room; the terminals are the summoned. Chrome stays still and Adwaita-true — a watchful sidebar, a still header bar, a horizontal strip of panes — while the state of each agent surfaces through small, precise signals: a symbolic icon, an unread dot, a 2px outline, a knock-blue flash. The design succeeds when the user can look away.

By default, the chrome is simply the OS theme: stock libadwaita, light or dark following the system, tracked live. The defining mechanism is opt-in possession — set a ghostty theme (`theme` under `[colors]`) and the chrome adopts the terminal's colors: window, view, card, headerbar, sidebar, popover, and dialog backgrounds alias the terminal background/foreground, the accent becomes the theme's ANSI blue (`palette[4]`), borders become `palette[8]` at 15% alpha, and notification outlines become `palette[12]` bright blue. Unset the theme and the window returns to stock Adwaita. Every swap is one atomic CSS exchange; no widget ever renders unthemed.

The app is Linux-native to the bone: GTK4, libadwaita, symbolic icons only, system fonts, `AdwDialog` + `AdwPreferencesPage` settings, backdrop dimming. It should pass for a well-bred GNOME app at arm's length and reveal its personality up close — in the scrolling strip, the focus bar, and the badge dots. Depth is tonal, never shadowed; state is outlined, never recolored.

**Key Characteristics:**
- System theme by default: stock libadwaita chrome following the OS light/dark preference
- Opt-in palette possession: setting a ghostty theme re-derives every chrome color from the terminal palette
- Flat surfaces; depth comes from fg/bg mixes at 4–15%, never from shadows
- State carried by 2px outlines and symbolic icons, not by status hues
- One accent (ANSI blue), one notification color (ANSI bright blue)
- Adwaita-native controls, symbolic icons, system typography
- Motion is short and functional: 100–200ms ease-in-out, 150ms revealers

## Colors

The palette is not a fixed brand ramp; it is a resolution strategy with two states. **Default state:** the chrome follows the OS system theme — libadwaita's own colors, light or dark, switching live with the OS preference. **Possessed state:** a configured ghostty theme re-derives every chrome token from the terminal palette. The values below are the system-theme reference points (matching the bundled `Adwaita` / `Adwaita Dark` ghostty themes), not brand constants — in the default state, libadwaita owns the actual values and they change with the OS.

### Primary
- **Signal Blue** (#1e78e4): The single accent, resolved from `palette[4]`. Used for selected sidebar rows and tabs (as a 35–45% mix over window bg), unread badges, progress-bar fill, drag-over indicators, and the focus bar (50% mix). Mapped onto libadwaita's `@accent_bg_color`, `@accent_color`, and `@accent_fg_color`.
- **Knock Blue** (#51a1ff): The notification signal, resolved from `palette[12]` (bright blue). Reserved for "something needs you": the 2px `.pane-notification` outline, `.pane-flash`, and dashed drop-target outlines. Never used for decoration.

### Neutral
- **Séance Dark** (#222226): Default dark window/view/sidebar/dialog background. All chrome surfaces alias this one value.
- **Seance Dark Ink** (#ffffff): Default dark foreground. Secondary text is the same ink at 0.8/0.6/0.5 opacity — never a second color.
- **Medium Paper** (#fafafa): Default light background.
- **Medium Ink** (#241f31): Default light foreground.
- **Veil** (rgba(94, 92, 100, 0.15)): The border color — `palette[8]` at 15% alpha. One-pixel dividers use foreground at 12% alpha instead.

### Workspace Color Codes
The ANSI ramp `palette[1..7]` — **tab-red** (#c01c28), **tab-green** (#2ec27e), **tab-yellow** (#f5c211), **tab-blue** (#1e78e4), **tab-purple** (#9841bb), **tab-cyan** (#0ab9dc), **tab-white** (#c0bfbc) — exists for one job: user-assigned workspace color coding on the 3px vertical-tab color bar and the workspace dot. It is identity tagging, not status.

### Named Rules
**The Palette Is the Chrome Rule.** Never hardcode a chrome color. In the default state, reference libadwaita's named colors and let the OS theme resolve them; in the possessed state, the same named colors resolve from the terminal palette. New surfaces take `@window_bg_color` / `@window_fg_color` or a documented mix of them; new signals take the accent or notify tokens.

**The One Accent Rule.** Agent status never gets its own hue. Working, idle, and needs-input are distinguished by symbolic icon and outline, not by green/yellow/red. `@success_color`, `@warning_color`, and `@error_color` are deliberately unused in app chrome.

## Typography

**App Font:** the OS system UI font (Cantarell on GNOME) — inherited, never overridden, and not configurable. Séance-fork has no app-font setting.
**Terminal Font:** Monospace (11px default) — user-configurable in Settings → Font (family, size, style). This selection applies **only to terminal cells**; it never touches app chrome.

**Character:** The UI speaks entirely in the system font at small sizes. Hierarchy comes from weight and opacity, not size jumps; nothing in chrome exceeds ~1em. All chrome sizes are **em-relative to the theme font**, never absolute px: GTK's px is DPI-aware but ignores the GNOME text-scaling-factor, so a px-locked sidebar is unreadable for someone running large text. The terminal font is the user's own setting and scales independently.

### Hierarchy
Ratios below are relative to the theme font (em), which is what the CSS actually ships.

- **Headline** (700, 0.95em): Sidebar section headers (`.sidebar-header`) only.
- **Title** (600, 0.85em): Workspace row titles (`.sidebar-ws-title`).
- **Body** (400, 0.88em): Command-palette input and result text; dialogs otherwise inherit the GTK default.
- **Label** (400, 0.68em, opacity 0.8): Metadata — branch lines, ports, status entries, notification previews (`.sidebar-ws-meta` et al). The floor for dimmed text is 0.7 opacity; 0.8 is the default secondary step.
- **Micro** (600–700, 0.55–0.62em): Unread badges and bell badges, always on accent circles sized in em (1.1–1.25em) so the circle grows with its glyph.

### Named Rules
**The Dim Label Rule.** Secondary information is the primary ink at reduced opacity, never a second text color. The floor for anything that carries text is **0.7** — that is the lowest value that clears WCAG AA (4.5:1) on *both* appearances; the light theme is the binding case, where 0.6 measures only 4.21:1. Below 0.7 (down to 0.55) is decoration only: disabled rows, borders, hover washes. Disabled controls are the one WCAG exemption and may sit below the floor.

**The Scaling Rule.** Chrome type is expressed in em against the theme font so it follows the system text-scaling-factor. Never reintroduce a px font-size; px silently opts that user out of scaling, and the terminal is the only place a user chooses a size.

**The Two Fonts Rule.** The app has exactly two fonts: the system UI font for chrome (fixed, unconfigurable) and the terminal font for cell content (user-configurable). Font settings never cross the boundary in either direction.

## Layout

The window is an `AdwApplicationWindow` → `AdwToastOverlay` → `GtkOverlay` (command palette floats above) → horizontal box: a 240px sidebar in a `GtkRevealer` (slide-left/right, 150ms) plus the workspace stack. On narrow windows the sidebar is capped at 40% of the window width (floor 160px) so the pane strip always keeps the majority of the space. CSD builds get an `AdwToolbarView` (flat) with an `AdwHeaderBar`; the header bar is painted manually because libadwaita strips it inside a toolbar view.

The workspace is a horizontal scrolling strip of columns on a `GtkFixed` inside a `GtkScrolledWindow` — the niri model. Columns hold tab groups (`AdwTabView`/`AdwTabBar`, or a vertical tab bar). A `multi-pane` class on the container arms the focus-bar indicator.

Density is compact and terminal-adjacent: 4px toolbar margins, 6px control radius, 8–12px interior padding, sidebar rows at `10px 12px 10px 15px`. Dividers are 1px lines at 12% foreground alpha; resize handles are invisible. Terminal content keeps an 8px window padding (ghostty `window-padding-x/y`).

## Elevation & Depth

Flat by default. Depth is tonal: hovering a row raises it by 4% foreground, the tab strip sits 5% above the window, the sidebar sits 10% above it, and a "lifted" surface (tab selected, popover) is a 15% foreground mix. Selection is not elevation — it is a 35% accent mix (45% on hover). The only shadow in the system belongs to the command palette (`0 5px 10px rgba(0,0,0,0.24)`), and dragged vertical tabs borrow a smaller one (`0 2px 8px rgba(0,0,0,0.3)`).

State is outlined, not elevated: focused panes, notifying panes, and drop targets all wear 2px outlines at −2px offset, inset so they never shift layout.

### Shadow Vocabulary
- **Palette shadow** (`box-shadow: 0 5px 10px rgba(0,0,0,0.24)`): Command palette only — the one true overlay.
- **Drag shadow** (`box-shadow: 0 2px 8px rgba(0,0,0,0.3)`): Vertical tab being reordered.

### Named Rules
**The Outline Carries State Rule.** Focus, notification, flash, and drop-target are 2px outlines at −2px offset. Shadows are for overlays and drag physics only — never for resting surfaces.

**The Backdrop Dim Rule.** When the window loses focus, sidebar chrome dims to 50% opacity over 200ms (`filter: opacity(0.5)`); accent-colored selection stays lit so you can find your place at a glance. This matches GNOME's own unfocused-window convention and is exempt from the contrast floor.

## Shapes

Small and consistent: 6px radius is the default for buttons, rows, vertical tabs, and the search overlay; 8px for the command palette; 4px for shortcut chips. Badges and icon-close buttons are full circles (50%). The recurring signatures are thin bars: the 3px focus bar, the 3px × full-height workspace color bar (2px radius), 1.5px-radius progress bars, and 1px divider lines. Pane outlines are sharp-cornered 2px strokes drawn inside the pane edge.

## Components

### Sidebar Workspace Row
The unit of the familiar's watch. `10px 12px 10px 15px` padding, title at 12.5px/600, metadata at 10px/0.8 opacity.
- **Hover:** foreground at 4% alpha — a breath, not a lift.
- **Selected:** 35% accent mix over window bg (45% on hover), with a squared edge; focus indicators are suppressed (no focus outline on rows).
- **Drag-over:** accent at 15% alpha fill plus a 2px accent top border at 60% alpha.

### Status Indicators
Agent state is a 16px symbolic icon at 0.8 opacity, never a color: `camera-flash-symbolic` (working), `bell-outline-symbolic` (needs input), `pause-symbolic` (idle). Background-running panes add `media-playback-start-symbolic`.

### Unread Badge
An accent-filled circle (18px, accent-fg text at 9px/600) counting unread notifications per workspace; the header-bar bell wears a 16px version at 8px/700. The single most saturated object in the UI — that is the point.

### Pane Frame
- **Outline:** a warm hairline (2px at 12% alpha, −2px offset) in the palette's **complementary hue** — `palette[3]` yellow, ~166° from the accent's ~213°. The accent-blue version read as a contrasting frame bolted onto flat chrome; the complement recedes instead, and it matches the app icon's warm ring around a blue wave. At 12% it measures 1.30:1 against the pane background in both appearances, the same register as the 1px dividers, and never reads as the Yellow workspace colour code.
- **Focus bar:** 3px strip at the pane's top edge, the same complementary hue at 50% mix with the pane background, fading in over 100ms; only rendered when more than one pane exists (`.multi-pane`). The bar and the ring share one warm cue so active-pane signalling is a single element pair.

### Named Rules
**The Complement Rule.** The active pane is marked in the theme's complementary hue, never in the accent. Accent means interactive selection; the complement means "this pane is active". Keeping the two apart is what stops the focus ring from competing with `.pane-notification`, which stays the only loud outline in the system.
- **Notification:** 2px Knock Blue outline when a pane requests attention; `.pane-flash` pulses the same outline once, then removes itself.
- **Unfocused dim:** children at `brightness(0.8)` when `dim_unfocused_panes` is on.

### Vertical Tab
6px radius, `5px 6px 6px 6px` padding inside a `1px 6px` wrapper; 150ms background transition. Selected wears the 35% accent mix. The 3px workspace color bar rides the left edge. Close is a 16px circular `window-close-symbolic` button at 0.7 opacity (full opacity + 10% fg wash on hover).

### Command Palette
The one elevated surface: 8px radius, window-bg fill, 1px border at 18% fg alpha, palette shadow, minimum width 340px, centered over a 24% black scrim. Entry text 13px; results at 24px minimum row height; shortcut chips are 4px-radius, 8% fg pills at 11px.

### Notification Popover & Rows
Popover surface is a 15% fg lift with no border. Rows: 6px radius, `10px 8px`, hover at 5% fg; an 8px accent unread dot, 12px bold title, 11px body at 0.6 opacity, 10px timestamp at 0.5.

### Icon Buttons (chrome)
Footer and header buttons are 28×28px minimum, 6px radius, symbolic icons only (`list-add-symbolic`, `sidebar-show-right-symbolic`, `bell-outline-symbolic`, `emblem-system-symbolic`). In-row close buttons shrink to 16px circles at 0.7 opacity.

### Progress Bar
3px trough (1.5px radius) at 20% fg alpha, accent fill — a hairline, not a bar.

### Dialogs
Settings and shortcuts are `AdwDialog` (800×680) over `AdwToolbarView` (flat) with `AdwPreferencesPage`/`AdwPreferencesGroup`/`AdwActionRow` content — stock libadwaita, unstyled beyond the theme colors. Destructive actions use `.destructive-action`; this is the one place libadwaita's error red is permitted.

## Do's and Don'ts

### Do:
- **Do** resolve every new chrome color from `@window_bg_color` / `@window_fg_color` (or a documented 4–15% mix), the accent, or the notify token — The Palette Is the Chrome Rule.
- **Do** use symbolic (`*-symbolic`) icons exclusively; tint with `color`, size via icon-size or px.
- **Do** express state as 2px outlines at −2px offset and symbolic-icon swaps, keeping layout stable.
- **Do** keep secondary text as the primary ink at 0.8/0.6/0.5 opacity — The Dim Label Rule.
- **Do** use stock libadwaita patterns (`AdwDialog`, `AdwPreferencesPage`, `.boxed-list`, `.dim-label`, `.title-4`) for dialogs.
- **Do** swap theme CSS atomically: attach the new provider before detaching the old, so no widget ever renders unthemed.

### Don't:
- **Don't** add status hues. No `@success_color`/`@warning_color`/`@error_color` in chrome; agent state is icon + outline — The One Accent Rule. (`.destructive-action` in settings dialogs is the sole exception.)
- **Don't** add resting shadows or card-style elevation; the command palette shadow is a deliberate singleton.
- **Don't** style chrome toward one fixed palette; the default state must stay correct under stock libadwaita, light and dark, with any OS accent color.
- **Don't** let the terminal font setting leak into chrome, or add an app-font setting — The Two Fonts Rule. The system UI font is the brand voice; nothing in chrome exceeds 14px.
- **Don't** use Knock Blue (#51a1ff) decoratively — it means "a pane needs you."
- **Don't** give workspace color codes any status meaning; they are user-assigned identity tags.
- **Don't** introduce GTK3 idioms (`key-press-event`, manual widget unrefs) or non-symbolic icons in new UI.
