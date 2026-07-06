const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const Window = @import("window.zig");
const keybinds = @import("keybinds.zig");
const session = @import("session.zig");
const WindowManager = @import("window_manager.zig").WindowManager;
const socket_server = @import("socket_server.zig");
const ghostty_bridge = @import("ghostty_bridge.zig");
const config_mod = @import("config.zig");
const blur_mod = @import("blur.zig");
const kde_decoration = @import("kde_decoration.zig");

const is_linux = builtin.os.tag == .linux;

/// Auto-install OpenCode plugin if OpenCode config dir exists but plugin is missing.
pub fn installOpenCodePlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const config_dir_path = std.fmt.allocPrint(alloc, "{s}/.config/opencode", .{home}) catch return;
    defer alloc.free(config_dir_path);
    _ = std.fs.openDirAbsolute(config_dir_path, .{}) catch return; // no opencode config dir → not installed

    // Read bundled plugin
    const bundled_path = blk: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch return;
        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const prefix = std.fs.path.dirname(exe_dir) orelse return;
        break :blk std.fmt.allocPrint(alloc, "{s}/share/seance/opencode-plugin.ts", .{prefix}) catch return;
    };
    defer alloc.free(bundled_path);

    const bundled_file = std.fs.openFileAbsolute(bundled_path, .{}) catch {
        std.log.info("opencode: plugin source not found, skipping", .{});
        return;
    };
    defer bundled_file.close();
    const bundled_content = bundled_file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(bundled_content);

    const bundled_version = extractVersion(bundled_content);

    // Check if installed plugin exists
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/opencode/plugins/seance-opencode.ts", .{home}) catch return;
    defer alloc.free(plugin_path);

    const installed_file = std.fs.openFileAbsolute(plugin_path, .{}) catch null;
    const installed_content = if (installed_file) |f| f.readToEndAlloc(alloc, 64 * 1024) catch null else null;
    defer if (installed_file) |f| f.close();
    defer if (installed_content) |ic| alloc.free(ic);

    if (installed_content) |content| {
        const installed_version = extractVersion(content);
        const identical = content.len == bundled_content.len and std.mem.eql(u8, content, bundled_content);
        if (installed_version == bundled_version and identical) return; // already in sync
        std.log.info("opencode: syncing plugin v{} → v{}", .{ installed_version, bundled_version });
    } else {
        ensurePluginDir(home) catch return;
        std.log.info("opencode: installing plugin v{}", .{bundled_version});
    }

    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{plugin_path}) catch return;
    defer alloc.free(tmp_path);
    const dst = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
}

/// Remove OpenCode plugin if installed.
pub fn removeOpenCodePlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/opencode/plugins/seance-opencode.ts", .{home}) catch return;
    defer alloc.free(plugin_path);
    std.fs.deleteFileAbsolute(plugin_path) catch |err| {
        if (err != error.FileNotFound) std.log.warn("opencode: failed to remove plugin: {s}", .{@errorName(err)});
    };
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.config/opencode/.seance-version", .{home}) catch return;
    defer alloc.free(marker_path);
    std.fs.deleteFileAbsolute(marker_path) catch {};
}

fn extractVersion(content: []const u8) u32 {
    // Look for "// @seance-version N" in first 256 bytes
    const header = if (content.len > 256) content[0..256] else content;
    if (std.mem.indexOf(u8, header, "@seance-version")) |idx| {
        const rest = header[idx + 16 ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
        if (end > 0) return std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
    }
    return 0;
}

fn ensurePluginDir(home: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const plugins_dir = try std.fmt.allocPrint(alloc, "{s}/.config/opencode/plugins", .{home});
    defer alloc.free(plugins_dir);
    std.fs.makeDirAbsolute(plugins_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };
}

/// Auto-install Kilo Code plugin if Kilo config dir exists but plugin is missing.
pub fn installKiloPlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const config_dir_path = std.fmt.allocPrint(alloc, "{s}/.config/kilo", .{home}) catch return;
    defer alloc.free(config_dir_path);
    _ = std.fs.openDirAbsolute(config_dir_path, .{}) catch return; // no kilo config dir → not installed

    // Read bundled plugin
    const bundled_path = blk: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch return;
        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const prefix = std.fs.path.dirname(exe_dir) orelse return;
        break :blk std.fmt.allocPrint(alloc, "{s}/share/seance/kilo-plugin.ts", .{prefix}) catch return;
    };
    defer alloc.free(bundled_path);

    const bundled_file = std.fs.openFileAbsolute(bundled_path, .{}) catch {
        std.log.info("kilo: plugin source not found, skipping", .{});
        return;
    };
    defer bundled_file.close();
    const bundled_content = bundled_file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(bundled_content);

    const bundled_version = extractVersion(bundled_content);

    // Check if installed plugin exists
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/kilo/plugins/seance-kilo.ts", .{home}) catch return;
    defer alloc.free(plugin_path);

    const installed_file = std.fs.openFileAbsolute(plugin_path, .{}) catch null;
    const installed_content = if (installed_file) |f| f.readToEndAlloc(alloc, 64 * 1024) catch null else null;
    defer if (installed_file) |f| f.close();
    defer if (installed_content) |ic| alloc.free(ic);

    if (installed_content) |content| {
        const installed_version = extractVersion(content);
        const identical = content.len == bundled_content.len and std.mem.eql(u8, content, bundled_content);
        if (installed_version == bundled_version and identical) return; // already in sync
        std.log.info("kilo: syncing plugin v{} → v{}", .{ installed_version, bundled_version });
    } else {
        ensureKiloPluginDir(home) catch return;
        std.log.info("kilo: installing plugin v{}", .{bundled_version});
    }

    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{plugin_path}) catch return;
    defer alloc.free(tmp_path);
    const dst = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
}

/// Remove Kilo Code plugin if installed.
pub fn removeKiloPlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/kilo/plugins/seance-kilo.ts", .{home}) catch return;
    defer alloc.free(plugin_path);
    std.fs.deleteFileAbsolute(plugin_path) catch |err| {
        if (err != error.FileNotFound) std.log.warn("kilo: failed to remove plugin: {s}", .{@errorName(err)});
    };
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.config/kilo/.seance-version", .{home}) catch return;
    defer alloc.free(marker_path);
    std.fs.deleteFileAbsolute(marker_path) catch {};
}

fn ensureKiloPluginDir(home: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const plugins_dir = try std.fmt.allocPrint(alloc, "{s}/.config/kilo/plugins", .{home});
    defer alloc.free(plugins_dir);
    std.fs.makeDirAbsolute(plugins_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };
}

/// Auto-install MiMo Code plugin if MiMo Code config dir exists but plugin is missing.
pub fn installMimocodePlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const config_dir_path = std.fmt.allocPrint(alloc, "{s}/.config/mimocode", .{home}) catch return;
    defer alloc.free(config_dir_path);
    _ = std.fs.openDirAbsolute(config_dir_path, .{}) catch return; // no mimocode config dir → not installed

    // Read bundled plugin
    const bundled_path = blk: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch return;
        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const prefix = std.fs.path.dirname(exe_dir) orelse return;
        break :blk std.fmt.allocPrint(alloc, "{s}/share/seance/mimocode-plugin.ts", .{prefix}) catch return;
    };
    defer alloc.free(bundled_path);

    const bundled_file = std.fs.openFileAbsolute(bundled_path, .{}) catch {
        std.log.info("mimocode: plugin source not found, skipping", .{});
        return;
    };
    defer bundled_file.close();
    const bundled_content = bundled_file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(bundled_content);

    const bundled_version = extractVersion(bundled_content);

    // Check if installed plugin exists
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/mimocode/plugins/seance-mimocode.ts", .{home}) catch return;
    defer alloc.free(plugin_path);

    const installed_file = std.fs.openFileAbsolute(plugin_path, .{}) catch null;
    const installed_content = if (installed_file) |f| f.readToEndAlloc(alloc, 64 * 1024) catch null else null;
    defer if (installed_file) |f| f.close();
    defer if (installed_content) |ic| alloc.free(ic);

    if (installed_content) |content| {
        const installed_version = extractVersion(content);
        const identical = content.len == bundled_content.len and std.mem.eql(u8, content, bundled_content);
        if (installed_version == bundled_version and identical) return; // already in sync
        std.log.info("mimocode: syncing plugin v{} → v{}", .{ installed_version, bundled_version });
    } else {
        ensureMimocodePluginDir(home) catch return;
        std.log.info("mimocode: installing plugin v{}", .{bundled_version});
    }

    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{plugin_path}) catch return;
    defer alloc.free(tmp_path);
    const dst = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
}

/// Remove MiMo Code plugin if installed.
pub fn removeMimocodePlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const plugin_path = std.fmt.allocPrint(alloc, "{s}/.config/mimocode/plugins/seance-mimocode.ts", .{home}) catch return;
    defer alloc.free(plugin_path);
    std.fs.deleteFileAbsolute(plugin_path) catch |err| {
        if (err != error.FileNotFound) std.log.warn("mimocode: failed to remove plugin: {s}", .{@errorName(err)});
    };
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.config/mimocode/.seance-version", .{home}) catch return;
    defer alloc.free(marker_path);
    std.fs.deleteFileAbsolute(marker_path) catch {};
}

fn ensureMimocodePluginDir(home: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const plugins_dir = try std.fmt.allocPrint(alloc, "{s}/.config/mimocode/plugins", .{home});
    defer alloc.free(plugins_dir);
    std.fs.makeDirAbsolute(plugins_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };
}

/// Auto-install Vibe hooks.toml if ~/.vibe exists.
pub fn installVibeHooks() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;

    // Check if Vibe config directory exists
    const config_dir_path = std.fmt.allocPrint(alloc, "{s}/.vibe", .{home}) catch return;
    defer alloc.free(config_dir_path);
    _ = std.fs.openDirAbsolute(config_dir_path, .{}) catch return; // no vibe config dir → not installed

    // Read bundled hooks template
    const bundled_path = blk: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch return;
        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const prefix = std.fs.path.dirname(exe_dir) orelse return;
        break :blk std.fmt.allocPrint(alloc, "{s}/share/seance/vibe-hooks.toml", .{prefix}) catch return;
    };
    defer alloc.free(bundled_path);

    const bundled_file = std.fs.openFileAbsolute(bundled_path, .{}) catch {
        std.log.info("vibe: hooks template not found, skipping", .{});
        return;
    };
    defer bundled_file.close();
    const bundled_content = bundled_file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(bundled_content);

    // Check if hooks.toml already exists
    const hooks_path = std.fmt.allocPrint(alloc, "{s}/.vibe/hooks.toml", .{home}) catch return;
    defer alloc.free(hooks_path);

    const installed_file = std.fs.openFileAbsolute(hooks_path, .{}) catch null;
    const installed_content = if (installed_file) |f| f.readToEndAlloc(alloc, 64 * 1024) catch null else null;
    defer if (installed_file) |f| f.close();
    defer if (installed_content) |ic| alloc.free(ic);

    if (installed_content) |content| {
        // Already has seance hooks installed (check for marker comment)
        if (std.mem.indexOf(u8, content, "Auto-installed by") != null) return;
        // Append to existing hooks.toml
        const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{hooks_path}) catch return;
        defer alloc.free(tmp_path);
        const dst = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
        _ = dst.writeAll(content) catch return;
        _ = dst.writeAll("\n") catch return;
        _ = dst.writeAll(bundled_content) catch return;
        dst.close();
        std.fs.renameAbsolute(tmp_path, hooks_path) catch return;
        std.log.info("vibe: appended hooks to existing hooks.toml", .{});
    } else {
        // Write new hooks.toml
        const dst = std.fs.createFileAbsolute(hooks_path, .{}) catch return;
        errdefer std.fs.deleteFileAbsolute(hooks_path) catch {};
        _ = dst.writeAll(bundled_content) catch return;
        dst.close();
        std.log.info("vibe: installed hooks.toml", .{});
    }
}

/// Remove Vibe hooks from ~/.vibe/hooks.toml.
pub fn removeVibeHooks() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const hooks_path = std.fmt.allocPrint(alloc, "{s}/.vibe/hooks.toml", .{home}) catch return;
    defer alloc.free(hooks_path);

    const file = std.fs.openFileAbsolute(hooks_path, .{}) catch return;
    defer file.close();
    const content = file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(content);

    // Find the seance section by marker
    const marker = "# Auto-installed by";
    const start = std.mem.indexOf(u8, content, marker) orelse return;

    // Find the start of the marker line (go back to beginning of line)
    var line_start = start;
    while (line_start > 0 and content[line_start - 1] != '\n') : (line_start -= 1) {}

    // Find where seance content ends: look for next [[hooks]] that isn't a seance hook
    var end: usize = content.len;
    {
        var pos = line_start;
        while (pos < content.len) {
            const eol = std.mem.indexOfScalar(u8, content[pos..], '\n') orelse content.len;
            const line = std.mem.trimRight(u8, content[pos..pos + eol], " \t\r");
            // If we hit a [[hooks]] block (non-seance), stop here
            if (std.mem.startsWith(u8, line, "[[hooks]]")) {
                // Check if this line references seance
                if (std.mem.indexOf(u8, content[pos..pos + eol], "seance") != null) {
                    pos += eol + 1;
                    continue;
                }
                end = pos;
                break;
            }
            pos += eol + 1;
        }
    }

    const before = content[0..line_start];
    const after = if (end < content.len) content[end..] else "";
    const before_trimmed = std.mem.trimRight(u8, before, " \t\r\n");
    const after_trimmed = std.mem.trimLeft(u8, after, " \t\r\n");

    if (before_trimmed.len == 0 and after_trimmed.len == 0) {
        std.fs.deleteFileAbsolute(hooks_path) catch {};
        return;
    }

    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{hooks_path}) catch return;
    defer alloc.free(tmp_path);
    const dst = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    if (before_trimmed.len > 0) {
        _ = dst.writeAll(before_trimmed) catch return;
        _ = dst.writeAll("\n") catch return;
    }
    if (after_trimmed.len > 0) {
        _ = dst.writeAll(after_trimmed) catch return;
    }
    dst.close();
    std.fs.renameAbsolute(tmp_path, hooks_path) catch {};
}

pub const PluginAgent = enum { opencode, kilo, mimocode, vibe };

/// Sync a plugin's on-disk state with the given enabled flag.
pub fn syncPlugin(agent: PluginAgent, enabled: bool) void {
    if (enabled) {
        switch (agent) {
            .opencode => installOpenCodePlugin(),
            .kilo => installKiloPlugin(),
            .mimocode => installMimocodePlugin(),
            .vibe => installVibeHooks(),
        }
    } else {
        switch (agent) {
            .opencode => removeOpenCodePlugin(),
            .kilo => removeKiloPlugin(),
            .mimocode => removeMimocodePlugin(),
            .vibe => removeVibeHooks(),
        }
    }
}

var wm: ?*WindowManager = null;
var server: socket_server.SocketServer = .{};
pub var shutting_down: bool = false;

pub fn create() *c.AdwApplication {
    if (is_linux) {
        _ = c.notify_init("seance");
    }

    const app = c.adw_application_new("com.seance.app", c.G_APPLICATION_DEFAULT_FLAGS);
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(app)),
        "activate",
        @as(c.GCallback, @ptrCast(&onActivate)),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(app)),
        "shutdown",
        @as(c.GCallback, @ptrCast(&onShutdown)),
        null,
        null,
        0,
    );
    return app;
}

pub fn destroy(app: *c.AdwApplication) void {
    c.g_object_unref(@ptrCast(app));
}

pub fn run(app: *c.AdwApplication) c_int {
    return c.g_application_run(gapp(app), 0, null);
}

fn onActivate(app: *c.AdwApplication) callconv(.c) void {
    keybinds.register(gtkApp(app));

    if (wm == null) {
        // Register bundled icons so GTK can find them by name.
        // Icons are installed to <prefix>/share/icons; the exe is at <prefix>/bin/.
        registerBundledIcons();

        // Load config before initializing ghostty so theme/font settings are available
        _ = config_mod.load();

        syncPlugin(.opencode, config_mod.get().opencode_hooks);
        syncPlugin(.kilo, config_mod.get().kilo_hooks);
        syncPlugin(.mimocode, config_mod.get().mimocode_hooks);
        syncPlugin(.vibe, config_mod.get().vibe_hooks);

        // Set libadwaita to follow system dark/light, preferring dark when
        // the system has no opinion (or on non-Linux platforms).
        const style_manager = c.adw_style_manager_get_default();
        c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_DEFAULT);

        // Initialize ghostty terminal engine
        if (!ghostty_bridge.init()) {
            std.log.err("Failed to initialize ghostty bridge", .{});
        }

        // Track system dark/light changes for default theme mode
        Window.initThemeTracking();

        // Initialize blur/transparency protocol support (X11/Wayland)
        blur_mod.init();

        // Initialize KDE server-side decoration support — no-op when not on KDE.
        kde_decoration.init();

        // First activation: create window manager and restore session
        const manager = WindowManager.init(gtkApp(app));
        wm = manager;
        Window.window_manager = manager;

        // Start socket server for CLI notifications (e.g., seance notify)
        server.start();

        session.cleanupStaleReplayDirs();
        if (!session.loadAndRestoreAll(manager)) {
            _ = manager.newWindow();
        }
        // Register UNIX signal handlers for graceful shutdown
        _ = c.g_unix_signal_add(std.posix.SIG.TERM, &onUnixSignal, @ptrCast(@alignCast(app)));
        _ = c.g_unix_signal_add(std.posix.SIG.INT, &onUnixSignal, @ptrCast(@alignCast(app)));
        _ = c.g_unix_signal_add(std.posix.SIG.HUP, &onUnixSignal, @ptrCast(@alignCast(app)));
    } else {
        // Subsequent activation (e.g., second instance): new window
        _ = wm.?.newWindow();
    }
}

fn onShutdown(_: *c.AdwApplication) callconv(.c) void {
    shutting_down = true;

    if (wm) |manager| {
        // Remove autosave timer first to prevent it firing during cleanup
        if (manager.autosave_timer != 0) {
            _ = c.g_source_remove(manager.autosave_timer);
            manager.autosave_timer = 0;
        }

        if (manager.windows.items.len > 0) {
            session.saveAll(manager, true);
        }
    }

    // Clean up scrollback replay temp files
    session.cleanupReplayDir();

    // Clean up wrapper resources dir (symlinks + wrapper scripts)
    ghostty_bridge.cleanupResourcesWrapper();

    // Clean up external resources before force-exit so we don't leave
    // stale socket files behind.
    server.stop();

    // Force-exit — ghostty's thread joins deadlock on Linux because the
    // renderer thread requires the main thread (must_draw_from_app_thread).
    std.posix.exit(0);
}

fn onUnixSignal(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_application_quit(@as(*c.GApplication, @ptrCast(@alignCast(data))));
    return 0; // G_SOURCE_REMOVE
}

fn registerBundledIcons() void {
    // Resolve exe path via /proc/self/exe, then derive <prefix>/share/icons.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch return;
    // exe_path is e.g. "/path/to/zig-out/bin/seance"
    // We need "/path/to/zig-out/share/icons"
    const bin_dir = std.fs.path.dirname(exe_path) orelse return;
    const prefix = std.fs.path.dirname(bin_dir) orelse return;

    var icon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const icons_path = std.fmt.bufPrintZ(&icon_buf, "{s}/share/icons", .{prefix}) catch return;

    const theme = c.gtk_icon_theme_get_for_display(c.gdk_display_get_default());
    c.gtk_icon_theme_add_search_path(theme, icons_path.ptr);
}

// Cast helpers
pub fn gapp(app: *c.AdwApplication) *c.GApplication {
    return @ptrCast(app);
}

pub fn gtkApp(app: *c.AdwApplication) *c.GtkApplication {
    return @ptrCast(app);
}
