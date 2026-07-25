const std = @import("std");
const c = @import("c.zig").c;

const WEBKIT_LOAD_STARTED: c_int = 0;
const WEBKIT_LOAD_COMMITTED: c_int = 2;
const WEBKIT_LOAD_FINISHED: c_int = 3;

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

pub const CloseFn = *const fn (*anyopaque) callconv(.c) void;
pub const FocusFn = *const fn (*anyopaque) callconv(.c) void;

pub const WebPanel = struct {
    id: u64,
    widget: *c.GtkWidget,
    toolbar: *c.GtkWidget,
    entry: *c.GtkEntry,
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

    pub fn create(alloc: std.mem.Allocator, url: []const u8) !*WebPanel {
        const id = nextId();

        const webview = @as(*c.WebKitWebView, @ptrCast(c.webkit_web_view_new() orelse return error.OutOfMemory));

        // Harden settings before any load
        const settings = c.webkit_web_view_get_settings(webview);
        c.webkit_settings_set_enable_developer_extras(settings, 0);
        c.webkit_settings_set_enable_page_cache(settings, 0);
        c.webkit_settings_set_enable_html5_local_storage(settings, 0);
        c.webkit_settings_set_enable_html5_database(settings, 0);
        c.webkit_settings_set_javascript_can_open_windows_automatically(settings, 0);
        c.webkit_settings_set_javascript_can_access_clipboard(settings, 0);

        const webview_widget: *c.GtkWidget = @ptrCast(webview);
        c.gtk_widget_set_hexpand(webview_widget, 1);
        c.gtk_widget_set_vexpand(webview_widget, 1);

        // Root container
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);

        // Toolbar: [◀] [▶] [⟲/✕] [URL entry] [✕]
        const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_hexpand(toolbar, 1);
        c.gtk_widget_set_margin_start(toolbar, 4);
        c.gtk_widget_set_margin_end(toolbar, 4);
        c.gtk_widget_set_margin_top(toolbar, 4);
        c.gtk_widget_set_margin_bottom(toolbar, 4);

        const btn_back = c.gtk_button_new_from_icon_name("go-previous-symbolic");
        c.gtk_widget_set_tooltip_text(btn_back, "Back");
        c.gtk_box_append(@ptrCast(toolbar), btn_back);

        const btn_forward = c.gtk_button_new_from_icon_name("go-next-symbolic");
        c.gtk_widget_set_tooltip_text(btn_forward, "Forward");
        c.gtk_box_append(@ptrCast(toolbar), btn_forward);

        const btn_reload = c.gtk_button_new_from_icon_name("view-refresh-symbolic");
        c.gtk_widget_set_tooltip_text(btn_reload, "Reload");
        c.gtk_box_append(@ptrCast(toolbar), btn_reload);

        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(@ptrCast(entry), 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Enter URL...");
        c.gtk_box_append(@ptrCast(toolbar), @ptrCast(entry));

        const btn_close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_widget_set_tooltip_text(btn_close, "Close browser pane");
        c.gtk_box_append(@ptrCast(toolbar), btn_close);

        c.gtk_box_append(@ptrCast(box), toolbar);

        // Progress bar (thin line under toolbar, hidden by default)
        const progress_bar = c.gtk_progress_bar_new();
        c.gtk_widget_set_hexpand(progress_bar, 1);
        c.gtk_widget_set_size_request(progress_bar, -1, 3);
        c.gtk_widget_set_visible(progress_bar, 0);
        c.gtk_box_append(@ptrCast(box), progress_bar);

        // Webview
        c.gtk_box_append(@ptrCast(box), webview_widget);

        const owned_url = try alloc.dupe(u8, url);
        errdefer alloc.free(owned_url);

        const panel = try alloc.create(WebPanel);
        panel.* = .{
            .id = id,
            .widget = box,
            .toolbar = toolbar,
            .entry = @ptrCast(entry),
            .webview = webview,
            .btn_reload = btn_reload,
            .progress_bar = progress_bar,
            .url = owned_url,
            .title = "",
            .alloc = alloc,
        };

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
            c.gtk_editable_set_text(@ptrCast(entry), url.ptr);
        }

        return panel;
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
        const uri = c.webkit_web_view_get_uri(self.webview);
        if (uri) |u| {
            const url_str = std.mem.span(u);
            c.gtk_editable_set_text(@ptrCast(self.entry), url_str.ptr);
        }
        _ = c.gtk_widget_grab_focus(@ptrCast(self.entry));
    }

    pub fn unfocus(self: *WebPanel) void {
        _ = self;
    }

    pub fn disconnectSignals(self: *WebPanel) void {
        _ = self;
    }

    pub fn destroy(self: *WebPanel) void {
        self.alloc.free(self.url);
        if (self.title.len > 0) self.alloc.free(self.title);
        self.alloc.destroy(self);
    }

    pub fn triggerFlash(self: *WebPanel) void {
        _ = self;
    }

    pub fn queueResize(self: *WebPanel) void {
        c.gtk_widget_queue_resize(@ptrCast(self.webview));
    }

    pub fn navigate(self: *WebPanel, url: []const u8) void {
        if (!isAllowedUrl(url)) return;
        const new_url = self.alloc.dupe(u8, url) catch return;
        self.alloc.free(self.url);
        self.url = new_url;
        var url_buf: [4096:0]u8 = .{0} ** 4096;
        const len = @min(url.len, 4095);
        @memcpy(url_buf[0..len], url[0..len]);
        url_buf[len] = 0;
        c.webkit_web_view_load_uri(self.webview, &url_buf);
        c.gtk_editable_set_text(@ptrCast(self.entry), &url_buf);
    }

    pub fn reload(self: *WebPanel) void {
        c.webkit_web_view_reload(self.webview);
    }

    pub fn stop(self: *WebPanel) void {
        c.webkit_web_view_stop_loading(self.webview);
    }

    pub fn back(self: *WebPanel) void {
        c.webkit_web_view_go_back(self.webview);
    }

    pub fn forward(self: *WebPanel) void {
        c.webkit_web_view_go_forward(self.webview);
    }

    pub fn getTitle(self: *WebPanel) []const u8 {
        if (c.webkit_web_view_get_title(self.webview)) |title_ptr| {
            const new_title = std.mem.span(title_ptr);
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
    var url_buf: [4096:0]u8 = .{0} ** 4096;
    const len = @min(panel.url.len, 4095);
    @memcpy(url_buf[0..len], panel.url[0..len]);
    url_buf[len] = 0;
    c.webkit_web_view_load_uri(panel.webview, &url_buf);
}

fn onEntryActivate(entry_: ?*c.GtkEditable, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    const editable = entry_ orelse return;
    const text = c.gtk_editable_get_text(editable);
    if (text == null) return;
    const url = std.mem.span(text.?);
    if (url.len == 0) return;
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
                const new_url = std.mem.span(u);
                if (!std.mem.eql(u8, panel.url, new_url)) {
                    const owned = panel.alloc.dupe(u8, new_url) catch return;
                    panel.alloc.free(panel.url);
                    panel.url = owned;
                }
                if (!panel.navigating_from_entry) {
                    c.gtk_editable_set_text(@ptrCast(panel.entry), new_url.ptr);
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

fn onPanelFocusIn(_: ?*c.GtkEventControllerFocus, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (panel.focus_cb) |cb| {
        if (panel.focus_data) |data| {
            cb(data);
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

fn onCloseClicked(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (panel.close_cb) |cb| {
        if (panel.close_data) |data| {
            cb(data);
        }
    }
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
