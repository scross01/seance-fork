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

const SEANCE_OPENCODE_VERSION: u32 = 2;
const SEANCE_KILO_VERSION: u32 = 2;
const SEANCE_MIMOCODE_VERSION: u32 = 36;
const SEANCE_VIBE_VERSION: u32 = 1;
const SEANCE_HERMES_PLUGIN_VERSION: u32 = 1;
pub const SEANCE_POOL_VERSION: u32 = 1;

/// Auto-install OpenCode plugin if OpenCode config dir exists but plugin is missing.
pub fn installOpenCodePlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;
    const config_dir_path = std.fmt.allocPrint(alloc, "{s}/.config/opencode", .{home}) catch return;
    defer alloc.free(config_dir_path);
    _ = std.fs.openDirAbsolute(config_dir_path, .{}) catch return; // no opencode config dir → not installed

    // Fast path: if version marker matches, skip all further IO
    if (readVersionMarker(config_dir_path)) |marker_version| {
        if (marker_version >= SEANCE_OPENCODE_VERSION) return;
    }

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
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const dst = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(plugin_path)) |stat| {
        if (stat.kind == .sym_link) return;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
    writeVersionMarker(config_dir_path, SEANCE_OPENCODE_VERSION);
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

fn readVersionMarker(dir_path: []const u8) ?u32 {
    const alloc = std.heap.page_allocator;
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.seance-version", .{dir_path}) catch return null;
    defer alloc.free(marker_path);
    const file = std.fs.openFileAbsolute(marker_path, .{}) catch return null;
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, buf[0..n], 10) catch null;
}

fn writeVersionMarker(dir_path: []const u8, version: u32) void {
    const alloc = std.heap.page_allocator;
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.seance-version", .{dir_path}) catch return;
    defer alloc.free(marker_path);
    const file = std.fs.createFileAbsolute(marker_path, .{}) catch return;
    defer file.close();
    const buf = std.fmt.allocPrint(alloc, "{d}", .{version}) catch return;
    defer alloc.free(buf);
    _ = file.writeAll(buf) catch return;
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

    // Fast path: if version marker matches, skip all further IO
    if (readVersionMarker(config_dir_path)) |marker_version| {
        if (marker_version >= SEANCE_KILO_VERSION) return;
    }

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
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const dst = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(plugin_path)) |stat| {
        if (stat.kind == .sym_link) return;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
    writeVersionMarker(config_dir_path, SEANCE_KILO_VERSION);
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

    // Fast path: if version marker matches, skip all further IO
    if (readVersionMarker(config_dir_path)) |marker_version| {
        if (marker_version >= SEANCE_MIMOCODE_VERSION) return;
    }

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
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const dst = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(plugin_path)) |stat| {
        if (stat.kind == .sym_link) return;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, plugin_path) catch return;
    writeVersionMarker(config_dir_path, SEANCE_MIMOCODE_VERSION);
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

    // Fast path: if version marker matches, skip all further IO
    if (readVersionMarker(config_dir_path)) |marker_version| {
        if (marker_version >= SEANCE_VIBE_VERSION) return;
    }

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

    // Strip existing seance block first (idempotent upgrade)
    removeVibeHooks();

    // Write fresh hooks.toml (always create, since remove may have deleted it)
    const dst = std.fs.createFileAbsolute(hooks_path, .{}) catch return;
    errdefer std.fs.deleteFileAbsolute(hooks_path) catch {};
    _ = dst.writeAll(bundled_content) catch return;
    dst.close();
    std.log.info("vibe: installed hooks.toml", .{});
    writeVersionMarker(config_dir_path, SEANCE_VIBE_VERSION);
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
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const dst = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    if (before_trimmed.len > 0) {
        _ = dst.writeAll(before_trimmed) catch return;
        _ = dst.writeAll("\n") catch return;
    }
    if (after_trimmed.len > 0) {
        _ = dst.writeAll(after_trimmed) catch return;
    }
    dst.close();
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(hooks_path)) |stat| {
        if (stat.kind == .sym_link) return;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, hooks_path) catch {};
}

pub const PluginAgent = enum { opencode, kilo, mimocode, vibe, hermes };

/// Auto-install Hermes plugin if ~/.hermes exists.
pub fn installHermesPlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;

    // Check if Hermes config directory exists
    const hermes_dir = std.fmt.allocPrint(alloc, "{s}/.hermes", .{home}) catch return;
    defer alloc.free(hermes_dir);
    _ = std.fs.openDirAbsolute(hermes_dir, .{}) catch return; // no hermes dir → not installed

    // Fast path: if version marker matches, plugin files are already installed.
    // Still ensure enabled state in config.yaml (user may have edited it).
    if (readVersionMarker(hermes_dir)) |marker_version| {
        if (marker_version >= SEANCE_HERMES_PLUGIN_VERSION) {
            _ = ensureHermesPluginEnabled(home);
            return;
        }
    }

    // Read bundled plugin files
    const bundled_dir = blk: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch return;
        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const prefix = std.fs.path.dirname(exe_dir) orelse return;
        break :blk std.fmt.allocPrint(alloc, "{s}/share/seance/hermes-plugin", .{prefix}) catch return;
    };
    defer alloc.free(bundled_dir);

    // Create staging directory for atomic installation
    const plugins_parent = std.fmt.allocPrint(alloc, "{s}/.hermes/plugins", .{home}) catch return;
    defer alloc.free(plugins_parent);
    std.fs.makeDirAbsolute(plugins_parent) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.warn("hermes: failed to create plugins dir: {s}", .{@errorName(err)});
            return;
        }
    };

    const staging_dir = std.fmt.allocPrint(alloc, "{s}/.hermes/plugins/seance-staging", .{home}) catch return;
    defer alloc.free(staging_dir);
    // Clean up any leftover staging directory from a previous failed install
    std.fs.deleteTreeAbsolute(staging_dir) catch {};
    std.fs.makeDirAbsolute(staging_dir) catch |err| {
        std.log.warn("hermes: failed to create staging dir: {s}", .{@errorName(err)});
        return;
    };

    // Copy plugin files to staging directory
    copyPluginFile(alloc, bundled_dir, staging_dir, "plugin.yaml") catch {
        std.fs.deleteTreeAbsolute(staging_dir) catch {};
        return;
    };
    copyPluginFile(alloc, bundled_dir, staging_dir, "__init__.py") catch {
        std.fs.deleteTreeAbsolute(staging_dir) catch {};
        return;
    };

    // Atomically move staging directory to final location
    const plugin_dir = std.fmt.allocPrint(alloc, "{s}/.hermes/plugins/seance", .{home}) catch {
        std.fs.deleteTreeAbsolute(staging_dir) catch {};
        return;
    };
    defer alloc.free(plugin_dir);
    // Remove old plugin directory if it exists
    std.fs.deleteTreeAbsolute(plugin_dir) catch {};
    std.fs.renameAbsolute(staging_dir, plugin_dir) catch |err| {
        std.log.warn("hermes: failed to move staging dir to final location: {s}", .{@errorName(err)});
        std.fs.deleteTreeAbsolute(staging_dir) catch {};
        return;
    };

    // Enable the plugin in config.yaml
    if (ensureHermesPluginEnabled(home)) {
        writeVersionMarker(hermes_dir, SEANCE_HERMES_PLUGIN_VERSION);
        std.log.info("hermes: installed plugin v{}", .{SEANCE_HERMES_PLUGIN_VERSION});
    }
}

fn copyPluginFile(alloc: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, filename: []const u8) !void {
    const src_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, filename });
    defer alloc.free(src_path);
    const dst_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, filename });
    defer alloc.free(dst_path);

    const src_file = std.fs.openFileAbsolute(src_path, .{}) catch {
        std.log.warn("hermes: plugin source {s} not found", .{filename});
        return error.FileNotFound;
    };
    defer src_file.close();
    const content = src_file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(content);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{dst_path});
    defer alloc.free(tmp_path);
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const dst = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = dst.writeAll(content) catch return;
    dst.close();
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(dst_path)) |stat| {
        if (stat.kind == .sym_link) return error.IsSymlink;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, dst_path) catch return;
}

/// Find the `plugins.enabled:` line in config.yaml content.
/// Returns the index of the 'e' in "enabled:" if found within a plugins block, null otherwise.
fn findPluginsEnabledLine(content: []const u8) ?usize {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, content[pos..], "plugins:")) |offset| {
        const idx = pos + offset;
        // Verify at start of line
        if (idx == 0 or content[idx - 1] == '\n') {
            // Scan lines within the plugins block (indented or empty/comment lines)
            var line_start = idx + "plugins:".len;
            while (line_start < content.len) {
                // Find first non-whitespace on this line
                var col = line_start;
                while (col < content.len and (content[col] == ' ' or content[col] == '\t')) : (col += 1) {}
                // Empty or comment — still in block, skip line
                if (col >= content.len or content[col] == '\n' or content[col] == '#') {
                    while (line_start < content.len and content[line_start] != '\n') : (line_start += 1) {}
                    if (line_start < content.len) line_start += 1;
                    continue;
                }
                // Non-indented non-empty line — left the plugins block
                if (col == line_start) break;
                // Check for "enabled:" on this line
                const line_len = if (std.mem.indexOfScalar(u8, content[line_start..], '\n')) |n| n else content.len - line_start;
                if (std.mem.indexOf(u8, content[line_start .. line_start + line_len], "enabled:")) |e_off| {
                    const e_idx = line_start + e_off;
                    if (e_idx == line_start or content[e_idx - 1] == ' ' or content[e_idx - 1] == '\t') {
                        return e_idx;
                    }
                }
                // Advance to next line
                line_start += line_len;
                if (line_start < content.len) line_start += 1;
            }
        }
        pos = idx + "plugins:".len;
    }
    return null;
}

/// Ensure "seance" is in the plugins.enabled list in ~/.hermes/config.yaml
fn ensureHermesPluginEnabled(home: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const config_path = std.fmt.allocPrint(alloc, "{s}/.hermes/config.yaml", .{home}) catch return false;
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return false;
    defer file.close();
    const content = file.readToEndAlloc(alloc, 1024 * 1024) catch return false;
    defer alloc.free(content);

    // Already enabled? Match actual list-item tokens, not bare substring.
    if (isHermesPluginEnabled(content)) return true;

    // Find "plugins.enabled:" line (scoped to plugins block)
    const enabled_idx = findPluginsEnabledLine(content) orelse {
        // No plugins.enabled key exists — synthesize plugins:\n  enabled:\n    - seance
        // Find where "plugins:" block should go (after last top-level key, or append)
        var insert_at = content.len;
        // Look for an existing "plugins:" line to append under (anchored to line start)
        if (findLineStart(content, "plugins:")) |plugins_marker_pos| {
            // plugins: exists but has no enabled: — insert enabled: right after plugins: line
            insert_at = findLineEnd(content, plugins_marker_pos + "plugins:".len);
        } else {
            // No plugins: section at all — append to end of file
            // Ensure we end with a newline before appending
            if (insert_at > 0 and content[insert_at - 1] != '\n') {
                // insert_at stays at content.len, we'll prepend \n
            }
        }

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(alloc);
        new_content.appendSlice(alloc, content[0..insert_at]) catch return false;
        // If plugins: already existed, we're inserting after its line (no extra newline needed)
        // If appending to end, ensure newline separation
        if (insert_at == content.len and insert_at > 0 and content[insert_at - 1] != '\n') {
            new_content.appendSlice(alloc, "\n") catch return false;
        }
        new_content.appendSlice(alloc, "\n  enabled:\n    - seance\n") catch return false;
        new_content.appendSlice(alloc, content[insert_at..]) catch return false;

        backupHermesConfig(alloc, config_path);
        writeAtomicConfig(alloc, config_path, new_content.items) catch return false;
        return true;
    };

    // Find the end of the "enabled:" line
    const line_end = findLineEnd(content, enabled_idx + "enabled:".len);

    // Check if this is an inline list (e.g., "enabled: [a, b]") or a block list
    const after_colon = std.mem.trimLeft(u8, content[enabled_idx + "enabled:".len .. line_end], " ");
    if (after_colon.len > 0 and after_colon[0] != '#' and after_colon[0] != '\n' and after_colon[0] == '[') {
        // Inline list — append to it
        const bracket_pos = std.mem.lastIndexOfScalar(u8, after_colon, ']') orelse {
            std.log.warn("hermes: unterminated inline list in {s}, skipping edit", .{config_path});
            return false;
        };
        const insert_pos = (@intFromPtr(after_colon.ptr) - @intFromPtr(content.ptr)) + bracket_pos;

        // Check if the list is empty: "[]"
        const bracket_offset = @intFromPtr(after_colon.ptr) - @intFromPtr(content.ptr);
        const list_start = bracket_offset + 1; // after '['
        const list_end_abs = insert_pos; // at ']'
        const is_empty = std.mem.eql(u8, std.mem.trim(u8, content[list_start..list_end_abs], " "), "");

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(alloc);
        new_content.appendSlice(alloc, content[0..insert_pos]) catch return false;
        if (is_empty) {
            new_content.appendSlice(alloc, "seance") catch return false;
        } else {
            new_content.appendSlice(alloc, ", seance") catch return false;
        }
        new_content.appendSlice(alloc, content[insert_pos..]) catch return false;

        // Backup user config before mutating
        backupHermesConfig(alloc, config_path);
        writeAtomicConfig(alloc, config_path, new_content.items) catch return false;
    } else {
        // Scalar non-list value (e.g. "enabled: true/null/yes"): bail instead
        // of appending "- seance" to a scalar line, which would corrupt YAML.
        if (after_colon.len > 0) {
            const first = after_colon[0];
            if (first != ' ' and first != '\t' and first != '\n' and first != '\r' and first != '#') {
                std.log.warn("hermes: unexpected scalar value for plugins.enabled in {s}, skipping edit", .{config_path});
                return false;
            }
        }
        // Block list — derive indentation from an existing list item
        var indent: []const u8 = "    "; // default 4-space indent
        // Look for "- " in the next few lines after enabled:
        var line_scan: usize = line_end + 1;
        var lines_checked: u32 = 0;
        while (line_scan < content.len and lines_checked < 10) : (lines_checked += 1) {
            // Find start of line (skip leading whitespace)
            var col: usize = line_scan;
            while (col < content.len and (content[col] == ' ' or content[col] == '\t')) : (col += 1) {}
            // Check if this is a list item
            if (col < content.len and content[col] == '-' and col + 1 < content.len and content[col + 1] == ' ') {
                indent = content[line_scan..col];
                break;
            }
            // Advance to next line
            while (line_scan < content.len and content[line_scan] != '\n') : (line_scan += 1) {}
            if (line_scan < content.len) line_scan += 1;
        }

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(alloc);
        new_content.appendSlice(alloc, content[0..line_end]) catch return false;
        new_content.appendSlice(alloc, "\n") catch return false;
        new_content.appendSlice(alloc, indent) catch return false;
        new_content.appendSlice(alloc, "- seance") catch return false;
        new_content.appendSlice(alloc, content[line_end..]) catch return false;

        // Backup user config before mutating
        backupHermesConfig(alloc, config_path);
        writeAtomicConfig(alloc, config_path, new_content.items) catch return false;
    }
    return true;
}

/// Create a timestamped backup of the Hermes config before mutating it.
/// Preserves source permission bits (e.g. 0600 for files containing API keys).
fn backupHermesConfig(alloc: std.mem.Allocator, config_path: []const u8) void {
    const bak_path = std.fmt.allocPrint(alloc, "{s}.bak", .{config_path}) catch return;
    defer alloc.free(bak_path);
    // Use fstatat with SYMLINK_NOFOLLOW so a symlink at the backup path is
    // actually detected (Dir.statFile / copyFileAbsolute both follow links,
    // making the original check unreachable).
    const bak_stat = std.posix.fstatat(std.fs.cwd().fd, bak_path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return, // doesn't exist yet, safe to proceed
        else => |e| {
            std.log.warn("hermes: failed to stat backup path: {s}", .{@errorName(e)});
            return;
        },
    };
    if ((bak_stat.mode & std.posix.S.IFMT) == std.posix.S.IFLNK) {
        std.log.warn("hermes: backup path is a symlink, refusing to write", .{});
        return;
    }

    const src_file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        std.log.warn("hermes: failed to open config for backup: {s}", .{@errorName(err)});
        return;
    };
    defer src_file.close();
    const content = src_file.readToEndAlloc(alloc, 4 * 1024 * 1024) catch return;
    defer alloc.free(content);

    const orig_stat = std.fs.cwd().statFile(config_path) catch null;
    const mode: std.fs.File.Mode = if (orig_stat) |st| (st.mode & 0o777) else 0o644;
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{bak_path}) catch return;
    defer alloc.free(tmp_path);
    const tmp = std.fs.createFileAbsolute(tmp_path, .{ .mode = mode, .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = tmp.writeAll(content) catch return;
    tmp.close();

    std.fs.renameAbsolute(tmp_path, bak_path) catch |err| {
        std.log.warn("hermes: failed to move backup into place: {s}", .{@errorName(err)});
        std.fs.deleteFileAbsolute(tmp_path) catch {};
    };

    const final_stat = std.fs.cwd().statFile(bak_path) catch return;
    const bak_file = std.fs.openFileAbsolute(bak_path, .{}) catch return;
    defer bak_file.close();
    std.posix.fchmod(bak_file.handle, final_stat.mode & 0o777) catch {};
}

/// Write content to a file atomically using tmp+rename, preserving original permissions.
fn writeAtomicConfig(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    // Stat original to preserve permission bits (e.g. 0600 for secrets)
    const orig_stat = std.fs.cwd().statFile(path) catch null;
    const mode: std.fs.File.Mode = if (orig_stat) |st| (st.mode & 0o777) else 0o666;
    // Use exclusive creation to prevent following an existing symlink at the tmp path
    const tmp = std.fs.createFileAbsolute(tmp_path, .{ .mode = mode, .exclusive = true }) catch return;
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
    _ = tmp.writeAll(data) catch return;
    tmp.close();
    // Verify destination is not a symlink before renaming
    if (std.fs.cwd().statFile(path)) |stat| {
        if (stat.kind == .sym_link) return error.IsSymlink;
    } else |_| {}
    std.fs.renameAbsolute(tmp_path, path) catch return;
}

/// Check if "seance" appears as an actual YAML list item in the plugins.enabled section.
fn isHermesPluginEnabled(content: []const u8) bool {
    const enabled_idx = findPluginsEnabledLine(content) orelse return false;

    // Find the end of the enabled: line
    const line_end = findLineEnd(content, enabled_idx + "enabled:".len);

    // Find section boundary: next non-indented, non-empty, non-comment line
    var section_end = content.len;
    var p = line_end + 1;
    while (p < content.len) {
        var col = p;
        while (col < content.len and (content[col] == ' ' or content[col] == '\t')) : (col += 1) {}
        if (col >= content.len or content[col] == '\n' or content[col] == '#') {
            p = col;
            if (p < content.len) p += 1;
            continue;
        }
        if (col == p) { // non-indented = block end
            section_end = p;
            break;
        }
        while (p < content.len and content[p] != '\n') : (p += 1) {}
        if (p < content.len) p += 1;
    }

    const section = content[enabled_idx..section_end];
    // Block list: "- seance" as a list item
    if (std.mem.indexOf(u8, section, "- seance")) |idx| {
        const after = idx + 8; // len("- seance")
        if (after >= section.len or section[after] == '\n' or section[after] == '\r' or section[after] == ' ' or section[after] == '\t') {
            return true;
        }
    }
    // Inline list: "seance" between delimiters
    if (std.mem.indexOf(u8, section, ", seance")) |_| return true;
    if (std.mem.indexOf(u8, section, "[seance")) |_| return true;
    if (std.mem.indexOf(u8, section, "seance]")) |_| return true;
    return false;
}

/// Remove Hermes plugin and disable it in config.yaml.
pub fn removeHermesPlugin() void {
    const home = std.posix.getenv("HOME") orelse return;
    const alloc = std.heap.page_allocator;

    const config_path = std.fmt.allocPrint(alloc, "{s}/.hermes/config.yaml", .{home}) catch {
        // Config unreadable — still clean up plugin files to avoid orphans
        deletePluginFiles(alloc, home);
        return;
    };
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        // Config.yaml missing — clean up plugin files anyway
        deletePluginFiles(alloc, home);
        return;
    };
    defer file.close();
    const content = file.readToEndAlloc(alloc, 1024 * 1024) catch {
        deletePluginFiles(alloc, home);
        return;
    };
    defer alloc.free(content);

    // Find the plugins.enabled section boundaries
    const enabled_idx = findPluginsEnabledLine(content) orelse {
        // No plugins.enabled found, just delete files
        deletePluginFiles(alloc, home);
        return;
    };

    // Find end of enabled: line
    const line_end = findLineEnd(content, enabled_idx + "enabled:".len);

    // Compute indentation of the "enabled:" key
    var enabled_indent: usize = 0;
    {
        var p = enabled_idx;
        while (p > 0 and content[p - 1] == ' ') : (p -= 1) {}
        enabled_indent = enabled_idx - p;
    }

    // Find the next key at the same or lesser indentation (section boundary).
    // Lines indented deeper than enabled: (or starting with "- ") are part of the section.
    var section_end = content.len;
    var pos = line_end + 1;
    while (pos < content.len) {
        var col = pos;
        while (col < content.len and (content[col] == ' ' or content[col] == '\t')) : (col += 1) {}
        if (col >= content.len or content[col] == '\n' or content[col] == '#') {
            pos = col;
            if (pos < content.len) pos += 1;
            continue;
        }
        const line_indent = col - pos;
        if (line_indent <= enabled_indent) {
            section_end = pos;
            break;
        }
        while (pos < content.len and content[pos] != '\n') : (pos += 1) {}
        if (pos < content.len) pos += 1;
    }

    // Extract the plugins.enabled section content
    const section = content[enabled_idx..section_end];
    const after_colon = std.mem.trimLeft(u8, section["enabled:".len..], " ");

    if (after_colon.len > 0 and after_colon[0] == '[') {
        // Inline list: remove seance from the list
        if (std.mem.lastIndexOfScalar(u8, after_colon, ']')) |bracket_pos| {
            const list_content = after_colon[1..bracket_pos]; // content between [ ]
            var new_list = std.ArrayList(u8).empty;
            defer new_list.deinit(alloc);

            // Parse comma-separated items and rebuild without seance
            var item_start: usize = 0;
            var found_any = false;
            while (item_start < list_content.len) {
                // Skip leading whitespace
                while (item_start < list_content.len and (list_content[item_start] == ' ' or list_content[item_start] == '\t')) : (item_start += 1) {}
                if (item_start >= list_content.len) break;

                // Find end of item (comma or end)
                var item_end = item_start;
                while (item_end < list_content.len and list_content[item_end] != ',') : (item_end += 1) {}

                const item = std.mem.trim(u8, list_content[item_start..item_end], " ");
                if (!std.mem.eql(u8, item, "seance")) {
                    if (found_any) new_list.appendSlice(alloc, ", ") catch break;
                    new_list.appendSlice(alloc, item) catch break;
                    found_any = true;
                }

                item_start = item_end + 1; // skip comma
            }

            // Rebuild the section with new list
            const abs_offset = @intFromPtr(after_colon.ptr) - @intFromPtr(content.ptr);
            var new_content = std.ArrayList(u8).empty;
            defer new_content.deinit(alloc);
            new_content.appendSlice(alloc, content[0..abs_offset]) catch return;
            new_content.appendSlice(alloc, "[") catch return;
            new_content.appendSlice(alloc, new_list.items) catch return;
            new_content.appendSlice(alloc, "]") catch return;
            new_content.appendSlice(alloc, content[abs_offset + bracket_pos + 1 ..]) catch return;

            // Backup config before mutating
            backupHermesConfig(alloc, config_path);
            writeAtomicConfig(alloc, config_path, new_content.items) catch return;
        }
    } else {
        // Block list: remove exact "- seance" lines (not prefix match)
        var new_content = std.ArrayList(u8).empty;
        defer new_content.deinit(alloc);
        new_content.appendSlice(alloc, content[0..enabled_idx]) catch return;

        // Rebuild without the seance line
        var remaining = section;
        while (remaining.len > 0) {
            // Check if current line is exactly "- seance" (after trimming leading whitespace)
            const trimmed = std.mem.trimLeft(u8, remaining, " \t");
            if (trimmed.len >= 8 and std.mem.eql(u8, trimmed[0..8], "- seance")) {
                // Verify word boundary: next char must be whitespace, newline, or end
                const after_seance = trimmed[8..];
                const is_boundary = after_seance.len == 0 or after_seance[0] == ' ' or after_seance[0] == '\t' or after_seance[0] == '\n' or after_seance[0] == '\r';
                if (is_boundary) {
                    // Skip this line's content
                    while (remaining.len > 0 and remaining[0] != '\n') : (remaining = remaining[1..]) {}
                    // Skip the newline only if the next line is indented (list item or child).
                    // If the next line is non-indented (sibling key), keep the newline to avoid
                    // merging the previous line with the next key.
                    if (remaining.len > 0) {
                        remaining = remaining[1..]; // skip newline
                        if (remaining.len > 0) {
                            const next_col = remaining[0];
                            if (next_col != ' ' and next_col != '\t' and next_col != '\n' and next_col != '#') {
                                // Next line is non-indented sibling — re-insert newline
                                new_content.append(alloc, '\n') catch return;
                            }
                        }
                    }
                    continue;
                }
            }
            // Keep this character
            new_content.appendSlice(alloc, remaining[0..1]) catch return;
            remaining = remaining[1..];
        }
        new_content.appendSlice(alloc, content[section_end..]) catch return;

        // Backup config before mutating
        backupHermesConfig(alloc, config_path);
        writeAtomicConfig(alloc, config_path, new_content.items) catch return;
    }

    // Now delete plugin files (after config edit succeeded)
    deletePluginFiles(alloc, home);
}

fn deletePluginFiles(alloc: std.mem.Allocator, home: []const u8) void {
    // Delete plugin directory
    const plugin_dir = std.fmt.allocPrint(alloc, "{s}/.hermes/plugins/seance", .{home}) catch return;
    defer alloc.free(plugin_dir);
    // Verify directory is not a symlink before recursive deletion
    if (std.fs.cwd().statFile(plugin_dir)) |stat| {
        if (stat.kind == .sym_link) {
            std.log.warn("hermes: plugin dir is a symlink, refusing to delete", .{});
            return;
        }
    } else |_| {}
    std.fs.deleteTreeAbsolute(plugin_dir) catch |err| {
        if (err != error.FileNotFound) std.log.warn("hermes: failed to remove plugin dir: {s}", .{@errorName(err)});
    };

    // Remove version marker
    const hermes_dir = std.fmt.allocPrint(alloc, "{s}/.hermes", .{home}) catch return;
    defer alloc.free(hermes_dir);
    const marker_path = std.fmt.allocPrint(alloc, "{s}/.seance-version", .{hermes_dir}) catch return;
    defer alloc.free(marker_path);
    std.fs.deleteFileAbsolute(marker_path) catch {};
}

/// Find the first occurrence of `needle` at the start of a line in `content`.
fn findLineStart(content: []const u8, needle: []const u8) ?usize {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, content[pos..], needle)) |offset| {
        const idx = pos + offset;
        if (idx == 0 or content[idx - 1] == '\n') return idx;
        pos = idx + 1;
    }
    return null;
}

/// Find the end of a line starting from the given position.
fn findLineEnd(content: []const u8, start: usize) usize {
    var end = start;
    while (end < content.len and content[end] != '\n') : (end += 1) {}
    return end;
}

/// Sync a plugin's on-disk state with the given enabled flag.
pub fn syncPlugin(agent: PluginAgent, enabled: bool) void {
    if (enabled) {
        switch (agent) {
            .opencode => installOpenCodePlugin(),
            .kilo => installKiloPlugin(),
            .mimocode => installMimocodePlugin(),
            .vibe => installVibeHooks(),
            .hermes => installHermesPlugin(),
        }
    } else {
        switch (agent) {
            .opencode => removeOpenCodePlugin(),
            .kilo => removeKiloPlugin(),
            .mimocode => removeMimocodePlugin(),
            .vibe => removeVibeHooks(),
            .hermes => removeHermesPlugin(),
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

    const app = c.adw_application_new("com.seance-fork.app", c.G_APPLICATION_DEFAULT_FLAGS);
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
        syncPlugin(.hermes, config_mod.get().hermes_hooks);

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
