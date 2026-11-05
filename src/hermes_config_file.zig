//! Narrow filesystem transactions for the Hermes config: a one-time
//! original backup and an atomic permission-preserving replace. No YAML
//! editing lives here — callers own content transformation and must not
//! mutate the live file unless these helpers succeed.
const std = @import("std");
const io = @import("io.zig");

pub const FailAt = enum {
    none,
    /// Fail after writing part of the temporary file.
    write,
    /// Fail with a complete temporary file, before the rename.
    rename,
};

pub const WriteOptions = struct {
    /// Test seam for deterministic failure injection.
    fail_at: FailAt = .none,
};

var tmp_counter: std.atomic.Value(u64) = .init(0);

/// Create `{path}.bak` once from the current bytes of `path`. An existing
/// regular backup is the original copy and is never overwritten; symlinks
/// and other non-regular entries at the backup path are refused. The
/// backup carries the source file's permission bits (e.g. 0600 for files
/// containing secrets). Any failure returns an error so callers can abort
/// before mutating the live config.
pub fn backupOriginal(path: []const u8, alloc: std.mem.Allocator) !void {
    const io_ = io.get();
    const bak_path = try std.fmt.allocPrint(alloc, "{s}.bak", .{path});
    defer alloc.free(bak_path);

    // No-follow stat: a symlink at the backup path must never be written
    // through, and a directory is not a backup.
    const existing = std.Io.Dir.cwd().statFile(io_, bak_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null, // no backup yet: create the first one
        else => return err,
    };
    if (existing) |st| {
        switch (st.kind) {
            .file => return, // original already backed up: keep it
            .sym_link => return error.SymlinkNotAllowed,
            else => return error.UnexpectedBackupKind,
        }
    }

    const src = std.Io.Dir.openFileAbsolute(io_, path, .{}) catch |err| return err;
    defer src.close(io_);
    const content = try io.readToEndAlloc(src, alloc, 4 * 1024 * 1024);
    defer alloc.free(content);
    const src_stat = try src.stat(io_);
    const mode: std.Io.File.Permissions = @enumFromInt(src_stat.permissions.toMode() & 0o777);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &tmp_buf,
        "{s}.seance-{d}-{d}.tmp",
        .{ bak_path, io.milliTimestamp(), tmp_counter.fetchAdd(1, .monotonic) },
    ) catch return error.NameTooLong;

    const tmp = std.Io.Dir.createFileAbsolute(io_, tmp_path, .{
        .exclusive = true,
        .permissions = mode,
    }) catch |err| return err;
    // Close exactly once through the defer; only our own uniquely named
    // temp is ever removed on failure.
    var renamed = false;
    defer {
        tmp.close(io_);
        if (!renamed) std.Io.Dir.deleteFileAbsolute(io_, tmp_path) catch {};
    }

    try tmp.writeStreamingAll(io_, content);
    // Creation modes pass through the process umask; pin them explicitly.
    try tmp.setPermissions(io_, mode);
    try std.Io.Dir.renameAbsolute(tmp_path, bak_path, io_);
    renamed = true;
}

/// Replace `path` with `data` atomically: a uniquely named exclusive
/// temporary file in the same directory, permission-preserving write, one
/// close, then rename. A symlink destination is refused so replacement
/// cannot write through a link the user controls. Any failure leaves the
/// live file untouched and removes only the temp file this call created.
pub fn writeAtomic(path: []const u8, data: []const u8, opts: WriteOptions) !void {
    const io_ = io.get();

    const existing = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    // null mode = destination absent: let the process umask decide.
    var mode: ?std.Io.File.Permissions = null;
    if (existing) |st| {
        if (st.kind == .sym_link) return error.SymlinkNotAllowed;
        mode = @enumFromInt(st.permissions.toMode() & 0o777);
    }

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &tmp_buf,
        "{s}.seance-{d}-{d}.tmp",
        .{ path, io.milliTimestamp(), tmp_counter.fetchAdd(1, .monotonic) },
    ) catch return error.NameTooLong;

    const tmp = std.Io.Dir.createFileAbsolute(io_, tmp_path, .{
        .exclusive = true,
        .permissions = mode orelse .default_file,
    }) catch |err| return err;
    var renamed = false;
    defer {
        tmp.close(io_);
        if (!renamed) std.Io.Dir.deleteFileAbsolute(io_, tmp_path) catch {};
    }

    if (opts.fail_at == .write) {
        // Partial write, then failure: the live file must stay intact.
        try tmp.writeStreamingAll(io_, data[0 .. data.len / 2]);
        return error.WriteFailed;
    }
    try tmp.writeStreamingAll(io_, data);
    if (mode) |m| try tmp.setPermissions(io_, m);
    if (opts.fail_at == .rename) return error.RenameFailed;
    try std.Io.Dir.renameAbsolute(tmp_path, path, io_);
    renamed = true;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn absPath(tmp: *const testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    var fd_buf: [64]u8 = undefined;
    const fd_path = try std.fmt.bufPrint(&fd_buf, "/proc/self/fd/{d}", .{tmp.dir.handle});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try std.Io.Dir.readLinkAbsolute(io.get(), fd_path, &dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir_buf[0..dir_len], name });
}

fn writeConfig(tmp: *testing.TmpDir, name: []const u8, data: []const u8, mode: ?u32) !void {
    const file = try tmp.dir.createFile(io.get(), name, .{});
    defer file.close(io.get());
    try file.writeStreamingAll(io.get(), data);
    if (mode) |m| try file.setPermissions(io.get(), std.Io.File.Permissions.fromMode(m));
}

fn readSmall(path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(io.get(), path, .{});
    defer file.close(io.get());
    const n = try io.readAll(file, buf);
    return buf[0..n];
}

fn fileMode(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(io.get(), path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

fn countOwnedTemps(tmp: *testing.TmpDir) !usize {
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".seance-") != null) count += 1;
    }
    return count;
}

test "backupOriginal creates the first backup with bytes and mode" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "original: true\n", 0o600);

    try backupOriginal(path, testing.allocator);

    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak_path = try std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("original: true\n", try readSmall(bak_path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(bak_path));
}

test "backupOriginal keeps an existing original backup" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "mutated: true\n", 0o600);
    try writeConfig(&tmp, "config.yaml.bak", "FIRST original\n", 0o600);

    try backupOriginal(path, testing.allocator);

    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak_path = try std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("FIRST original\n", try readSmall(bak_path, &buf));
}

test "backupOriginal refuses a symlink backup path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "live\n", null);
    try writeConfig(&tmp, "target.yaml", "target\n", null);
    try tmp.dir.symLink(io.get(), "target.yaml", "config.yaml.bak", .{});

    try testing.expectError(error.SymlinkNotAllowed, backupOriginal(path, testing.allocator));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("target\n", try readSmall(try absPath(&tmp, "target.yaml", &path_buf), &buf));
}

test "backupOriginal refuses a directory backup path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "live\n", null);
    try tmp.dir.createDir(io.get(), "config.yaml.bak", .default_dir);

    try testing.expectError(error.UnexpectedBackupKind, backupOriginal(path, testing.allocator));
}

test "backupOriginal fails when the config is missing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "absent.yaml", &path_buf);

    try testing.expectError(error.FileNotFound, backupOriginal(path, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "backupOriginal leaves foreign temp files alone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "live\n", null);
    try writeConfig(&tmp, "config.yaml.bak.stale.tmp", "not ours\n", null);

    try backupOriginal(path, testing.allocator);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("not ours\n", try readSmall(try absPath(&tmp, "config.yaml.bak.stale.tmp", &path_buf), &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic preserves permission bits" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "old\n", 0o600);

    try writeAtomic(path, "new content\n", .{});

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new content\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic refuses a symlink destination" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "target.yaml", "target\n", null);
    try tmp.dir.symLink(io.get(), "target.yaml", "config.yaml", .{});

    try testing.expectError(error.SymlinkNotAllowed, writeAtomic(path, "evil\n", .{}));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("target\n", try readSmall(try absPath(&tmp, "target.yaml", &path_buf), &buf));
}

test "writeAtomic rename failure keeps the original and removes its temp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "old\n", 0o600);

    try testing.expectError(error.RenameFailed, writeAtomic(path, "new content\n", .{ .fail_at = .rename }));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("old\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic propagates filesystem rename failures without leftovers" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    // Destination is a directory: the rename itself fails.
    try tmp.dir.createDir(io.get(), "config.yaml", .default_dir);

    const result = writeAtomic(path, "new\n", .{});
    try testing.expect(std.meta.isError(result));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic write failure leaves the original bytes intact" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "config.yaml", &path_buf);
    try writeConfig(&tmp, "config.yaml", "old\n", 0o600);

    try testing.expectError(error.WriteFailed, writeAtomic(path, "new content\n", .{ .fail_at = .write }));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("old\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic propagates create failures" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "missing-dir/config.yaml", &path_buf);

    try testing.expectError(error.FileNotFound, writeAtomic(path, "x\n", .{}));
}
