const std = @import("std");
const c = @import("c.zig").c;

const WEBKIT_LOAD_STARTED: c_int = 0;
const WEBKIT_LOAD_COMMITTED: c_int = 2;
const WEBKIT_LOAD_FINISHED: c_int = 3;

fn nextId() u64 {
    return @import("panel_id.zig").next();
}

pub const CloseFn = *const fn (*anyopaque) callconv(.c) void;
pub const FocusFn = *const fn (*anyopaque, *WebPanel) callconv(.c) void;

pub const WebPanel = struct {
    id: u64,
    widget: *c.GtkWidget,
    toolbar: *c.GtkWidget,
    url_stack: *c.GtkWidget,
    entry: *c.GtkEntry,
    url_label: *c.GtkLabel,
    webview: *c.WebKitWebView,
    btn_reload: *c.GtkWidget,
    progress_bar: *c.GtkWidget,
    url: []u8,
    title: []u8,
    alloc: std.mem.Allocator,
    navigating_from_entry: bool = false,
    initial_load_done: bool = false,
    close_cb: ?CloseFn = null,
    close_data: ?*anyopaque = null,
    focus_cb: ?FocusFn = null,
    focus_data: ?*anyopaque = null,
    stacked_open_anim: f64 = 1.0,
    stacked_frac_y: f64 = 0.0,
    stacked_frac_h: f64 = 1.0,
    height_weight: f64 = 1.0,
    stacked_offset_x: f64 = 0.0,
    flash_step: u8 = 0,
    flash_timeout: c.guint = 0,
    initial_load_id: c.guint = 0,
    // Ownership tracking: weak pointers record finalization of the root
    // widget and of the webview (which WebKit may retain past unparent),
    // so signal disconnection never dereferences a dead emitter.
    widget_weak: ?*c.GtkWidget = null,
    webview_weak: ?*c.WebKitWebView = null,
    // Emitters (widgets, controllers, gestures) whose signals borrow this
    // panel. Disconnected only while the root widget is still alive; the
    // handlers of a finalized emitter died with it.
    borrowed: [16]?*anyopaque = [_]?*anyopaque{null} ** 16,
    borrowed_count: u8 = 0,
    // Outstanding TLS error dialog contexts; each response releases its
    // own context exactly once.
    tls_head: ?*TlsErrorCtx = null,

    pub fn create(alloc: std.mem.Allocator, url: []const u8) !*WebPanel {
        const id = nextId();

        const webview = @as(*c.WebKitWebView, @ptrCast(c.webkit_web_view_new() orelse return error.OutOfMemory));

        // Dev-friendly settings — enable full web API surface for AI web app development
        const settings = c.webkit_web_view_get_settings(webview);
        c.webkit_settings_set_enable_developer_extras(settings, 1);
        c.webkit_settings_set_enable_page_cache(settings, 0);
        c.webkit_settings_set_enable_html5_local_storage(settings, 1);
        c.webkit_settings_set_enable_html5_database(settings, 1);
        c.webkit_settings_set_enable_webgl(settings, 1);
        c.webkit_settings_set_enable_webaudio(settings, 1);
        c.webkit_settings_set_enable_webrtc(settings, 1);
        c.webkit_settings_set_enable_media_stream(settings, 1);
        c.webkit_settings_set_enable_mock_capture_devices(settings, 1);
        c.webkit_settings_set_enable_2d_canvas_acceleration(settings, 1);
        c.webkit_settings_set_enable_fullscreen(settings, 1);
        c.webkit_settings_set_allow_modal_dialogs(settings, 1);
        c.webkit_settings_set_javascript_can_open_windows_automatically(settings, 1);
        c.webkit_settings_set_javascript_can_access_clipboard(settings, 1);

        // Match terminal theme background for about:blank and similar pages
        const theme_bg = @import("theme.zig").resolveColors().window_bg;
        const bg_rgba: c.GdkRGBA = .{
            .red = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[1..3], 16) catch 0x0e)) / 255.0,
            .green = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[3..5], 16) catch 0x14)) / 255.0,
            .blue = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[5..7], 16) catch 0x19)) / 255.0,
            .alpha = 1.0,
        };
        c.webkit_web_view_set_background_color(webview, &bg_rgba);

        const webview_widget: *c.GtkWidget = @ptrCast(webview);
        c.gtk_widget_set_hexpand(webview_widget, 1);
        c.gtk_widget_set_vexpand(webview_widget, 1);

        // Root container: overlay wrapper (carries pane focus classes) >
        // box (toolbar + webview), with a dim layer for unfocused state.
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);

        const dim = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_can_target(dim, 0);
        c.gtk_widget_set_can_focus(dim, 0);
        c.gtk_widget_add_css_class(dim, "pane-dim");

        const wrapper = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(wrapper), box);
        c.gtk_overlay_add_overlay(@ptrCast(wrapper), dim);
        c.gtk_widget_add_css_class(@ptrCast(wrapper), "pane-unfocused");

        // Toolbar: [◀] [▶] [⟲/✕] [URL entry] [✕]
        const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        c.gtk_widget_add_css_class(toolbar, "browser-toolbar");
        c.gtk_widget_set_hexpand(toolbar, 1);
        c.gtk_widget_set_margin_start(toolbar, 2);
        c.gtk_widget_set_margin_end(toolbar, 2);
        c.gtk_widget_set_margin_top(toolbar, 2);
        c.gtk_widget_set_margin_bottom(toolbar, 2);

        const nav_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_add_css_class(nav_box, "linked");
        c.gtk_widget_add_css_class(nav_box, "browser-nav");
        c.gtk_box_append(@ptrCast(toolbar), nav_box);

        const btn_back = c.gtk_button_new_from_icon_name("go-previous-symbolic");
        c.gtk_widget_set_tooltip_text(btn_back, "Back");
        c.gtk_widget_add_css_class(btn_back, "flat");
        c.gtk_box_append(@ptrCast(nav_box), btn_back);

        const btn_forward = c.gtk_button_new_from_icon_name("go-next-symbolic");
        c.gtk_widget_set_tooltip_text(btn_forward, "Forward");
        c.gtk_widget_add_css_class(btn_forward, "flat");
        c.gtk_box_append(@ptrCast(nav_box), btn_forward);

        const btn_reload = c.gtk_button_new_from_icon_name("view-refresh-symbolic");
        c.gtk_widget_set_tooltip_text(btn_reload, "Reload");
        c.gtk_widget_add_css_class(btn_reload, "flat");
        c.gtk_widget_add_css_class(btn_reload, "circular");
        c.gtk_box_append(@ptrCast(toolbar), btn_reload);

        // URL display stack: label (styled display) + entry (editing)
        const url_stack = c.gtk_stack_new();
        c.gtk_widget_add_css_class(url_stack, "browser-url-stack");
        c.gtk_widget_set_hexpand(url_stack, 1);
        c.gtk_widget_set_valign(url_stack, c.GTK_ALIGN_CENTER);

        const url_label: *c.GtkWidget = c.gtk_label_new(null);
        c.gtk_label_set_ellipsize(@ptrCast(url_label), c.PANGO_ELLIPSIZE_START);
        c.gtk_label_set_xalign(@ptrCast(url_label), 0);
        c.gtk_widget_add_css_class(url_label, "url-display");
        c.gtk_widget_add_css_class(url_label, "browser-url-display");
        _ = c.gtk_stack_add_named(@ptrCast(url_stack), url_label, "display");

        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(@ptrCast(entry), 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Enter URL…");
        _ = c.gtk_stack_add_named(@ptrCast(url_stack), @ptrCast(entry), "edit");

        c.gtk_stack_set_visible_child_name(@ptrCast(url_stack), "display");
        c.gtk_box_append(@ptrCast(toolbar), url_stack);

        // Hamburger menu: [☰] → Developer Tools
        const menu_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        const btn_devtools = c.gtk_button_new();
        c.gtk_widget_set_halign(btn_devtools, c.GTK_ALIGN_START);
        const devtools_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        _ = c.gtk_box_append(@ptrCast(devtools_box), c.gtk_image_new_from_icon_name("system-run-symbolic"));
        _ = c.gtk_box_append(@ptrCast(devtools_box), c.gtk_label_new("Developer tools"));
        c.gtk_button_set_child(@ptrCast(btn_devtools), devtools_box);
        c.gtk_widget_set_tooltip_text(btn_devtools, "Open WebKit Inspector (Ctrl+Shift+I)");
        _ = c.gtk_box_append(@ptrCast(menu_box), btn_devtools);

        const popover = c.gtk_popover_new();
        c.gtk_popover_set_child(@ptrCast(popover), menu_box);

        const btn_menu = c.gtk_menu_button_new();
        c.gtk_menu_button_set_icon_name(@ptrCast(btn_menu), "open-menu-symbolic");
        c.gtk_widget_set_tooltip_text(btn_menu, "Browser menu");
        c.gtk_widget_add_css_class(btn_menu, "flat");
        c.gtk_widget_add_css_class(btn_menu, "circular");
        c.gtk_menu_button_set_popover(@ptrCast(btn_menu), popover);
        c.gtk_box_append(@ptrCast(toolbar), btn_menu);

        const btn_close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_widget_set_tooltip_text(btn_close, "Close browser pane");
        c.gtk_widget_add_css_class(btn_close, "flat");
        c.gtk_widget_add_css_class(btn_close, "circular");
        c.gtk_box_append(@ptrCast(toolbar), btn_close);

        c.gtk_box_append(@ptrCast(box), toolbar);

        // Progress bar (thin line under toolbar, hidden by default)
        const progress_bar = c.gtk_progress_bar_new();
        c.gtk_widget_add_css_class(progress_bar, "browser-progress");
        c.gtk_widget_set_hexpand(progress_bar, 1);
        c.gtk_widget_set_size_request(progress_bar, -1, 3);
        c.gtk_widget_set_visible(progress_bar, 0);
        c.gtk_box_append(@ptrCast(box), progress_bar);

        // Webview
        c.gtk_box_append(@ptrCast(box), webview_widget);

        const owned_url = try alloc.dupe(u8, url);
        errdefer alloc.free(owned_url);

        // gtk_editable_set_text reads a C string. The incoming slice can be a
        // parsed JSON string with no terminator, so the entry is populated
        // from an owned copy whose sentinel is guaranteed.
        const terminated_url = try alloc.dupeZ(u8, url);
        defer alloc.free(terminated_url);

        const panel = try alloc.create(WebPanel);
        panel.* = .{
            .id = id,
            .widget = @ptrCast(wrapper),
            .toolbar = toolbar,
            .url_stack = url_stack,
            .entry = @ptrCast(entry),
            .url_label = @ptrCast(url_label),
            .webview = webview,
            .btn_reload = btn_reload,
            .progress_bar = progress_bar,
            .url = owned_url,
            .title = "",
            .alloc = alloc,
        };

        // Weak pointers: disconnectSignals must be callable after any part
        // of the widget tree (or the WebKit-held webview) finalized. Seed
        // the live slots before registering so tracking never depends on
        // the order GObject initializes them; it clears each one at
        // finalization.
        panel.widget_weak = @ptrCast(wrapper);
        panel.webview_weak = webview;
        c.g_object_add_weak_pointer(
            @as(*c.GObject, @ptrCast(panel.widget)),
            @ptrCast(&panel.widget_weak),
        );
        c.g_object_add_weak_pointer(
            @as(*c.GObject, @ptrCast(webview)),
            @ptrCast(&panel.webview_weak),
        );

        // Navigate on Enter in address bar
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry)),
            "activate",
            @as(c.GCallback, @ptrCast(&onEntryActivate)),
            @ptrCast(panel),
            null,
            0,
        );

        // Track load state + sync entry text
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(webview)),
            "load-changed",
            @as(c.GCallback, @ptrCast(&onLoadChanged)),
            @ptrCast(panel),
            null,
            0,
        );

        // Update progress bar from WebKit's estimated-load-progress
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(webview)),
            "notify::estimated-load-progress",
            @as(c.GCallback, @ptrCast(&onProgressChanged)),
            @ptrCast(panel),
            null,
            0,
        );

        // TLS certificate errors — show dialog to let user proceed
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(webview)),
            "load-failed-with-tls-errors",
            @as(c.GCallback, @ptrCast(&onTlsError)),
            @ptrCast(panel),
            null,
            0,
        );

        // Focus callback: when any part of the browser panel gains focus,
        // notify workspace to unfocus terminal panes.
        // Use GtkEventControllerFocus (the GTK4-idiomatic approach, same as
        // terminal panes in pane.zig) instead of notify::has-focus which is
        // unreliable in GTK4's focus group model.
        const entry_focus_ctrl = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry_focus_ctrl)),
            "enter",
            @as(c.GCallback, @ptrCast(&onPanelFocusIn)),
            @ptrCast(panel),
            null,
            0,
        );
        c.gtk_widget_add_controller(@ptrCast(entry), @ptrCast(entry_focus_ctrl));

        const webview_focus_ctrl = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(webview_focus_ctrl)),
            "enter",
            @as(c.GCallback, @ptrCast(&onPanelFocusIn)),
            @ptrCast(panel),
            null,
            0,
        );
        c.gtk_widget_add_controller(webview_widget, @ptrCast(webview_focus_ctrl));

        // Label click → switch to edit mode
        const label_click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(label_click), 0);
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(label_click)),
            "pressed",
            @as(c.GCallback, @ptrCast(&onLabelPressed)),
            @ptrCast(panel),
            null,
            0,
        );
        c.gtk_widget_add_controller(url_label, @ptrCast(label_click));

        // Entry focus lost → switch back to display mode
        const entry_focus_leave = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry_focus_leave)),
            "leave",
            @as(c.GCallback, @ptrCast(&onEntryFocusLeave)),
            @ptrCast(panel),
            null,
            0,
        );
        c.gtk_widget_add_controller(@ptrCast(entry), @ptrCast(entry_focus_leave));

        // Back button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(btn_back)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onBackClicked)),
            @ptrCast(panel),
            null,
            0,
        );

        // Forward button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(btn_forward)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onForwardClicked)),
            @ptrCast(panel),
            null,
            0,
        );

        // Reload / Stop button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(btn_reload)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onReloadStopClicked)),
            @ptrCast(panel),
            null,
            0,
        );

        // Developer Tools button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(btn_devtools)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onDevToolsClicked)),
            @ptrCast(panel),
            null,
            0,
        );

        // Close button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(btn_close)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onCloseClicked)),
            @ptrCast(panel),
            null,
            0,
        );

        // Load URL when widget is first mapped (visible in GTK hierarchy).
        // Calling load_uri before map is unreliable — WebKit may defer it.
        if (isAllowedUrl(url)) {
            _ = c.g_signal_connect_data(
                @as(c.gpointer, @ptrCast(box)),
                "map",
                @as(c.GCallback, @ptrCast(&onMap)),
                @ptrCast(panel),
                null,
                0,
            );
            c.gtk_editable_set_text(@ptrCast(entry), terminated_url.ptr);
            panel.syncDisplay();
        }

        // Record every emitter whose handlers borrow this panel so
        // disconnectSignals can detach them while the tree is alive.
        panel.rememberBorrowed(entry);
        panel.rememberBorrowed(entry_focus_ctrl);
        panel.rememberBorrowed(webview_focus_ctrl);
        panel.rememberBorrowed(label_click);
        panel.rememberBorrowed(entry_focus_leave);
        panel.rememberBorrowed(btn_back);
        panel.rememberBorrowed(btn_forward);
        panel.rememberBorrowed(btn_reload);
        panel.rememberBorrowed(btn_devtools);
        panel.rememberBorrowed(btn_close);
        panel.rememberBorrowed(box);

        return panel;
    }

    fn rememberBorrowed(self: *WebPanel, emitter: anytype) void {
        if (self.borrowed_count >= self.borrowed.len) return;
        self.borrowed[self.borrowed_count] = @ptrCast(emitter);
        self.borrowed_count += 1;
    }

    pub fn setCloseCallback(self: *WebPanel, cb: CloseFn, data: *anyopaque) void {
        self.close_cb = cb;
        self.close_data = data;
    }

    pub fn setFocusCallback(self: *WebPanel, cb: FocusFn, data: *anyopaque) void {
        self.focus_cb = cb;
        self.focus_data = data;
    }

    pub fn getWidget(self: *WebPanel) *c.GtkWidget {
        return self.widget;
    }

    pub fn getId(self: *WebPanel) u64 {
        return self.id;
    }

    pub fn focus(self: *WebPanel) void {
        c.gtk_widget_remove_css_class(self.widget, "pane-unfocused");
        c.gtk_widget_add_css_class(self.widget, "pane-focused");
        const uri = c.webkit_web_view_get_uri(self.webview);
        if (uri) |u| {
            c.gtk_editable_set_text(@ptrCast(self.entry), u);
        }
        c.gtk_stack_set_visible_child_name(@ptrCast(self.url_stack), "edit");
        _ = c.gtk_widget_grab_focus(@ptrCast(self.entry));
    }

    pub fn unfocus(self: *WebPanel) void {
        c.gtk_widget_remove_css_class(self.widget, "pane-focused");
        c.gtk_widget_add_css_class(self.widget, "pane-unfocused");
    }

    pub fn updateBackgroundColor(self: *WebPanel) void {
        const theme_bg = @import("theme.zig").resolveColors().window_bg;
        const bg_rgba: c.GdkRGBA = .{
            .red = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[1..3], 16) catch 0x0e)) / 255.0,
            .green = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[3..5], 16) catch 0x14)) / 255.0,
            .blue = @as(f32, @floatFromInt(std.fmt.parseInt(u8, theme_bg[5..7], 16) catch 0x19)) / 255.0,
            .alpha = 1.0,
        };
        c.webkit_web_view_set_background_color(self.webview, &bg_rgba);
    }

    /// Detach every borrowed-self handler and cancel owned sources. Safe
    /// to call multiple times and safe when widgets already finalized:
    /// weak pointers record which emitters can still be reached, and
    /// handlers on a finalized emitter died with it.
    pub fn disconnectSignals(self: *WebPanel) void {
        // Sources are context-level: removable regardless of widget state.
        cancelIdle(&self.initial_load_id);
        cancelIdle(&self.flash_timeout);

        // Outstanding TLS dialogs keep their context (the response frees
        // it exactly once) but lose their panel reference, so a late
        // response becomes a harmless cancellation.
        invalidateTlsContexts(self);

        if (self.webview_weak) |wv| {
            disconnectByData(wv, self);
            c.g_object_remove_weak_pointer(
                @as(*c.GObject, @ptrCast(wv)),
                @ptrCast(&self.webview_weak),
            );
            self.webview_weak = null;
        }
        if (self.widget_weak) |root| {
            // Root alive ⇒ the recorded widget/controller subtree is
            // intact (it is only ever destroyed together with the root).
            for (self.borrowed[0..self.borrowed_count]) |emitter| {
                if (emitter) |e| disconnectByData(e, self);
            }
            c.g_object_remove_weak_pointer(
                @as(*c.GObject, @ptrCast(root)),
                @ptrCast(&self.widget_weak),
            );
            self.widget_weak = null;
        }
    }

    pub fn destroy(self: *WebPanel) void {
        self.disconnectSignals();
        self.alloc.free(self.url);
        if (self.title.len > 0) self.alloc.free(self.title);
        self.alloc.destroy(self);
    }

    pub fn triggerFlash(self: *WebPanel) void {
        if (self.flash_timeout != 0) {
            _ = c.g_source_remove(self.flash_timeout);
            self.flash_timeout = 0;
        }
        c.gtk_widget_remove_css_class(self.widget, "pane-flash");
        // Reduced motion: single static highlight instead of a pulse.
        if (!@import("a11y.zig").animationsEnabled()) {
            c.gtk_widget_add_css_class(self.widget, "pane-flash");
            self.flash_timeout = c.g_timeout_add(400, @ptrCast(&onFlashClear), @ptrCast(self));
            return;
        }
        self.flash_step = 0;
        advanceFlash(self);
    }

    /// Apply the focused visual state (CSS class + opacity) without grabbing
    /// focus or switching the URL stack. Used when the entry or webview gains
    /// focus so the panel stops rendering as unfocused.
    pub fn focusVisuals(self: *WebPanel) void {
        c.gtk_widget_remove_css_class(self.widget, "pane-unfocused");
        c.gtk_widget_add_css_class(self.widget, "pane-focused");
    }

    pub fn queueResize(self: *WebPanel) void {
        c.gtk_widget_queue_resize(@ptrCast(self.webview));
    }

    pub fn showInspector(self: *WebPanel) void {
        const inspector = c.webkit_web_view_get_inspector(self.webview);
        c.webkit_web_inspector_show(inspector);
    }

    pub fn navigate(self: *WebPanel, url: []const u8) void {
        if (!isAllowedUrl(url)) return;
        self.setTlsPolicy(c.WEBKIT_TLS_ERRORS_POLICY_FAIL);
        const new_url = self.alloc.dupe(u8, url) catch return;
        self.alloc.free(self.url);
        self.url = new_url;
        self.loadUrl(url);
        var url_buf: [4096:0]u8 = .{0} ** 4096;
        const len = @min(url.len, 4095);
        @memcpy(url_buf[0..len], url[0..len]);
        url_buf[len] = 0;
        c.gtk_editable_set_text(@ptrCast(self.entry), &url_buf);
        self.syncDisplay();
    }

    pub fn reload(self: *WebPanel) void {
        self.setTlsPolicy(c.WEBKIT_TLS_ERRORS_POLICY_FAIL);
        c.webkit_web_view_reload(self.webview);
    }

    pub fn stop(self: *WebPanel) void {
        c.webkit_web_view_stop_loading(self.webview);
    }

    pub fn back(self: *WebPanel) void {
        self.setTlsPolicy(c.WEBKIT_TLS_ERRORS_POLICY_FAIL);
        c.webkit_web_view_go_back(self.webview);
    }

    pub fn forward(self: *WebPanel) void {
        self.setTlsPolicy(c.WEBKIT_TLS_ERRORS_POLICY_FAIL);
        c.webkit_web_view_go_forward(self.webview);
    }

    /// Copy `url` into a null-terminated stack buffer and start loading it.
    /// Single home for the buffer/clamp logic that navigate, onDeferredLoad,
    /// and onTlsErrorResponse all used to duplicate.
    fn loadUrl(self: *WebPanel, url: []const u8) void {
        var url_buf: [4096:0]u8 = .{0} ** 4096;
        const len = @min(url.len, 4095);
        @memcpy(url_buf[0..len], url[0..len]);
        url_buf[len] = 0;
        c.webkit_web_view_load_uri(self.webview, &url_buf);
    }

    /// Set the session-wide TLS errors policy. Both the "proceed anyway" flow
    /// and the LOAD_FINISHED reset route through here so the policy value and
    /// session-retrieval logic live in one place.
    fn setTlsPolicy(self: *WebPanel, policy: c.WebKitTLSErrorsPolicy) void {
        const session = c.webkit_web_view_get_network_session(self.webview);
        c.webkit_network_session_set_tls_errors_policy(session, policy);
    }

    pub fn getTitle(self: *WebPanel) []const u8 {
        if (c.webkit_web_view_get_title(self.webview)) |title_ptr| {
            const new_title = std.mem.sliceTo(title_ptr, 0);
            if (new_title.len > 0 and !std.mem.eql(u8, self.title, new_title)) {
                if (self.title.len > 0) self.alloc.free(self.title);
                self.title = self.alloc.dupe(u8, new_title) catch "";
            }
        }
        if (self.title.len > 0) return self.title;
        return getHostFromUrl(self.url);
    }

    fn setLoading(self: *WebPanel, loading: bool) void {
        if (loading) {
            c.gtk_widget_set_visible(self.progress_bar, 1);
            c.gtk_button_set_icon_name(@ptrCast(self.btn_reload), "process-stop-symbolic");
            c.gtk_widget_set_tooltip_text(self.btn_reload, "Stop");
        } else {
            c.gtk_widget_set_visible(self.progress_bar, 0);
            c.gtk_progress_bar_set_fraction(@ptrCast(self.progress_bar), 0);
            c.gtk_button_set_icon_name(@ptrCast(self.btn_reload), "view-refresh-symbolic");
            c.gtk_widget_set_tooltip_text(self.btn_reload, "Reload");
        }
    }

    fn syncDisplay(self: *WebPanel) void {
        // Use self.url (heap-owned, always in sync) instead of reading from
        // gtk_editable_get_text whose internal buffer can expose stale bytes
        // past the null terminator, causing Pango UTF-8 parse errors.
        const url: []const u8 = self.url;
        var markup_buf: [2048:0]u8 = .{0} ** 2048;
        const markup = buildUrlMarkup(url, &markup_buf);
        c.gtk_label_set_markup(self.url_label, markup.ptr);
    }
};

/// URL scheme validation — only allow http/https and about:blank.
/// This is an in-app dev browser, so localhost/private addresses are allowed.
pub fn isAllowedUrl(url: []const u8) bool {
    if (url.len == 0) return false;

    // Allow about:blank for initial/default load
    if (std.mem.eql(u8, url, "about:blank")) return true;

    // Reject file:// and data: URIs
    if (std.mem.startsWith(u8, url, "file:")) return false;
    if (std.mem.startsWith(u8, url, "data:")) return false;
    if (std.mem.startsWith(u8, url, "javascript:")) return false;
    if (std.mem.startsWith(u8, url, "blob:")) return false;

    // Must be http or https
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "http://")) return true;
    return false;
}

fn getHostFromUrl(url: []const u8) []const u8 {
    var rest = url;
    // Skip scheme
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        rest = rest[colon + 1 ..];
    }
    // Skip user info
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        rest = rest[at + 1 ..];
    }
    // Host is until next /, :, or end
    const end = for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == ':' or ch == '?') break i;
    } else rest.len;
    return rest[0..end];
}

fn onMap(widget_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (panel.initial_load_done) return;
    panel.initial_load_done = true;
    const w = widget_ orelse return;
    _ = w;
    if (!isAllowedUrl(panel.url)) return;
    // Defer load_uri to idle so GTK layout sets the webview size first.
    // Idle callbacks run after frame clock ticks (lower priority),
    // so applyLayout will have set proper dimensions before we load.
    // The ID is tracked so teardown can cancel a pending first load.
    if (panel.initial_load_id == 0) {
        panel.initial_load_id = c.g_idle_add(@ptrCast(&onDeferredLoad), @ptrCast(panel));
    }
}

fn onDeferredLoad(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return 0));
    // Clear the tracked ID before touching any other panel state so a
    // later cancel never removes an already-dispatched source.
    panel.initial_load_id = 0;
    if (!isAllowedUrl(panel.url)) return 0;
    panel.loadUrl(panel.url);
    return 0; // remove from idle source
}

/// Remove a tracked GLib source by ID. Idempotent: callbacks clear their
/// ID before dispatch, so a source that already ran is never removed a
/// second time (which would raise a GLib critical).
fn cancelIdle(id: *c.guint) void {
    if (id.* == 0) return;
    _ = c.g_source_remove(id.*);
    id.* = 0;
}

/// Disconnect every handler on `emitter` whose user data is `panel`.
fn disconnectByData(emitter: *anyopaque, panel: *WebPanel) void {
    _ = c.g_signal_handlers_disconnect_matched(
        emitter,
        c.G_SIGNAL_MATCH_DATA,
        0,
        0,
        null,
        null,
        @as(c.gpointer, @ptrCast(panel)),
    );
}

/// Panel teardown: every outstanding TLS context keeps its allocations
/// (the dialog response frees them) but loses its panel reference.
fn invalidateTlsContexts(panel: *WebPanel) void {
    var it = panel.tls_head;
    while (it) |ctx| : (it = ctx.next) ctx.panel = null;
}

/// Remove `ctx` from its panel's outstanding list, if still linked.
fn unlinkTlsCtx(panel: *WebPanel, ctx: *TlsErrorCtx) void {
    if (panel.tls_head == ctx) {
        panel.tls_head = ctx.next;
        return;
    }
    var it = panel.tls_head;
    while (it) |cur| : (it = cur.next) {
        if (cur.next == ctx) {
            cur.next = ctx.next;
            return;
        }
    }
}

/// Free a TLS context's owned data exactly once (callers use `defer`).
fn releaseTlsCtx(ctx: *TlsErrorCtx) void {
    ctx.alloc.free(ctx.failing_uri);
    ctx.alloc.free(ctx.host);
    if (ctx.certificate) |cert| _ = c.g_object_unref(@ptrCast(cert));
    ctx.alloc.destroy(ctx);
}

fn onEntryActivate(entry_: ?*c.GtkEditable, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    const editable = entry_ orelse return;
    const text = c.gtk_editable_get_text(editable);
    if (text == null) return;
    const url = std.mem.span(text.?);
    if (url.len == 0) return;
    // Auto-prepend https:// for bare domains
    const needs_scheme = !std.mem.containsAtLeast(u8, url, 1, "://") and
        !std.mem.startsWith(u8, url, "about:");
    if (needs_scheme) {
        var full_buf: [4096:0]u8 = .{0} ** 4096;
        const prefix = "https://";
        const copy_len = @min(url.len, 4096 - prefix.len - 1);
        @memcpy(full_buf[0..prefix.len], prefix);
        @memcpy(full_buf[prefix.len .. prefix.len + copy_len], url[0..copy_len]);
        full_buf[prefix.len + copy_len] = 0;
        panel.navigating_from_entry = true;
        panel.navigate(full_buf[0 .. prefix.len + copy_len]);
        return;
    }
    panel.navigating_from_entry = true;
    panel.navigate(url);
}

fn onLoadChanged(_: ?*c.WebKitWebView, event: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));

    switch (event) {
        WEBKIT_LOAD_STARTED => {
            panel.setLoading(true);
        },
        WEBKIT_LOAD_COMMITTED => {
            const uri = c.webkit_web_view_get_uri(panel.webview);
            if (uri) |u| {
                const new_url = std.mem.sliceTo(u, 0);
                if (!std.mem.eql(u8, panel.url, new_url)) {
                    const owned = panel.alloc.dupe(u8, new_url) catch return;
                    panel.alloc.free(panel.url);
                    panel.url = owned;
                }
                if (!panel.navigating_from_entry) {
                    c.gtk_editable_set_text(@ptrCast(panel.entry), u);
                    panel.syncDisplay();
                }
            }
        },
        WEBKIT_LOAD_FINISHED => {
            panel.setLoading(false);
            panel.navigating_from_entry = false;
        },
        else => {},
    }
}

fn onProgressChanged(_: ?*c.GObject, _: ?*c.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    const fraction = c.webkit_web_view_get_estimated_load_progress(panel.webview);
    c.gtk_progress_bar_set_fraction(@ptrCast(panel.progress_bar), fraction);
}

fn advanceFlash(panel: *WebPanel) void {
    const flash_on = [_]bool{ false, true, false, true, false };
    if (panel.flash_step >= flash_on.len) return;
    if (flash_on[panel.flash_step]) {
        c.gtk_widget_add_css_class(panel.widget, "pane-flash");
    } else {
        c.gtk_widget_remove_css_class(panel.widget, "pane-flash");
    }
    panel.flash_step += 1;
    if (panel.flash_step < flash_on.len) {
        panel.flash_timeout = c.g_timeout_add(225, @ptrCast(&onFlashStep), @ptrCast(panel));
    } else {
        panel.flash_timeout = 0;
    }
}

fn onFlashStep(data: c.gpointer) callconv(.c) c.gboolean {
    const panel: *WebPanel = @ptrCast(@alignCast(data));
    advanceFlash(panel);
    return 0;
}

fn onFlashClear(data: c.gpointer) callconv(.c) c.gboolean {
    const panel: *WebPanel = @ptrCast(@alignCast(data));
    panel.flash_timeout = 0;
    c.gtk_widget_remove_css_class(panel.widget, "pane-flash");
    return 0;
}

fn onTlsError(
    webview_: ?*c.WebKitWebView,
    failing_uri: ?[*:0]const u8,
    certificate: ?*c.GTlsCertificate,
    errors: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) c.gboolean {
    _ = webview_;
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return 0));
    const uri = failing_uri orelse return 0;
    const cert = certificate orelse return 0;

    const uri_str = std.mem.sliceTo(uri, 0);

    // Canonical host via GLib's URI parser (not string splitting).
    var host_owned: []u8 = &[_]u8{};
    const guri = c.g_uri_parse(uri_str.ptr, c.G_URI_FLAGS_NONE, null);
    const host_slice: []const u8 = if (guri) |u| blk: {
        const h = c.g_uri_get_host(u);
        if (h) |hp| break :blk std.mem.sliceTo(hp, 0) else break :blk getHostFromUrl(uri_str);
    } else getHostFromUrl(uri_str);
    host_owned = panel.alloc.dupe(u8, host_slice) catch {
        if (guri) |u| c.g_uri_unref(u);
        return 0;
    };
    if (guri) |u| c.g_uri_unref(u);

    const retained_cert = c.g_object_ref(@ptrCast(cert));

    const ctx = panel.alloc.create(TlsErrorCtx) catch {
        _ = c.g_object_unref(retained_cert);
        panel.alloc.free(host_owned);
        return 0;
    };
    ctx.* = .{
        .panel = panel,
        .alloc = panel.alloc,
        .failing_uri = panel.alloc.dupe(u8, uri_str) catch {
            panel.alloc.free(host_owned);
            _ = c.g_object_unref(retained_cert);
            panel.alloc.destroy(ctx);
            return 0;
        },
        .certificate = @ptrCast(@alignCast(retained_cert)),
        .host = host_owned,
        .next = null,
    };
    host_owned = &[_]u8{};

    // Test seam: auto-approve when SEANCE_AUTO_PROCEED_TLS is set.
    if (std.c.getenv("SEANCE_AUTO_PROCEED_TLS") != null) {
        if (ctx.certificate) |crt| {
            const session = c.webkit_web_view_get_network_session(panel.webview);
            const host_z = panel.alloc.dupeZ(u8, ctx.host) catch {
                releaseTlsCtx(ctx);
                return 0;
            };
            defer panel.alloc.free(host_z);
            c.webkit_network_session_allow_tls_certificate_for_host(session, crt, host_z);
        }
        panel.loadUrl(ctx.failing_uri);
        releaseTlsCtx(ctx);
        return 1;
    }

    ctx.next = panel.tls_head;
    panel.tls_head = ctx;

    var msg_buf: [512:0]u8 = [_:0]u8{0} ** 512;
    _ = std.fmt.bufPrint(&msg_buf, "The certificate for <b>{s}</b> is not trusted.\n\n{s}", .{ ctx.host, formatTlsErrorFlags(errors) }) catch {};

    const dialog = c.adw_alert_dialog_new("Insecure connection", &msg_buf);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "proceed", "Proceed anyway");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "proceed", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onTlsErrorResponse)), @ptrCast(ctx), null, 0);
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), panel.widget);

    // Test instrumentation: the GUI harness waits for this line before typing
    // at the dialog, so it never guesses when the dialog became interactive.
    if (std.c.getenv("SEANCE_TLS_DIALOG_LOG") != null) {
        std.log.info("tls dialog presented for host {s}", .{ctx.host});
    }

    return 1; // handled
}

const TlsErrorCtx = struct {
    /// Null once the owning panel was invalidated; the response then only
    /// releases this context. The context owns its allocations so the
    /// release never depends on the panel.
    panel: ?*WebPanel,
    failing_uri: []u8,
    certificate: ?*c.GTlsCertificate,
    host: []u8,
    alloc: std.mem.Allocator,
    next: ?*TlsErrorCtx = null,
};

fn onTlsErrorResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *TlsErrorCtx = @ptrCast(@alignCast(data));
    defer releaseTlsCtx(ctx);

    // Test instrumentation, paired with the presentation line above.
    if (std.c.getenv("SEANCE_TLS_DIALOG_LOG") != null) {
        std.log.info("tls dialog response {s}", .{std.mem.sliceTo(response, 0)});
    }

    const panel = ctx.panel orelse return; // panel gone: harmless cancellation
    unlinkTlsCtx(panel, ctx);

    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "proceed")) return;

    // Approve only the retained certificate for the failing host.
    if (ctx.certificate) |cert| {
        const session = c.webkit_web_view_get_network_session(panel.webview);
        const host_z = panel.alloc.dupeZ(u8, ctx.host) catch return;
        defer panel.alloc.free(host_z);
        c.webkit_network_session_allow_tls_certificate_for_host(session, cert, host_z);
    }

    panel.loadUrl(ctx.failing_uri);
}

fn formatTlsErrorFlags(errors: c_uint) []const u8 {
    if (errors == 0) return "Unknown error";
    var result: []const u8 = "";
    if (errors & (1 << 0) != 0) result = "Unknown Certificate Authority";
    if (errors & (1 << 1) != 0) result = "Hostname mismatch";
    if (errors & (1 << 2) != 0) result = "Certificate not yet valid";
    if (errors & (1 << 3) != 0) result = "Certificate has expired";
    if (errors & (1 << 4) != 0) result = "Certificate has been revoked";
    if (errors & (1 << 5) != 0) result = "Insecure algorithm or key";
    if (errors & (1 << 6) != 0) result = "Generic validation error";
    return result;
}

fn onPanelFocusIn(_: ?*c.GtkEventControllerFocus, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (panel.focus_cb) |cb| {
        if (panel.focus_data) |data| {
            cb(data, panel);
        }
    }
}

fn onBackClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    panel.back();
}

fn onForwardClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    panel.forward();
}

fn onReloadStopClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (c.webkit_web_view_is_loading(panel.webview) != 0) {
        panel.stop();
    } else {
        panel.reload();
    }
}

fn onDevToolsClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    panel.showInspector();
}

fn onCloseClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (panel.close_cb) |cb| {
        if (panel.close_data) |data| {
            cb(data);
        }
    }
}

fn onLabelPressed(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    c.gtk_stack_set_visible_child_name(@ptrCast(panel.url_stack), "edit");
    _ = c.gtk_widget_grab_focus(@ptrCast(panel.entry));
}

fn onEntryFocusLeave(_: ?*c.GtkEventControllerFocus, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    panel.syncDisplay();
    c.gtk_stack_set_visible_child_name(@ptrCast(panel.url_stack), "display");
}

/// Build Pango markup for URL display: domain in normal color,
/// scheme and path/port in muted color (alpha 50%).
fn buildUrlMarkup(url: []const u8, buf: *[2048:0]u8) [:0]const u8 {
    if (url.len == 0) {
        buf[0] = 0;
        return buf[0..0 :0];
    }

    const muted_open = "<span alpha=\"50%\">";
    const muted_close = "</span>";

    // Find scheme end (after "://")
    var scheme_end: usize = 0;
    var domain_start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |idx| {
        scheme_end = idx + 3;
        domain_start = scheme_end;
    } else if (std.mem.startsWith(u8, url, "about:")) {
        // about:blank — plain text, no styling
        const copy_len = @min(url.len, 2047);
        @memcpy(buf[0..copy_len], url[0..copy_len]);
        buf[copy_len] = 0;
        return buf[0..copy_len :0];
    } else {
        domain_start = 0;
    }

    // Find domain end (first /, :, ?, # after domain_start)
    var domain_end: usize = url.len;
    for (url[domain_start..], 0..) |ch, i| {
        if (ch == '/' or ch == ':' or ch == '?' or ch == '#') {
            domain_end = domain_start + i;
            break;
        }
    }

    var pos: usize = 0;

    // Muted scheme
    if (scheme_end > 0) {
        pos = appendStr(buf, pos, muted_open);
        pos = appendEscapedRange(buf, pos, url[0..scheme_end]);
        pos = appendStr(buf, pos, muted_close);
    }

    // Domain (normal color — no span)
    pos = appendEscapedRange(buf, pos, url[domain_start..domain_end]);

    // Muted port + path
    if (domain_end < url.len) {
        pos = appendStr(buf, pos, muted_open);
        pos = appendEscapedRange(buf, pos, url[domain_end..]);
        pos = appendStr(buf, pos, muted_close);
    }

    buf[pos] = 0;
    return buf[0..pos :0];
}

fn appendStr(buf: *[2048:0]u8, pos: usize, s: []const u8) usize {
    const space = buf.len - 1 - pos;
    const n = @min(s.len, space);
    @memcpy(buf[pos..][0..n], s[0..n]);
    return pos + n;
}

fn appendEscapedRange(buf: *[2048:0]u8, pos: usize, range: []const u8) usize {
    var p = pos;
    for (range) |ch| {
        if (p + 8 >= buf.len) break;
        switch (ch) {
            '<' => {
                @memcpy(buf[p..][0..4], "&lt;");
                p += 4;
            },
            '>' => {
                @memcpy(buf[p..][0..4], "&gt;");
                p += 4;
            },
            '&' => {
                @memcpy(buf[p..][0..5], "&amp;");
                p += 5;
            },
            '"' => {
                @memcpy(buf[p..][0..6], "&quot;");
                p += 6;
            },
            '\'' => {
                @memcpy(buf[p..][0..6], "&apos;");
                p += 6;
            },
            else => {
                buf[p] = ch;
                p += 1;
            },
        }
    }
    return p;
}

test "isAllowedUrl: https accepted" {
    try std.testing.expect(isAllowedUrl("https://example.com"));
}

test "isAllowedUrl: http accepted" {
    try std.testing.expect(isAllowedUrl("http://example.com"));
}

test "isAllowedUrl: about:blank accepted" {
    try std.testing.expect(isAllowedUrl("about:blank"));
}

test "isAllowedUrl: file rejected" {
    try std.testing.expect(!isAllowedUrl("file:///etc/passwd"));
}

test "isAllowedUrl: data rejected" {
    try std.testing.expect(!isAllowedUrl("data:text/html,<h1>hi</h1>"));
}

test "isAllowedUrl: localhost accepted" {
    try std.testing.expect(isAllowedUrl("http://localhost:3000"));
}

test "isAllowedUrl: loopback accepted" {
    try std.testing.expect(isAllowedUrl("http://127.0.0.1/secret"));
}

test "isAllowedUrl: link-local accepted" {
    try std.testing.expect(isAllowedUrl("http://169.254.169.254/metadata"));
}

test "isAllowedUrl: RFC1918 10.x accepted" {
    try std.testing.expect(isAllowedUrl("http://10.0.0.1/secret"));
}

test "isAllowedUrl: RFC1918 192.168.x accepted" {
    try std.testing.expect(isAllowedUrl("http://192.168.1.1/secret"));
}

test "isAllowedUrl: RFC1918 172.16.x accepted" {
    try std.testing.expect(isAllowedUrl("http://172.16.0.1/secret"));
}

test "isAllowedUrl: RFC1918 172.31.x accepted" {
    try std.testing.expect(isAllowedUrl("http://172.31.255.255/secret"));
}

test "isAllowedUrl: javascript rejected" {
    try std.testing.expect(!isAllowedUrl("javascript:alert(1)"));
}

test "isAllowedUrl: empty rejected" {
    try std.testing.expect(!isAllowedUrl(""));
}

test "buildUrlMarkup: https with path" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("https://www.example.com/path/to/page", &buf);
    try std.testing.expectEqualStrings("<span alpha=\"50%\">https://</span>www.example.com<span alpha=\"50%\">/path/to/page</span>", result);
}

test "buildUrlMarkup: http with port and path" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("http://localhost:3000/api", &buf);
    try std.testing.expectEqualStrings("<span alpha=\"50%\">http://</span>localhost<span alpha=\"50%\">:3000/api</span>", result);
}

test "buildUrlMarkup: about:blank plain" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("about:blank", &buf);
    try std.testing.expectEqualStrings("about:blank", result);
}

test "buildUrlMarkup: bare domain no scheme" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("www.example.com", &buf);
    try std.testing.expectEqualStrings("www.example.com", result);
}

test "buildUrlMarkup: domain only with trailing slash" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("https://example.com/", &buf);
    try std.testing.expectEqualStrings("<span alpha=\"50%\">https://</span>example.com<span alpha=\"50%\">/</span>", result);
}

test "buildUrlMarkup: domain with query string" {
    var buf: [2048:0]u8 = .{0} ** 2048;
    const result = buildUrlMarkup("https://example.com/search?q=test", &buf);
    try std.testing.expectEqualStrings("<span alpha=\"50%\">https://</span>example.com<span alpha=\"50%\">/search?q=test</span>", result);
}

test "web sources: tracked idle cancel is idempotent and never double-removes" {
    const State = struct {
        var id: c.guint = 0;
        var ran: usize = 0;
        fn cb(data: c.gpointer) callconv(.c) c.gboolean {
            _ = data;
            ran += 1;
            return c.G_SOURCE_REMOVE;
        }
    };
    State.id = 0;
    State.ran = 0;

    // Cancel with nothing pending is a no-op (a g_source_remove(0) would
    // raise a GLib critical under fatal-criticals).
    cancelIdle(&State.id);

    // Queue, cancel, drain: the callback must not run.
    State.id = c.g_idle_add(State.cb, null);
    try std.testing.expect(State.id != 0);
    cancelIdle(&State.id);
    try std.testing.expectEqual(@as(c.guint, 0), State.id);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(@as(usize, 0), State.ran);

    // Repeated cancel after a dispatch-clear is a no-op.
    cancelIdle(&State.id);
    cancelIdle(&State.id);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(@as(usize, 0), State.ran);
}

test "web panel: create and destroy release their allocations" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const panel = try WebPanel.create(alloc, "about:blank");
    panel.destroy();
}

test "web panel: widget finalization before panel destroy is safe" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const panel = try WebPanel.create(alloc, "about:blank");
    const widget = panel.widget;
    _ = c.g_object_ref_sink(@ptrCast(widget));
    // The app's natural order: the widget tree is torn down first (close
    // page / unparent), then the panel is destroyed against the weak-
    // nulled emitters.
    c.g_object_unref(@ptrCast(widget));
    panel.destroy();
}

test "web panel: pending first-load and flash sources are cancelled before free" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const panel = try WebPanel.create(alloc, "about:blank");

    // First-load idle: queued through the real onMap path, tracked for
    // cancellation (a genuine map event passes the mapped widget).
    onMap(@ptrCast(panel.widget), @ptrCast(panel));
    try std.testing.expect(panel.initial_load_done);
    try std.testing.expect(panel.initial_load_id != 0);

    // Flash chain: triggerFlash always leaves a pending timeout source
    // (animated pulse or the static reduced-motion highlight).
    panel.triggerFlash();
    try std.testing.expect(panel.flash_timeout != 0);

    // Teardown cancels both sources before self is freed; draining after
    // the free must not dispatch into it (fatal-criticals enforces). The
    // widget tree is left un-finalized here on purpose: WebKit's dispose
    // path is only safe under the full application runtime, and the
    // finalize-then-destroy order is covered by the test above.
    panel.destroy();
    while (c.g_main_context_iteration(null, 0) != 0) {}
}

test "web panel: create seeds live weak slots and terminates the entry URL" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    // A parsed JSON URL slice has no terminator; `Z` right behind it is the
    // first byte the entry must never copy.
    const url = "https://example.com/x";
    var backing = [_]u8{'Z'} ** (url.len + 4);
    @memcpy(backing[0..url.len], url);
    const panel = try WebPanel.create(alloc, backing[0..url.len]);
    const widget = panel.widget;
    _ = c.g_object_ref_sink(@ptrCast(widget));
    defer {
        c.g_object_unref(@ptrCast(widget));
        panel.destroy();
    }

    // Both emitters are tracked the moment the panel exists, so a later
    // teardown can reach them; registration must not leave null slots.
    try testing.expect(panel.widget_weak != null);
    try testing.expect(panel.webview_weak != null);
    const text = c.gtk_editable_get_text(@ptrCast(panel.entry)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(url, std.mem.span(text));
}

test "web panel: about:blank is copied into the entry, not its sentinel tail" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var backing = [_]u8{'Z'} ** ("about:blank".len + 3);
    @memcpy(backing[0.."about:blank".len], "about:blank");
    const panel = try WebPanel.create(alloc, backing[0.."about:blank".len]);
    const widget = panel.widget;
    _ = c.g_object_ref_sink(@ptrCast(widget));
    defer {
        c.g_object_unref(@ptrCast(widget));
        panel.destroy();
    }

    const text = c.gtk_editable_get_text(@ptrCast(panel.entry)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("about:blank", std.mem.span(text));
}

test "web panel: disconnect is idempotent and leaves live emitters usable" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const panel = try WebPanel.create(alloc, "https://example.com");
    const widget = panel.widget;
    _ = c.g_object_ref_sink(@ptrCast(widget));

    // The panel goes first while its widget tree is still alive: both
    // registrations are removed and the slots nulled.
    panel.disconnectSignals();
    try testing.expect(panel.widget_weak == null);
    try testing.expect(panel.webview_weak == null);
    // A repeated call must not touch already-removed registrations.
    panel.disconnectSignals();

    // The tree outlives the disconnect and still works.
    c.gtk_editable_set_text(@ptrCast(panel.entry), "still reachable");
    const text = c.gtk_editable_get_text(@ptrCast(panel.entry)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("still reachable", std.mem.span(text));

    c.g_object_unref(@ptrCast(widget));
    panel.destroy();
}

test "tls contexts: invalidation turns the response into a pure release" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var panel: WebPanel = undefined;
    panel.tls_head = null;

    const ctx = try alloc.create(TlsErrorCtx);
    ctx.* = .{
        .panel = &panel,
        .alloc = alloc,
        .failing_uri = try alloc.dupe(u8, "https://example.com"),
        .certificate = null,
        .host = try alloc.dupe(u8, "example.com"),
        .next = null,
    };
    panel.tls_head = ctx;

    invalidateTlsContexts(&panel);
    try testing.expect(ctx.panel == null);

    // The dialog response now only frees the context — exactly once;
    // the allocator's leak check enforces single release.
    releaseTlsCtx(ctx);
}

test "tls contexts: a live-panel response unlinks before freeing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var panel: WebPanel = undefined;
    panel.tls_head = null;

    const first = try alloc.create(TlsErrorCtx);
    first.* = .{ .panel = &panel, .alloc = alloc, .failing_uri = try alloc.dupe(u8, "https://a"), .certificate = null, .host = try alloc.dupe(u8, "a"), .next = null };
    panel.tls_head = first;
    const second = try alloc.create(TlsErrorCtx);
    second.* = .{ .panel = &panel, .alloc = alloc, .failing_uri = try alloc.dupe(u8, "https://b"), .certificate = null, .host = try alloc.dupe(u8, "b"), .next = first };
    panel.tls_head = second;

    // Response for the older context while the panel is alive: unlinked
    // so a later teardown never walks the freed entry.
    unlinkTlsCtx(&panel, first);
    try testing.expectEqual(@as(?*TlsErrorCtx, second), panel.tls_head);
    try testing.expect(second.next == null);

    // Panel teardown invalidates only what is still outstanding.
    invalidateTlsContexts(&panel);
    try testing.expect(second.panel == null);
    releaseTlsCtx(second);
    releaseTlsCtx(first);
}
