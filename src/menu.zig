const std = @import("std");
const c = @import("c.zig").c;
const keybinds = @import("keybinds.zig");

const Entry = struct {
    action: keybinds.Action,
    name: [*:0]const u8,
    label: [*:0]const u8,
};

/// Every hamburger-menu command: keybinds action, kebab-case GAction name,
/// display label. `preferences`/`shortcuts`/`about`/`quit` are excluded —
/// they stay registered in app.zig and are referenced by buildMenu directly.
pub const menu_actions = [_]Entry{
    .{ .action = .new_workspace, .name = "new-workspace", .label = "New Workspace" },
    .{ .action = .new_window, .name = "new-window", .label = "New Window" },
    .{ .action = .new_tab, .name = "new-tab", .label = "New Tab" },
    .{ .action = .new_browser_panel, .name = "new-browser-panel", .label = "New Browser Panel" },
    .{ .action = .open_command_palette, .name = "command-palette", .label = "Command Palette…" },
    .{ .action = .copy, .name = "copy", .label = "Copy" },
    .{ .action = .paste, .name = "paste", .label = "Paste" },
    .{ .action = .find, .name = "find", .label = "Find…" },
    .{ .action = .find_next, .name = "find-next", .label = "Find Next" },
    .{ .action = .find_previous, .name = "find-previous", .label = "Find Previous" },
    .{ .action = .clear_scrollback, .name = "clear-scrollback", .label = "Clear Scrollback" },
    .{ .action = .new_column, .name = "new-column", .label = "New Column" },
    .{ .action = .move_column_left, .name = "move-column-left", .label = "Move Column Left" },
    .{ .action = .move_column_right, .name = "move-column-right", .label = "Move Column Right" },
    .{ .action = .toggle_layout_mode, .name = "toggle-layout-mode", .label = "Toggle Layout Mode" },
    .{ .action = .maximize_column, .name = "maximize-column", .label = "Toggle Zoom" },
    .{ .action = .equalize_splits, .name = "equalize-splits", .label = "Equalize Splits" },
    .{ .action = .rename_tab, .name = "rename-tab", .label = "Rename Tab…" },
    .{ .action = .next_tab, .name = "next-tab", .label = "Next Tab" },
    .{ .action = .prev_tab, .name = "prev-tab", .label = "Previous Tab" },
    .{ .action = .close_tab, .name = "close-tab", .label = "Close Tab" },
    .{ .action = .close_other_tabs, .name = "close-other-tabs", .label = "Close Other Tabs" },
    .{ .action = .close_tabs_to_right, .name = "close-tabs-to-right", .label = "Close Tabs to Right" },
    .{ .action = .new_browser_tab, .name = "new-browser-tab", .label = "New Browser Tab" },
    .{ .action = .browser_back, .name = "browser-back", .label = "Back" },
    .{ .action = .browser_forward, .name = "browser-forward", .label = "Forward" },
    .{ .action = .browser_reload, .name = "browser-reload", .label = "Reload" },
    .{ .action = .browser_inspector, .name = "browser-inspector", .label = "Developer Tools" },
    .{ .action = .toggle_fullscreen, .name = "toggle-fullscreen", .label = "Toggle Fullscreen" },
    .{ .action = .close_window, .name = "close-window", .label = "Close Window" },
};

fn activateMenuAction(_: ?*c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const kb: keybinds.Action = @enumFromInt(@intFromPtr(data));
    const win_mod = @import("window.zig");
    if (win_mod.window_manager) |mgr| {
        if (mgr.active_window) |state| _ = keybinds.executeAction(kb, state);
    }
}

/// Register one `app.<name>` GAction per menu entry, all sharing the
/// executeAction dispatch above. Called once from app.initAppMenu.
pub fn registerActions(app: *c.AdwApplication) void {
    for (menu_actions) |entry| {
        const ga = c.g_simple_action_new(entry.name, null);
        _ = c.g_signal_connect_data(@ptrCast(ga), "activate", @as(c.GCallback, @ptrCast(&activateMenuAction)), @ptrFromInt(@intFromEnum(entry.action)), null, 0);
        c.g_action_map_add_action(@as(*c.GActionMap, @ptrCast(app)), @ptrCast(@alignCast(ga)));
        c.g_object_unref(@ptrCast(ga));
    }
}

const Item = struct {
    label: [*:0]const u8,
    detailed: [*:0]const u8,
};

const MenuRef = @TypeOf(c.g_menu_new());

fn appendAll(menu: MenuRef, items: []const Item) void {
    for (items) |it| {
        c.g_menu_append(@as(*c.GMenu, @ptrCast(menu)), it.label, it.detailed);
    }
}

fn section(items: []const Item) MenuRef {
    const m = c.g_menu_new();
    appendAll(m, items);
    return m;
}

fn addSection(parent: MenuRef, items: []const Item) void {
    const s = section(items);
    c.g_menu_append_section(@as(*c.GMenu, @ptrCast(parent)), null, @ptrCast(@alignCast(s)));
    c.g_object_unref(@ptrCast(s));
}

fn addGroup(parent: MenuRef, items: []const Item) void {
    const s = section(items);
    c.g_menu_append_section(@as(*c.GMenu, @ptrCast(parent)), null, @ptrCast(@alignCast(s)));
    c.g_object_unref(@ptrCast(s));
}

/// Build the hamburger menu model. Caller passes it to
/// gtk_menu_button_set_menu_model (which refs it) then unrefs.
pub fn buildMenu() MenuRef {
    const root = c.g_menu_new();

    addSection(root, &.{
        .{ .label = "New Workspace", .detailed = "app.new-workspace" },
        .{ .label = "New Window", .detailed = "app.new-window" },
    });

    addSection(root, &.{
        .{ .label = "New Tab", .detailed = "app.new-tab" },
        .{ .label = "New Browser Panel", .detailed = "app.new-browser-panel" },
        .{ .label = "Command Palette…", .detailed = "app.command-palette" },
    });

    const subs = c.g_menu_new();
    {
        const terminal = c.g_menu_new();
        addGroup(terminal, &.{
            .{ .label = "Copy", .detailed = "app.copy" },
            .{ .label = "Paste", .detailed = "app.paste" },
        });
        addGroup(terminal, &.{
            .{ .label = "Find…", .detailed = "app.find" },
            .{ .label = "Find Next", .detailed = "app.find-next" },
            .{ .label = "Find Previous", .detailed = "app.find-previous" },
        });
        addGroup(terminal, &.{
            .{ .label = "Clear Scrollback", .detailed = "app.clear-scrollback" },
        });
        c.g_menu_append_submenu(@as(*c.GMenu, @ptrCast(subs)), "Terminal", @ptrCast(@alignCast(terminal)));
        c.g_object_unref(@ptrCast(terminal));
    }
    {
        const splits = c.g_menu_new();
        addGroup(splits, &.{
            .{ .label = "New Column", .detailed = "app.new-column" },
        });
        addGroup(splits, &.{
            .{ .label = "Move Column Left", .detailed = "app.move-column-left" },
            .{ .label = "Move Column Right", .detailed = "app.move-column-right" },
        });
        addGroup(splits, &.{
            .{ .label = "Toggle Layout Mode", .detailed = "app.toggle-layout-mode" },
            .{ .label = "Toggle Zoom", .detailed = "app.maximize-column" },
            .{ .label = "Equalize Splits", .detailed = "app.equalize-splits" },
        });
        c.g_menu_append_submenu(@as(*c.GMenu, @ptrCast(subs)), "Splits & Layout", @ptrCast(@alignCast(splits)));
        c.g_object_unref(@ptrCast(splits));
    }
    {
        const tabs = c.g_menu_new();
        addGroup(tabs, &.{
            .{ .label = "Rename Tab…", .detailed = "app.rename-tab" },
        });
        addGroup(tabs, &.{
            .{ .label = "Next Tab", .detailed = "app.next-tab" },
            .{ .label = "Previous Tab", .detailed = "app.prev-tab" },
        });
        addGroup(tabs, &.{
            .{ .label = "Close Tab", .detailed = "app.close-tab" },
            .{ .label = "Close Other Tabs", .detailed = "app.close-other-tabs" },
            .{ .label = "Close Tabs to Right", .detailed = "app.close-tabs-to-right" },
        });
        c.g_menu_append_submenu(@as(*c.GMenu, @ptrCast(subs)), "Tabs", @ptrCast(@alignCast(tabs)));
        c.g_object_unref(@ptrCast(tabs));
    }
    {
        const browser = c.g_menu_new();
        addGroup(browser, &.{
            .{ .label = "New Browser Panel", .detailed = "app.new-browser-panel" },
            .{ .label = "New Browser Tab", .detailed = "app.new-browser-tab" },
        });
        addGroup(browser, &.{
            .{ .label = "Back", .detailed = "app.browser-back" },
            .{ .label = "Forward", .detailed = "app.browser-forward" },
            .{ .label = "Reload", .detailed = "app.browser-reload" },
        });
        addGroup(browser, &.{
            .{ .label = "Developer Tools", .detailed = "app.browser-inspector" },
        });
        c.g_menu_append_submenu(@as(*c.GMenu, @ptrCast(subs)), "Browser", @ptrCast(@alignCast(browser)));
        c.g_object_unref(@ptrCast(browser));
    }
    c.g_menu_append_section(@as(*c.GMenu, @ptrCast(root)), null, @ptrCast(@alignCast(subs)));
    c.g_object_unref(@ptrCast(subs));

    addSection(root, &.{
        .{ .label = "Toggle Fullscreen", .detailed = "app.toggle-fullscreen" },
        .{ .label = "Close Window", .detailed = "app.close-window" },
    });

    addSection(root, &.{
        .{ .label = "Preferences", .detailed = "app.preferences" },
        .{ .label = "Keyboard shortcuts", .detailed = "app.shortcuts" },
        .{ .label = "About Séance", .detailed = "app.about" },
        .{ .label = "Quit", .detailed = "app.quit" },
    });

    return root;
}

test "menu actions have unique non-empty names and distinct actions" {
    for (menu_actions, 0..) |entry, i| {
        try std.testing.expect(std.mem.span(entry.name).len > 0);
        for (menu_actions[0..i]) |other| {
            try std.testing.expect(!std.mem.eql(u8, std.mem.span(entry.name), std.mem.span(other.name)));
        }
    }
    var distinct: usize = 0;
    for (menu_actions, 0..) |entry, i| {
        var seen = false;
        for (menu_actions[0..i]) |other| {
            if (entry.action == other.action) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    try std.testing.expectEqual(menu_actions.len, distinct);
}
