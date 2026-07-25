const std = @import("std");
const c = @import("c.zig").c;

const WEBKIT_LOAD_COMMITTED: c_int = 1;

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

pub const WebPanel = struct {
    id: u64,
    widget: *c.GtkWidget,
    entry: *c.GtkEntry,
    webview: *c.WebKitWebView,
    url: []u8,
    title: []u8,
    alloc: std.mem.Allocator,
    navigating_from_entry: bool = false,

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
        c.webkit_settings_set_enable_hyperlink_auditing(settings, 0);
        c.webkit_settings_set_javascript_can_access_clipboard(settings, 0);

        const webview_widget: *c.GtkWidget = @ptrCast(webview);
        c.gtk_widget_set_hexpand(webview_widget, 1);
        c.gtk_widget_set_vexpand(webview_widget, 1);

        // Create a GtkBox to hold the address bar and webview
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);

        // Address bar
        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(@ptrCast(entry), 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Enter URL...");
        c.gtk_box_append(@ptrCast(box), @ptrCast(entry));

        // Webview
        c.gtk_box_append(@ptrCast(box), webview_widget);

        const owned_url = try alloc.dupe(u8, url);
        errdefer alloc.free(owned_url);

        const panel = try alloc.create(WebPanel);
        panel.* = .{
            .id = id,
            .widget = box,
            .entry = @ptrCast(entry),
            .webview = webview,
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

        // Sync entry text on page load
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(webview)),
            "load-changed",
            @as(c.GCallback, @ptrCast(&onLoadChanged)),
            @ptrCast(panel),
            null,
            0,
        );

        // Load URL if valid
        if (isAllowedUrl(url)) {
            var url_buf: [4096:0]u8 = .{0} ** 4096;
            const len = @min(url.len, 4095);
            @memcpy(url_buf[0..len], url[0..len]);
            url_buf[len] = 0;
            c.webkit_web_view_load_uri(webview, &url_buf);
        }

        return panel;
    }

    pub fn getWidget(self: *WebPanel) *c.GtkWidget {
        return self.widget;
    }

    pub fn getId(self: *WebPanel) u64 {
        return self.id;
    }

    pub fn focus(self: *WebPanel) void {
        const uri = c.webkit_web_view_get_uri(self.webview);
        const url_str = if (uri) |u| std.mem.span(u) else self.url;
        c.gtk_editable_set_text(@ptrCast(self.entry), url_str.ptr);
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
    }

    pub fn reload(self: *WebPanel) void {
        c.webkit_web_view_reload(self.webview);
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
};

/// URL scheme validation — reject local/private network schemes
pub fn isAllowedUrl(url: []const u8) bool {
    if (url.len == 0) return false;

    // Reject file:// and data: URIs
    if (std.mem.startsWith(u8, url, "file:")) return false;
    if (std.mem.startsWith(u8, url, "data:")) return false;
    if (std.mem.startsWith(u8, url, "javascript:")) return false;
    if (std.mem.startsWith(u8, url, "blob:")) return false;

    // Must be http or https
    const after_scheme: []const u8 = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (std.mem.startsWith(u8, after_scheme, "169.254.") or
        std.mem.startsWith(u8, after_scheme, "127.") or
        std.mem.startsWith(u8, after_scheme, "10.") or
        std.mem.startsWith(u8, after_scheme, "192.168.") or
        std.mem.startsWith(u8, after_scheme, "0.") or
        std.mem.eql(u8, after_scheme, "localhost") or
        std.mem.startsWith(u8, after_scheme, "localhost:") or
        std.mem.startsWith(u8, after_scheme, "[::1]") or
        std.mem.startsWith(u8, after_scheme, "[0:"))
    {
        return false;
    }

    // 172.16-31.x.x (RFC1918)
    if (std.mem.startsWith(u8, after_scheme, "172.")) {
        const rest = after_scheme["172.".len..];
        if (rest.len > 0) {
            const dot_pos = std.mem.indexOfScalar(u8, rest, '.') orelse return true;
            const octet_str = rest[0..dot_pos];
            if (std.fmt.parseInt(u8, octet_str, 10)) |octet| {
                if (octet >= 16 and octet <= 31) return false;
            } else |_| {}
        }
    }

    return true;
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

fn onLoadChanged(webview: ?*c.WebKitWebView, event: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = webview;
    const panel: *WebPanel = @ptrCast(@alignCast(user_data orelse return));
    if (event != WEBKIT_LOAD_COMMITTED) return;
    const uri = c.webkit_web_view_get_uri(panel.webview);
    if (uri) |u| {
        const new_url = std.mem.span(u);
        if (!std.mem.eql(u8, panel.url, new_url)) {
            const owned = panel.alloc.dupe(u8, new_url) catch return;
            panel.alloc.free(panel.url);
            panel.url = owned;
        }
    }
    if (!panel.navigating_from_entry) {
        const url_str = if (uri) |u| std.mem.span(u) else panel.url;
        c.gtk_editable_set_text(@ptrCast(panel.entry), url_str.ptr);
    }
    panel.navigating_from_entry = false;
}

test "isAllowedUrl: https accepted" {
    try std.testing.expect(isAllowedUrl("https://example.com"));
}

test "isAllowedUrl: http accepted" {
    try std.testing.expect(isAllowedUrl("http://example.com"));
}

test "isAllowedUrl: file rejected" {
    try std.testing.expect(!isAllowedUrl("file:///etc/passwd"));
}

test "isAllowedUrl: data rejected" {
    try std.testing.expect(!isAllowedUrl("data:text/html,<h1>hi</h1>"));
}

test "isAllowedUrl: localhost rejected" {
    try std.testing.expect(!isAllowedUrl("http://localhost:3000"));
}

test "isAllowedUrl: loopback rejected" {
    try std.testing.expect(!isAllowedUrl("http://127.0.0.1/secret"));
}

test "isAllowedUrl: link-local rejected" {
    try std.testing.expect(!isAllowedUrl("http://169.254.169.254/metadata"));
}

test "isAllowedUrl: RFC1918 10.x rejected" {
    try std.testing.expect(!isAllowedUrl("http://10.0.0.1/secret"));
}

test "isAllowedUrl: RFC1918 192.168.x rejected" {
    try std.testing.expect(!isAllowedUrl("http://192.168.1.1/secret"));
}

test "isAllowedUrl: RFC1918 172.16.x rejected" {
    try std.testing.expect(!isAllowedUrl("http://172.16.0.1/secret"));
}

test "isAllowedUrl: RFC1918 172.31.x rejected" {
    try std.testing.expect(!isAllowedUrl("http://172.31.255.255/secret"));
}

test "isAllowedUrl: 172.32.x accepted (not RFC1918)" {
    try std.testing.expect(isAllowedUrl("http://172.32.0.1/ok"));
}

test "isAllowedUrl: javascript rejected" {
    try std.testing.expect(!isAllowedUrl("javascript:alert(1)"));
}

test "isAllowedUrl: empty rejected" {
    try std.testing.expect(!isAllowedUrl(""));
}
