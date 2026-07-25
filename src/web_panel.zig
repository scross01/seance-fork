const std = @import("std");
const c = @import("c.zig").c;

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

pub const WebPanel = struct {
    id: u64,
    widget: *c.GtkWidget,
    webview: *c.WebKitWebView,
    url: []u8,
    title: []u8,
    alloc: std.mem.Allocator,

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

        // Create a GtkBox to hold the webview
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);
        c.gtk_box_append(@ptrCast(box), webview_widget);

        const owned_url = try alloc.dupe(u8, url);
        errdefer alloc.free(owned_url);

        const panel = try alloc.create(WebPanel);
        panel.* = .{
            .id = id,
            .widget = box,
            .webview = webview,
            .url = owned_url,
            .title = "",
            .alloc = alloc,
        };

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
        const w: *c.GtkWidget = @ptrCast(self.webview);
        _ = c.gtk_widget_grab_focus(w);
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
