const std = @import("std");
const c = @import("c.zig").c;
const Pane = @import("pane.zig").Pane;
const Panel = @import("panel.zig").Panel;
const WebPanel = @import("web_panel.zig").WebPanel;
const text_mod = @import("text.zig");

// Module-level state for cross-group tab transfer via AdwTabView.
// When a page is detached during a transfer, we stash the panel here
// so page-attached on the destination can pick it up.
var pending_transfer_panel: ?Panel = null;

/// Cast any libadwaita/GTK pointer to *GtkWidget (handles alignment).
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

pub const PaneGroup = struct {
    pub const FindPanelResult = struct { panel: Panel, index: usize };

    id: u64,
    workspace_id: u64,
    panels: std.ArrayList(Panel),
    active_panel: usize = 0,
    container: *c.GtkWidget, // GtkBox vertical: [AdwTabBar | separator | AdwTabView]
    tab_view: *c.AdwTabView,
    tab_bar: *c.GtkWidget, // AdwTabBar widget, stored for CSS class toggling
    alloc: std.mem.Allocator,
    is_zooming: bool = false,
    /// When true, onPageDetached skips cleanup — the caller handles it.
    programmatic_close: bool = false,
    /// Set after disconnectSignals() so destroy() won't re-disconnect
    /// on a potentially-finalized tab_view.
    signals_disconnected: bool = false,
    menu_target_page: ?*c.AdwTabPage = null,
    /// True when panels live on GtkFixed instead of inside AdwTabView.
    in_stacked_mode: bool = false,
    /// GtkFixed widget where panels are placed in stacked mode.
    fixed: ?*c.GtkWidget = null,
    /// Set when a non-terminal panel was added in stacked mode so the
    /// workspace's onTick triggers a layout pass.
    needs_stacked_layout: bool = false,

    pub fn create(alloc: std.mem.Allocator, cwd: ?[*:0]const u8, workspace_id: u64) !*PaneGroup {
        const self = try initGroupWidgets(alloc, workspace_id);
        const pane = try Pane.create(alloc, cwd, workspace_id, self.id);
        const panel = Panel{ .terminal = pane };
        try self.addPanel(panel);
        return self;
    }

    /// Create a PaneGroup with no initial panel. Used when moving a
    /// detached panel into a brand-new column.
    pub fn createEmpty(alloc: std.mem.Allocator, workspace_id: u64) !*PaneGroup {
        return initGroupWidgets(alloc, workspace_id);
    }

    /// Shared widget creation, signal wiring, and struct init for
    /// create() and createEmpty().
    fn initGroupWidgets(alloc: std.mem.Allocator, workspace_id: u64) !*PaneGroup {
        const group_id = nextId();

        const min_pane_size: c_int = 100;
        const container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(container, 1);
        c.gtk_widget_set_vexpand(container, 1);
        c.gtk_widget_set_size_request(container, min_pane_size, min_pane_size);
        c.gtk_widget_set_overflow(container, c.GTK_OVERFLOW_HIDDEN);

        const tab_view = c.adw_tab_view_new() orelse return error.OutOfMemory;
        c.adw_tab_view_set_shortcuts(tab_view, c.ADW_TAB_VIEW_SHORTCUT_NONE);
        const tv_widget = asWidget(tab_view);
        c.gtk_widget_set_hexpand(tv_widget, 1);
        c.gtk_widget_set_vexpand(tv_widget, 1);

        const menu = c.g_menu_new();
        c.g_menu_append(menu, "Rename tab", "tab.rename");
        c.g_menu_append(menu, "Close", "tab.close");
        c.g_menu_append(menu, "Close other tabs", "tab.close-others");
        c.g_menu_append(menu, "Close tabs to the right", "tab.close-right");
        c.adw_tab_view_set_menu_model(tab_view, @ptrCast(@alignCast(menu)));
        c.g_object_unref(@ptrCast(menu));

        const tab_bar = c.adw_tab_bar_new();
        c.adw_tab_bar_set_view(tab_bar, tab_view);
        c.adw_tab_bar_set_autohide(tab_bar, 0);
        c.adw_tab_bar_set_expand_tabs(tab_bar, 0);

        const add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_widget_add_css_class(@ptrCast(add_btn), "flat");
        c.gtk_widget_set_tooltip_text(@ptrCast(add_btn), "New tab");
        c.adw_tab_bar_set_end_action_widget(tab_bar, @ptrCast(add_btn));

        const tb_widget = asWidget(tab_bar);
        c.gtk_box_append(@ptrCast(container), tb_widget);
        const divider = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_box_append(@ptrCast(container), @ptrCast(divider));
        c.gtk_box_append(@ptrCast(container), tv_widget);

        const self = try alloc.create(PaneGroup);
        self.* = .{
            .id = group_id,
            .workspace_id = workspace_id,
            .panels = .empty,
            .container = container,
            .tab_view = tab_view,
            .tab_bar = tb_widget,
            .alloc = alloc,
        };

        const action_group = c.g_simple_action_group_new();

        const rename_action = c.g_simple_action_new("rename", null);
        _ = c.g_signal_connect_data(@ptrCast(rename_action), "activate", @as(c.GCallback, @ptrCast(&onCtxRename)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(rename_action));

        const close_action = c.g_simple_action_new("close", null);
        _ = c.g_signal_connect_data(@ptrCast(close_action), "activate", @as(c.GCallback, @ptrCast(&onCtxClose)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(close_action));

        const others_action = c.g_simple_action_new("close-others", null);
        _ = c.g_signal_connect_data(@ptrCast(others_action), "activate", @as(c.GCallback, @ptrCast(&onCtxCloseOthers)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(others_action));

        const right_action = c.g_simple_action_new("close-right", null);
        _ = c.g_signal_connect_data(@ptrCast(right_action), "activate", @as(c.GCallback, @ptrCast(&onCtxCloseRight)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(right_action));

        c.gtk_widget_insert_action_group(container, "tab", @ptrCast(action_group));
        c.g_object_unref(@ptrCast(action_group));

        _ = c.g_signal_connect_data(@ptrCast(tab_view), "close-page", @as(c.GCallback, @ptrCast(&onClosePage)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "page-detached", @as(c.GCallback, @ptrCast(&onPageDetached)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "page-attached", @as(c.GCallback, @ptrCast(&onPageAttached)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "notify::selected-page", @as(c.GCallback, @ptrCast(&onSelectedPageChanged)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "setup-menu", @as(c.GCallback, @ptrCast(&onSetupMenu)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "create-window", @as(c.GCallback, @ptrCast(&onCreateWindow)), null, null, 0);

        _ = c.g_signal_connect_data(@ptrCast(add_btn), "clicked", @as(c.GCallback, @ptrCast(&onAddClicked)), @ptrCast(self), null, 0);

        return self;
    }

    /// Disconnect all signal handlers (on AdwTabView and on each panel's
    /// widgets) so GTK won't call back into freed memory during widget
    /// teardown. Must be called while widgets are still alive (before
    /// gtk_fixed_remove). Safe to call multiple times.
    pub fn disconnectSignals(self: *PaneGroup) void {
        if (self.signals_disconnected) return;
        self.signals_disconnected = true;
        _ = c.g_signal_handlers_disconnect_matched(
            @as(c.gpointer, @ptrCast(self.tab_view)),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @as(c.gpointer, @ptrCast(self)),
        );
        for (self.panels.items) |panel| {
            panel.disconnectSignals();
        }
    }

    pub fn destroy(self: *PaneGroup) void {
        self.disconnectSignals();
        // Remove stacked panel widgets from GtkFixed before destroying
        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                for (self.panels.items) |panel| {
                    c.gtk_fixed_remove(@ptrCast(fixed), panel.getWidget());
                }
            }
        }
        for (self.panels.items) |panel| {
            panel.destroy(self.alloc);
        }
        self.panels.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn addPanel(self: *PaneGroup, panel: Panel) !void {
        try self.panels.append(self.alloc, panel);

        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                c.gtk_fixed_put(@ptrCast(fixed), panel.getWidget(), 0, 0);
                // Start with open animation at 0 (will animate in)
                panel.setStackedOpenAnim(0.0);
                // Signal workspace to run a layout pass so
                // set_size_request is applied on the next tick.
                self.needs_stacked_layout = true;
            }
            // Seat the newcomer in the row its weight owns, with or without a
            // fixed, so it never starts in a row another panel already fills.
            self.seatStackedRow(self.panels.items.len - 1);
            // Focus the newly added panel
            if (self.active_panel < self.panels.items.len - 1) {
                self.panels.items[self.active_panel].unfocus();
            }
            self.active_panel = self.panels.items.len - 1;
            panel.focus();
        } else {
            const page = c.adw_tab_view_append(self.tab_view, panel.getWidget());
            const title = panel.title();
            var buf: [65:0]u8 = [_:0]u8{0} ** 65;
            const tlen = text_mod.copy(buf[0..], title);
            buf[tlen] = 0;
            c.adw_tab_page_set_title(page, &buf);
            setTabIcon(page, panel.iconName());

            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
    }

    /// Assign every panel the row its height weight owns, matching the fixed
    /// point the tick animates toward: `frac_y` is the prefix weight over the
    /// total and `frac_h` its own share. Used where the whole column must be
    /// correct in the same frame, such as a panel expelled into it.
    pub fn tileStackedRows(self: *PaneGroup) void {
        const total = self.totalHeightWeight();
        var y: f64 = 0.0;
        for (self.panels.items) |panel| {
            const share = panel.getHeightWeight() / total;
            panel.setStackedFracY(y);
            panel.setStackedFracH(share);
            y += share;
        }
    }

    /// Seat only the panel at `index` at its weight-based position, leaving the
    /// other rows where they are so the tick keeps animating their squeeze.
    /// Used when a panel fades in and must not start in a row it does not own.
    pub fn seatStackedRow(self: *PaneGroup, index: usize) void {
        if (index >= self.panels.items.len) return;
        const total = self.totalHeightWeight();
        var y: f64 = 0.0;
        for (self.panels.items[0..index]) |panel| y += panel.getHeightWeight() / total;
        const panel = self.panels.items[index];
        panel.setStackedFracY(y);
        panel.setStackedFracH(panel.getHeightWeight() / total);
    }

    fn totalHeightWeight(self: *const PaneGroup) f64 {
        var total: f64 = 0.0;
        for (self.panels.items) |panel| total += panel.getHeightWeight();
        return if (total > 0.0) total else 1.0;
    }

    pub fn newPanel(self: *PaneGroup, cwd: ?[*:0]const u8) !*Pane {
        const pane = try Pane.create(self.alloc, cwd, self.workspace_id, self.id);

        const panel = Panel{ .terminal = pane };
        try self.addPanel(panel);
        return pane;
    }

    pub fn newBrowserPanel(self: *PaneGroup, url: []const u8) !*WebPanel {
        const wp = try WebPanel.create(self.alloc, url);
        const panel = Panel{ .webkit = wp };
        try self.addPanel(panel);
        wp.focus();
        return wp;
    }

    /// Remove panel at index. Returns true if the group is now empty.
    /// Caller is responsible for handling the empty-group case.
    pub fn removePanel(self: *PaneGroup, index: usize) bool {
        if (index >= self.panels.items.len) return self.panels.items.len == 0;

        const panel = self.panels.items[index];
        _ = self.panels.orderedRemove(index);

        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                c.gtk_fixed_remove(@ptrCast(fixed), panel.getWidget());
            }
        } else {
            // Close the tab view page; suppress onPageDetached cleanup
            self.programmatic_close = true;
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(index));
            c.adw_tab_view_close_page(self.tab_view, page);
            self.programmatic_close = false;
        }

        panel.destroy(self.alloc);

        if (self.panels.items.len == 0) return true;

        if (self.active_panel >= self.panels.items.len) {
            self.active_panel = self.panels.items.len - 1;
        }
        if (!self.in_stacked_mode) {
            self.switchToPanel(self.active_panel);
        }
        // Ensure keyboard focus lands on the new active panel.
        // In tabbed mode switchToPanel may be a no-op when the page
        // was already auto-selected by adw_tab_view_close_page.
        self.panels.items[self.active_panel].focus();
        return false;
    }

    /// Remove the active panel. Returns true if the group is now empty.
    pub fn removeActivePanel(self: *PaneGroup) bool {
        return self.removePanel(self.active_panel);
    }

    pub fn switchToPanel(self: *PaneGroup, index: usize) void {
        if (index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            // In stacked mode, directly update active_panel and focus
            if (self.active_panel < self.panels.items.len) {
                self.panels.items[self.active_panel].unfocus();
            }
            self.active_panel = index;
            self.panels.items[index].focus();
        } else {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(index));
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
    }

    pub fn getActivePanel(self: *const PaneGroup) ?Panel {
        if (self.panels.items.len == 0) return null;
        if (self.active_panel >= self.panels.items.len) return null;
        return self.panels.items[self.active_panel];
    }

    pub fn focusedTerminalPane(self: *const PaneGroup) ?*Pane {
        const panel = self.getActivePanel() orelse return null;
        return panel.asTerminal();
    }

    pub fn nextPanel(self: *PaneGroup) void {
        if (self.panels.items.len <= 1) return;
        self.switchToPanel((self.active_panel + 1) % self.panels.items.len);
    }

    pub fn prevPanel(self: *PaneGroup) void {
        if (self.panels.items.len <= 1) return;
        if (self.active_panel == 0) {
            self.switchToPanel(self.panels.items.len - 1);
        } else {
            self.switchToPanel(self.active_panel - 1);
        }
    }

    pub fn focus(self: *PaneGroup) void {
        c.gtk_widget_add_css_class(self.tab_bar, "tab-bar-focused");
        if (self.getActivePanel()) |panel| panel.focus();
    }

    pub fn unfocus(self: *PaneGroup) void {
        c.gtk_widget_remove_css_class(self.tab_bar, "tab-bar-focused");
        if (self.getActivePanel()) |panel| panel.unfocus();
    }

    pub fn getWidget(self: *const PaneGroup) *c.GtkWidget {
        return self.container;
    }

    /// Move all panels from AdwTabView to GtkFixed for stacked display.
    /// The PaneGroup container remains on GtkFixed (for tab bar animation)
    /// but its tab_view content is hidden.
    pub fn enterStackedMode(self: *PaneGroup, fixed: *c.GtkWidget) void {
        if (self.in_stacked_mode) return;
        self.in_stacked_mode = true;
        self.fixed = fixed;

        // Suppress signals during reparenting.
        self.programmatic_close = true;

        // Ref all panel widgets before removing them from AdwTabView.
        for (self.panels.items) |panel| {
            _ = c.g_object_ref(@ptrCast(panel.getWidget()));
        }

        // Directly unparent each panel widget from the AdwTabView's internal
        // container rather than using adw_tab_view_close_page (which can
        // leave the widget parented in an internal container and schedule
        // deferred cleanup on repeated enter/exit cycles).
        // Unparenting directly is safe because we hold an extra ref.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            if (c.gtk_widget_get_parent(w) != null) {
                c.gtk_widget_unparent(w);
            }
        }

        // Close the now-stale (childless) pages immediately.  Widgets are
        // parentless at this point, so page dispose's gtk_widget_unparent
        // is a no-op.  Without this, the AdwTabView retains pages whose
        // dispose will later unparent widgets that have since been moved
        // to GtkFixed (e.g. after an expel moves a panel to another group
        // and the source column is destroyed, finalizing this tab_view).
        var stale_n = c.adw_tab_view_get_n_pages(self.tab_view);
        while (stale_n > 0) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, 0);
            c.adw_tab_view_close_page(self.tab_view, page);
            const new_n = c.adw_tab_view_get_n_pages(self.tab_view);
            if (new_n >= stale_n) break;
            stale_n = new_n;
        }

        // Hide tab_view
        c.gtk_widget_set_visible(asWidget(self.tab_view), 0);

        // Add all panel widgets to GtkFixed, then seat every row at its
        // weight-based position so the first stacked frame is already tiled.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            c.gtk_fixed_put(@ptrCast(fixed), w, 0, 0);
            _ = c.g_object_unref(@ptrCast(w));
        }
        self.tileStackedRows();

        self.programmatic_close = false;
    }

    /// Move all panels from GtkFixed back to AdwTabView for tabbed display.
    pub fn exitStackedMode(self: *PaneGroup) void {
        if (!self.in_stacked_mode) return;
        self.in_stacked_mode = false;

        const fixed = self.fixed orelse return;

        // Ref all panel widgets, restore visibility/opacity (cleared by
        // stacked→tabbed animation), remove divider CSS classes (they're
        // meaningless inside AdwTabView and must be cleared before
        // reparenting to avoid stale style state), then remove from GtkFixed.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            c.gtk_widget_set_visible(w, 1);
            c.gtk_widget_set_opacity(w, 1.0);
            // Clear the explicit size request left by stacked layout so the
            // panel doesn't inflate AdwTabView's natural size (which GtkFixed
            // uses for allocation).  Without this, the tabbed container stays
            // at full-viewport width when a second column is added.
            c.gtk_widget_set_size_request(w, -1, -1);
            c.gtk_widget_remove_css_class(w, "column-has-divider");
            c.gtk_widget_remove_css_class(w, "column-has-right-divider");
            c.gtk_widget_remove_css_class(w, "row-has-divider");
            c.gtk_fixed_set_child_transform(@ptrCast(fixed), w, null);
            _ = c.g_object_ref(@ptrCast(w));
            c.gtk_fixed_remove(@ptrCast(fixed), w);
        }

        // Suppress signals while cleaning up stale pages and re-adding panels.
        self.programmatic_close = true;

        // Clean up stale (childless) pages left by enterStackedMode.
        // enterStackedMode unparents widgets directly without close_page,
        // so the tab_view may still have page objects with no children.
        var stale_n = c.adw_tab_view_get_n_pages(self.tab_view);
        while (stale_n > 0) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, 0);
            c.adw_tab_view_close_page(self.tab_view, page);
            const new_n = c.adw_tab_view_get_n_pages(self.tab_view);
            if (new_n >= stale_n) break;
            stale_n = new_n;
        }

        // Add all panels back to AdwTabView as fresh pages.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            const page = c.adw_tab_view_append(self.tab_view, w);
            const title = panel.title();
            var buf: [65:0]u8 = [_:0]u8{0} ** 65;
            const tlen = text_mod.copy(buf[0..], title);
            buf[tlen] = 0;
            c.adw_tab_page_set_title(page, &buf);
            setTabIcon(page, panel.iconName());
            _ = c.g_object_unref(@ptrCast(w));
        }

        self.programmatic_close = false;

        // Show tab_view
        c.gtk_widget_set_visible(asWidget(self.tab_view), 1);

        // Select active panel (fires onSelectedPageChanged normally)
        if (self.active_panel < self.panels.items.len) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(self.active_panel));
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }

        self.fixed = null;
    }

    /// Find a panel by its ID in this group. Returns the panel and its index.
    pub fn findPanelById(self: *const PaneGroup, panel_id: u64) ?FindPanelResult {
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == panel_id) return .{ .panel = panel, .index = i };
        }
        return null;
    }

    /// Find a terminal pane by ID in this group.
    pub fn findPaneById(self: *const PaneGroup, pane_id: u64) ?*Pane {
        for (self.panels.items) |panel| {
            if (panel.getId() == pane_id) {
                return panel.asTerminal();
            }
        }
        return null;
    }

    /// Returns true if any terminal pane in this group has unread notifications.
    pub fn hasUnreadPane(self: *const PaneGroup) bool {
        for (self.panels.items) |panel| {
            const pane = panel.asTerminal() orelse continue;
            if (pane.has_unread) return true;
        }
        return false;
    }

    /// Close all panels except the one at keep_index.
    pub fn closeOtherPanels(self: *PaneGroup, keep_index: usize) void {
        if (keep_index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            // Remove panels manually in reverse order
            var i = self.panels.items.len;
            while (i > 0) {
                i -= 1;
                if (i != keep_index) {
                    _ = self.removePanel(i);
                }
            }
            self.active_panel = 0;
        } else {
            const keep_page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(keep_index));
            c.adw_tab_view_close_other_pages(self.tab_view, keep_page);
        }
    }

    /// Close all panels to the right of from_index.
    pub fn closePanelsToRight(self: *PaneGroup, from_index: usize) void {
        if (from_index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            var i = self.panels.items.len;
            while (i > from_index + 1) {
                i -= 1;
                _ = self.removePanel(i);
            }
        } else {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(from_index));
            c.adw_tab_view_close_pages_after(self.tab_view, page);
        }
    }

    pub fn reorderPanel(self: *PaneGroup, from: usize, to: usize) void {
        if (from == to) return;
        if (from >= self.panels.items.len or to >= self.panels.items.len) return;

        const panel = self.panels.items[from];
        _ = self.panels.orderedRemove(from);
        self.panels.insert(self.alloc, to, panel) catch return;

        if (!self.in_stacked_mode) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(from));
            _ = c.adw_tab_view_reorder_page(self.tab_view, page, @intCast(to));
        }

        if (self.active_panel == from) {
            self.active_panel = to;
        } else if (from < self.active_panel and to >= self.active_panel) {
            self.active_panel -= 1;
        } else if (from > self.active_panel and to <= self.active_panel) {
            self.active_panel += 1;
        }

        // Every row is visible, so the new order is seated now rather than
        // animating from the previous positions.
        if (self.in_stacked_mode) self.tileStackedRows();
    }

    /// Update the tab bar title for a panel by its pane ID.
    pub fn updateTitleForPane(self: *PaneGroup, pane_id: u64, title: []const u8) void {
        if (self.in_stacked_mode) return; // no tab pages in stacked mode
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == pane_id) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(i));
                var buf: [65:0]u8 = [_:0]u8{0} ** 65;
                const tlen = text_mod.copy(buf[0..], title);
                buf[tlen] = 0;
                c.adw_tab_page_set_title(page, &buf);
                setTabIcon(page, panel.iconName());
                return;
            }
        }
    }

    /// Set tab notification badge for a panel by pane ID.
    pub fn setNotificationForPane(self: *PaneGroup, pane_id: u64, has_notification: bool) void {
        if (self.in_stacked_mode) return; // no tab pages in stacked mode
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == pane_id) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(i));
                c.adw_tab_page_set_needs_attention(page, if (has_notification) 1 else 0);
                return;
            }
        }
    }

    /// Clear tab attention indicators on all panels in this group.
    pub fn clearAllTabNotifications(self: *PaneGroup) void {
        if (self.in_stacked_mode) return;
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
            c.adw_tab_page_set_needs_attention(page, 0);
        }
    }

    /// Find panel index by matching the widget inside an AdwTabPage.
    fn findPanelIndexByWidget(self: *PaneGroup, widget: *c.GtkWidget) ?usize {
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getWidget() == widget) return i;
        }
        return null;
    }
};

fn setTabIcon(page_: ?*c.AdwTabPage, icon_name: [*:0]const u8) void {
    const page = page_ orelse return;
    const icon = c.g_themed_icon_new(icon_name);
    c.adw_tab_page_set_icon(page, icon);
    c.g_object_unref(@ptrCast(icon));
}

// ── AdwTabView signal handlers ─────────────────────────────────────

fn onClosePage(_: *c.AdwTabView, page: *c.AdwTabPage, user_data: c.gpointer) callconv(.c) c.gboolean {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    c.adw_tab_view_close_page_finish(self.tab_view, page, 1);
    return 1; // handled
}

fn onPageDetached(tab_view: *c.AdwTabView, page: *c.AdwTabPage, _: c.gint, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    const child = c.adw_tab_page_get_child(page);

    // If transferring to another tab view, stash the panel instead of destroying
    if (c.adw_tab_view_get_is_transferring_page(tab_view) != 0) {
        if (self.findPanelIndexByWidget(child)) |idx| {
            pending_transfer_panel = self.panels.items[idx];
            _ = self.panels.orderedRemove(idx);
            if (self.active_panel >= self.panels.items.len and self.panels.items.len > 0) {
                self.active_panel = self.panels.items.len - 1;
            }
        }
        if (self.panels.items.len == 0) {
            _ = c.g_idle_add(@ptrCast(&idleCloseEmptyGroup), @ptrFromInt(self.id));
        }
        return;
    }

    // Programmatic close (removePanel) — caller handles cleanup.
    // Also ignore in stacked mode: panels live on GtkFixed, not in the
    // tab view, so any deferred page-detached signals are stale.
    if (self.is_zooming or self.programmatic_close or self.in_stacked_mode) return;

    // User-initiated close (clicked tab close button): clean up the panel
    if (self.findPanelIndexByWidget(child)) |idx| {
        const panel = self.panels.items[idx];
        _ = self.panels.orderedRemove(idx);
        panel.destroy(self.alloc);
        if (self.active_panel >= self.panels.items.len and self.panels.items.len > 0) {
            self.active_panel = self.panels.items.len - 1;
        }
    }

    if (self.panels.items.len == 0) {
        _ = c.g_idle_add(@ptrCast(&idleCloseEmptyGroup), @ptrFromInt(self.id));
    }
}

fn onPageAttached(_: *c.AdwTabView, page: *c.AdwTabPage, position: c.gint, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));

    if (pending_transfer_panel) |panel| {
        pending_transfer_panel = null;
        const pos: usize = @intCast(position);

        if (panel.asTerminal()) |pane| {
            pane.pane_group_id = self.id;
            pane.workspace_id = self.workspace_id;
        }

        self.panels.insert(self.alloc, pos, panel) catch return;

        const title = panel.title();
        var buf: [65:0]u8 = [_:0]u8{0} ** 65;
        const tlen = text_mod.copy(buf[0..], title);
        buf[tlen] = 0;
        c.adw_tab_page_set_title(page, &buf);
        setTabIcon(page, panel.iconName());
    }
}

fn onSelectedPageChanged(_: *c.GObject, _: *c.GParamSpec, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    // Suppress during enterStackedMode/exitStackedMode reparenting
    if (self.programmatic_close) return;
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    const child = c.adw_tab_page_get_child(page);

    if (self.active_panel < self.panels.items.len) {
        self.panels.items[self.active_panel].unfocus();
    }

    if (self.findPanelIndexByWidget(child)) |idx| {
        self.active_panel = idx;
        self.panels.items[idx].focus();
    }
}

fn onSetupMenu(_: *c.AdwTabView, page: ?*c.AdwTabPage, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    self.menu_target_page = page;
}

fn onCreateWindow(_: *c.AdwTabView, _: c.gpointer) callconv(.c) ?*c.AdwTabView {
    return null;
}

fn onAddClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    _ = self.newPanel(null) catch {};
}

// ── Context menu action handlers ───────────────────────────────────

fn onCtxRename(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;
    const child = c.adw_tab_page_get_child(page);
    const pane = blk: {
        for (self.panels.items) |panel| {
            if (panel.getWidget() == child) break :blk panel.asTerminal() orelse return;
        }
        return;
    };

    _ = showRenameDialog(std.heap.c_allocator, self, pane);
}

/// Builds, owns and presents the rename dialog for one pane. Returns the
/// dialog so tests can drive its response without a pointer-driven menu.
fn showRenameDialog(alloc: std.mem.Allocator, group: *PaneGroup, pane: *Pane) ?*c.AdwAlertDialog {
    const root = c.gtk_widget_get_root(asWidget(group.tab_view)) orelse return null;

    const dialog = c.adw_alert_dialog_new("Rename tab", null);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "clear", "Clear");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", "Rename");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", c.ADW_RESPONSE_SUGGESTED);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    const entry = c.gtk_entry_new();
    c.gtk_entry_set_activates_default(@ptrCast(entry), 1);
    const display_title = pane.getDisplayTitle() orelse "Terminal";
    var title_z: [257]u8 = undefined;
    const tlen = text_mod.copy(title_z[0..], display_title);
    title_z[tlen] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), &title_z);
    c.adw_alert_dialog_set_extra_child(@as(*c.AdwAlertDialog, @ptrCast(dialog)), entry);

    const alert: *c.AdwAlertDialog = @ptrCast(@alignCast(dialog));
    presentDialog(alloc, alert, group.id, pane.id, false, &onCtxRenameResponse, root);

    _ = c.gtk_widget_grab_focus(entry);
    c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    return alert;
}

/// One outstanding tab dialog. The dialog owns this allocation and GTK frees it
/// through the signal destroy notify, whether a response was delivered or the
/// window took the dialog down first. Nothing here references the group, the
/// target page, or the group's allocator, so a late response can only find a
/// live target or cancel.
const TabDialogCtx = struct {
    group_id: u64,
    panel_id: u64,
    right_only: bool = false,
    alloc: std.mem.Allocator,
    /// Live lookups; tests substitute them to model a destroyed group and a
    /// tab that moved elsewhere.
    resolve: GroupResolver = .{},
};

/// Where a pending dialog finds its targets. Both lookups walk the live window
/// manager in production.
const GroupResolver = struct {
    by_id: *const fn (group_id: u64) ?*PaneGroup = findLiveGroup,
    by_pane: *const fn (pane_id: u64) ?*PaneGroup = findGroupContainingPane,
};

fn presentDialog(
    alloc: std.mem.Allocator,
    dialog: *c.AdwAlertDialog,
    group_id: u64,
    panel_id: u64,
    right_only: bool,
    handler: *const fn (*c.AdwAlertDialog, [*:0]const u8, c.gpointer) callconv(.c) void,
    root: *c.GtkRoot,
) void {
    ownDialog(alloc, dialog, group_id, panel_id, right_only, handler, .{});
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), @ptrCast(@alignCast(root)));
}

/// Gives one outstanding dialog ownership of its context. The dialog frees it
/// through the destroy notify, so no response path can double-free and a
/// dialog torn down with the window still releases.
fn ownDialog(
    alloc: std.mem.Allocator,
    dialog: *c.AdwAlertDialog,
    group_id: u64,
    panel_id: u64,
    right_only: bool,
    handler: *const fn (*c.AdwAlertDialog, [*:0]const u8, c.gpointer) callconv(.c) void,
    resolver: GroupResolver,
) void {
    const ctx = alloc.create(TabDialogCtx) catch return;
    ctx.* = .{ .group_id = group_id, .panel_id = panel_id, .right_only = right_only, .alloc = alloc, .resolve = resolver };

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(dialog)),
        "response",
        @as(c.GCallback, @ptrCast(handler)),
        @ptrCast(ctx),
        @ptrCast(&releaseTabDialog),
        0,
    );
}

fn releaseTabDialog(data: c.gpointer, _: ?*anyopaque) callconv(.c) void {
    const ctx: *TabDialogCtx = @ptrCast(@alignCast(data));
    ctx.alloc.destroy(ctx);
}

fn findLiveGroup(group_id: u64) ?*PaneGroup {
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return null;
    for (wm.windows.items) |state| {
        for (state.workspaces.items) |ws| {
            for (ws.columns.items) |col| {
                for (col.groups.items) |group| {
                    if (group.id == group_id) return group;
                }
            }
        }
    }
    return null;
}

/// Finds the live group that currently holds a pane, following a tab that was
/// dragged to another group or window after its dialog opened.
fn findGroupContainingPane(pane_id: u64) ?*PaneGroup {
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return null;
    for (wm.windows.items) |state| {
        for (state.workspaces.items) |ws| {
            if (ws.findGroupContainingPane(pane_id)) |group| return group;
        }
    }
    return null;
}

fn onCtxRenameResponse(dialog: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *TabDialogCtx = @ptrCast(@alignCast(data));
    const resp = std.mem.sliceTo(response, 0);
    if (!std.mem.eql(u8, resp, "rename") and !std.mem.eql(u8, resp, "clear")) return;

    const title: ?[]const u8 = if (std.mem.eql(u8, resp, "rename")) dialogEntryText(dialog) else null;
    _ = applyRenameResponse(ctx.resolve, ctx.group_id, ctx.panel_id, title);
}

/// Reads the rename entry from the live dialog; null when it was emptied.
fn dialogEntryText(dialog: *c.AdwAlertDialog) ?[]const u8 {
    const child = c.adw_alert_dialog_get_extra_child(dialog) orelse return null;
    const entry: *c.GtkEditable = @ptrCast(@alignCast(child));
    const raw: [*c]const u8 = c.gtk_editable_get_text(entry);
    if (raw == null) return null;
    const trimmed = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

/// Applies a rename decision to the live pane, following it across groups.
/// Returns false when the pane is gone, so a late response is cancellation.
fn applyRenameResponse(resolve: GroupResolver, group_id: u64, pane_id: u64, title: ?[]const u8) bool {
    const owner = if (resolve.by_id(group_id)) |group|
        (if (group.findPaneById(pane_id) != null) group else null)
    else
        null;
    const group = owner orelse resolve.by_pane(pane_id) orelse return false;
    const pane = group.findPaneById(pane_id) orelse return false;

    if (title) |text| {
        pane.setCustomTitle(text);
        group.updateTitleForPane(pane_id, text);
    } else {
        pane.clearCustomTitle();
        group.updateTitleForPane(pane_id, pane.getCachedTitle() orelse "Terminal");
    }
    return true;
}

fn onCtxClose(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;
    c.adw_tab_view_close_page(self.tab_view, page);
}

fn onCtxCloseOthers(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;

    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    if (n <= 1) return;

    if (n > 2) {
        showCloseConfirmDialog(self, page, false);
        return;
    }
    c.adw_tab_view_close_other_pages(self.tab_view, page);
}

fn onCtxCloseRight(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;

    const page_pos = c.adw_tab_view_get_page_position(self.tab_view, page);
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    const count_right = n - page_pos - 1;
    if (count_right <= 0) return;

    if (count_right > 1) {
        showCloseConfirmDialog(self, page, true);
        return;
    }
    c.adw_tab_view_close_pages_after(self.tab_view, page);
}

/// Resolves the panel ID that owns a live tab page; null once the page's
/// panel left this group.
fn panelIdForPage(group: *PaneGroup, page: *c.AdwTabPage) ?u64 {
    const child = c.adw_tab_page_get_child(page);
    for (group.panels.items) |panel| {
        if (panel.getWidget() == child) return panel.getId();
    }
    return null;
}

fn showCloseConfirmDialog(group: *PaneGroup, page: *c.AdwTabPage, right_only: bool) void {
    _ = showCloseConfirmDialogWith(std.heap.c_allocator, group, page, right_only);
}

/// Builds, owns and presents the close-confirmation dialog. Returns the dialog
/// so tests can drive its response without a pointer-driven menu.
fn showCloseConfirmDialogWith(alloc: std.mem.Allocator, group: *PaneGroup, page: *c.AdwTabPage, right_only: bool) ?*c.AdwAlertDialog {
    const panel_id = panelIdForPage(group, page) orelse return null;
    const root = c.gtk_widget_get_root(asWidget(group.tab_view)) orelse return null;

    const page_pos = c.adw_tab_view_get_page_position(group.tab_view, page);
    const n = c.adw_tab_view_get_n_pages(group.tab_view);
    const count: usize = if (right_only)
        @intCast(n - page_pos - 1)
    else
        @intCast(n - 1);

    const title: [*:0]const u8 = if (right_only) "Close Tabs to the Right?" else "Close Other Tabs?";
    var msg_buf: [128:0]u8 = [_:0]u8{0} ** 128;
    _ = std.fmt.bufPrint(&msg_buf, "This will close {d} tab{s} and their terminal sessions.", .{ count, if (count != 1) "s" else "" }) catch {};

    const dialog = c.adw_alert_dialog_new(title, &msg_buf);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", "Close");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    const alert: *c.AdwAlertDialog = @ptrCast(@alignCast(dialog));
    presentDialog(alloc, alert, group.id, panel_id, right_only, &onCloseDialogResponse, root);
    return alert;
}

fn onCloseDialogResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *TabDialogCtx = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "close")) return;
    _ = applyCloseResponse(ctx.resolve, ctx.group_id, ctx.panel_id, ctx.right_only);
}

/// Resolves a panel's current tab page in a live group; null after the tab was
/// closed or moved elsewhere, which turns the response into a no-op.
fn tabPageForPanel(group: *PaneGroup, panel_id: u64) ?*c.AdwTabPage {
    const found = group.findPanelById(panel_id) orelse return null;
    return c.adw_tab_view_get_page(group.tab_view, found.panel.getWidget());
}

/// Applies a confirmed close to the live group. Returns false, touching no tab,
/// when the group or the target panel disappeared while the dialog was open.
fn applyCloseResponse(resolve: GroupResolver, group_id: u64, panel_id: u64, right_only: bool) bool {
    const group = resolve.by_id(group_id) orelse return false;
    const page = tabPageForPanel(group, panel_id) orelse return false;
    if (right_only) {
        c.adw_tab_view_close_pages_after(group.tab_view, page);
    } else {
        c.adw_tab_view_close_other_pages(group.tab_view, page);
    }
    return true;
}

// ── Idle callback to close empty groups ────────────────────────────

fn idleCloseEmptyGroup(user_data: c.gpointer) callconv(.c) c.gboolean {
    const group_id: u64 = @intFromPtr(user_data);
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return 0;
    for (wm.windows.items) |state| {
        for (state.workspaces.items, 0..) |ws, ws_idx| {
            if (ws.closeEmptyGroup(group_id)) {
                if (ws.columns.items.len == 0) {
                    state.closeWorkspace(ws_idx);
                } else {
                    state.sidebar.refresh();
                }
                return 0;
            }
        }
    }
    return 0; // G_SOURCE_REMOVE
}

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var test_group: ?*PaneGroup = null;

fn testGroupById(_: u64) ?*PaneGroup {
    return test_group;
}

fn testGroupByPane(_: u64) ?*PaneGroup {
    return test_group;
}

fn missingGroup(_: u64) ?*PaneGroup {
    return null;
}

fn testResolver() GroupResolver {
    return .{ .by_id = testGroupById, .by_pane = testGroupByPane };
}

fn liveGroupResolver() GroupResolver {
    return .{};
}

/// Creates a group with `count` terminal panels, returning it with its first
/// pane. The container is sunk so tests can finalize it after `destroy`.
fn destroyTestGroup(group: *PaneGroup, container: *c.GtkWidget) void {
    group.destroy();
    c.g_object_unref(@ptrCast(container));
    test_group = null;
}

fn makeTestGroup(alloc: std.mem.Allocator, count: usize) !*PaneGroup {
    const group = try PaneGroup.createEmpty(alloc, 1);
    for (0..count) |_| {
        _ = try group.newPanel(null);
    }
    return group;
}

/// Append a panel without going through addPanel, whose stacked branch focuses
/// the new pane. Tests that only care about row fractions use this.
fn appendTestPanel(group: *PaneGroup, alloc: std.mem.Allocator) !Panel {
    const pane = try Pane.create(alloc, null, 1, group.id);
    const panel = Panel{ .terminal = pane };
    try group.panels.append(alloc, panel);
    return panel;
}

test "adding to a resized stacked group seats the newcomer by weight" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 2);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);

    switch (group.panels.items[0]) {
        .terminal => |p| p.height_weight = 3.0,
        .webkit => unreachable,
    }
    group.in_stacked_mode = true;

    _ = try group.newPanel(null);

    // Prefix weight is 3 + 1 = 4 of 5, so the newcomer owns the bottom fifth.
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 5.0), group.panels.items[2].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[2].getStackedFracH(), 1e-9);
}

test "tiling a resized stacked group fills the column by weight" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);
    group.in_stacked_mode = true;

    switch (group.panels.items[0]) {
        .terminal => |p| p.height_weight = 3.0,
        .webkit => unreachable,
    }
    group.tileStackedRows();

    try testing.expectApproxEqAbs(@as(f64, 0.0), group.panels.items[0].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 5.0), group.panels.items[0].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 5.0), group.panels.items[1].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[1].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 5.0), group.panels.items[2].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[2].getStackedFracH(), 1e-9);
}

test "tiling equal weights keeps exact thirds" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);
    group.in_stacked_mode = true;

    group.tileStackedRows();

    for (group.panels.items, 0..) |panel, i| {
        const i_f: f64 = @floatFromInt(i);
        try testing.expectApproxEqAbs(i_f / 3.0, panel.getStackedFracY(), 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), panel.getStackedFracH(), 1e-9);
    }
}

test "seatStackedRow gives a panel joining a stacked group its own row" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 1);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);
    // Only the row arithmetic is under test, so the group needs no GtkFixed:
    // a single stacked panel fills the column, as it does live.
    group.in_stacked_mode = true;
    group.panels.items[0].setStackedFracY(0.0);
    group.panels.items[0].setStackedFracH(1.0);

    _ = try appendTestPanel(group, alloc);
    group.seatStackedRow(1);

    // The newcomer starts in the bottom half; the row above keeps its current
    // size so the tick can animate the squeeze instead of snapping.
    try testing.expectApproxEqAbs(@as(f64, 0.0), group.panels.items[0].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), group.panels.items[0].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), group.panels.items[1].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), group.panels.items[1].getStackedFracH(), 1e-9);
}

test "tileStackedRows repairs rows that already overlapped" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 2);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);
    group.in_stacked_mode = true;

    // Adding a panel to a stacked group leaves the first panel full height,
    // so a group can reach a transfer already overlapping.
    group.panels.items[0].setStackedFracY(0.0);
    group.panels.items[0].setStackedFracH(1.0);
    group.panels.items[1].setStackedFracY(0.5);
    group.panels.items[1].setStackedFracH(0.5);

    _ = try appendTestPanel(group, alloc);
    group.tileStackedRows();

    // Equal weights: the overlapped rows are replaced by exact thirds.
    for (group.panels.items, 0..) |panel, i| {
        const i_f: f64 = @floatFromInt(i);
        try testing.expectApproxEqAbs(i_f / 3.0, panel.getStackedFracY(), 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), panel.getStackedFracH(), 1e-9);
    }
}

test "dropping a tab in a resized stacked column reseats rows by weight" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);
    group.in_stacked_mode = true;

    switch (group.panels.items[0]) {
        .terminal => |p| p.height_weight = 3.0,
        .webkit => unreachable,
    }
    const heavy = group.panels.items[0];
    group.tileStackedRows();

    // AdwTabView drag and `surface.reorder` both land in reorderPanel.
    group.reorderPanel(0, 2);

    try testing.expectEqual(heavy.getWidget(), group.panels.items[2].getWidget());
    try testing.expectApproxEqAbs(@as(f64, 3.0), group.panels.items[2].getHeightWeight(), 1e-9);

    // Weights 1 : 1 : 3 follow the new order, seated without waiting a tick.
    try testing.expectApproxEqAbs(@as(f64, 0.0), group.panels.items[0].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[0].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[1].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), group.panels.items[1].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 5.0), group.panels.items[2].getStackedFracY(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 5.0), group.panels.items[2].getStackedFracH(), 1e-9);
}

test "transfer into a resized stacked column tiles the whole column in one frame" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const target = try makeTestGroup(alloc, 2);
    const container = target.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = target;
    defer destroyTestGroup(target, container);
    target.in_stacked_mode = true;

    switch (target.panels.items[0]) {
        .terminal => |p| p.height_weight = 3.0,
        .webkit => unreachable,
    }
    target.tileStackedRows();

    // expelPane appends the transferred panel and, because it is visible at
    // once, re-tiles the whole target column instead of only its own slot.
    _ = try appendTestPanel(target, alloc);
    target.tileStackedRows();

    try testing.expectEqual(@as(usize, 3), target.panels.items.len);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 5.0), target.panels.items[0].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), target.panels.items[1].getStackedFracH(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), target.panels.items[2].getStackedFracH(), 1e-9);

    // Rows are contiguous: each starts where the previous one ends.
    var y: f64 = 0.0;
    for (target.panels.items) |panel| {
        try testing.expectApproxEqAbs(y, panel.getStackedFracY(), 1e-9);
        y += panel.getStackedFracH();
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0), y, 1e-9);
}

test "tab dialog context is released once by the dialog destroy notify" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 1);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);

    const dialog = c.adw_alert_dialog_new("Rename tab", null);
    _ = c.g_object_ref_sink(@ptrCast(dialog));
    ownDialog(alloc, @ptrCast(dialog), group.id, group.focusedTerminalPane().?.id, false, &onCtxRenameResponse, testResolver());

    // Cancel: the response must not touch the pane, and the destroy notify
    // still releases the context exactly once (testing.allocator checks both
    // a leak here and a double free below).
    c.g_signal_emit_by_name(@ptrCast(dialog), "response", @as([*c]const u8, "cancel"));
    c.g_object_unref(@ptrCast(dialog));

    const silent = c.adw_alert_dialog_new("Close other tabs", null);
    _ = c.g_object_ref_sink(@ptrCast(silent));
    ownDialog(alloc, @ptrCast(silent), group.id, group.focusedTerminalPane().?.id, false, &onCloseDialogResponse, testResolver());
    // Window teardown without any response: release must still happen.
    c.g_object_unref(@ptrCast(silent));
}

test "rename response renames the live pane and refuses a vanished target" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);

    const first = group.panels.items[0].asTerminal().?;
    const middle = group.panels.items[1].asTerminal().?;

    try testing.expect(applyRenameResponse(testResolver(), group.id, first.id, "Live"));
    try testing.expectEqualStrings("Live", first.getDisplayTitle().?);

    // Clearing restores whatever title the shell reported (possibly none).
    try testing.expect(applyRenameResponse(testResolver(), group.id, first.id, null));
    try testing.expect(!std.mem.eql(u8, first.getDisplayTitle() orelse "", "Live"));

    // The tab was closed while its dialog was open: cancellation, no crash.
    _ = group.removePanel(1);
    try testing.expect(!applyRenameResponse(testResolver(), group.id, middle.id, "Gone"));

    // The pane moved to another group: follow it there.
    const moved = group.panels.items[1].asTerminal().?;
    try testing.expect(applyRenameResponse(.{ .by_id = missingGroup, .by_pane = testGroupByPane }, group.id, moved.id, "Moved"));
    try testing.expectEqualStrings("Moved", moved.getDisplayTitle().?);

    // Everything is gone (group and window destroyed first).
    try testing.expect(!applyRenameResponse(.{ .by_id = missingGroup, .by_pane = missingGroup }, group.id, moved.id, "Late"));
    try testing.expect(!applyRenameResponse(liveGroupResolver(), group.id, moved.id, "Late"));
}

test "close response leaves surviving tabs alone when its target vanished" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    _ = c.g_object_ref_sink(@ptrCast(container));
    test_group = group;
    defer destroyTestGroup(group, container);

    const middle = group.panels.items[1].asTerminal().?;
    try testing.expectEqual(@as(c.gint, 3), c.adw_tab_view_get_n_pages(group.tab_view));

    // Remove the dialog's target, then deliver its response: no tab-view call
    // may run, so the two surviving tabs stay put.
    try testing.expect(!group.removePanel(1));
    try testing.expectEqual(@as(c.gint, 2), c.adw_tab_view_get_n_pages(group.tab_view));
    try testing.expect(!applyCloseResponse(testResolver(), group.id, middle.id, false));
    try testing.expectEqual(@as(c.gint, 2), c.adw_tab_view_get_n_pages(group.tab_view));
    try testing.expectEqual(@as(usize, 2), group.panels.items.len);

    // Destroyed group, live panel ID: cancellation.
    try testing.expect(!applyCloseResponse(.{ .by_id = missingGroup, .by_pane = missingGroup }, group.id, group.panels.items[0].getId(), false));

    // Live target: close pages after it and leave only that tab.
    try testing.expect(applyCloseResponse(testResolver(), group.id, group.panels.items[0].getId(), true));
    try testing.expectEqual(@as(c.gint, 1), c.adw_tab_view_get_n_pages(group.tab_view));
    try testing.expectEqual(@as(usize, 1), group.panels.items.len);
}

test "presented tab dialogs become harmless when their group is destroyed" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const window = c.gtk_window_new();
    _ = c.g_object_ref_sink(@ptrCast(window));
    defer c.g_object_unref(@ptrCast(window));

    const group = try makeTestGroup(alloc, 3);
    const container = group.getWidget();
    c.gtk_window_set_child(@ptrCast(window), container);

    // Both dialogs are owned by the presented window, exactly as in the app.
    const close_dialog = showCloseConfirmDialogWith(alloc, group, c.adw_tab_view_get_nth_page(group.tab_view, 0).?, false).?;
    const rename_dialog = showRenameDialog(alloc, group, group.panels.items[0].asTerminal().?).?;
    try testing.expect(close_dialog != rename_dialog);

    while (c.g_main_context_iteration(null, 0) != 0) {}

    // The group is torn down while both dialogs are outstanding.
    group.destroy();

    // Late responses must resolve nothing and leave the window untouched. The
    // context release still happens through each dialog's destroy notify, which
    // testing.allocator verifies (leak or double free would fail the test).
    c.g_signal_emit_by_name(@ptrCast(close_dialog), "response", @as([*c]const u8, "close"));
    c.g_signal_emit_by_name(@ptrCast(rename_dialog), "response", @as([*c]const u8, "rename"));
    _ = c.adw_dialog_close(@ptrCast(close_dialog));
    _ = c.adw_dialog_close(@ptrCast(rename_dialog));
    while (c.g_main_context_iteration(null, 0) != 0) {}

    c.gtk_window_set_child(@ptrCast(window), null);
    while (c.g_main_context_iteration(null, 0) != 0) {}
}
