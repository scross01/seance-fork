//! Owned atomic replacement for installer-managed plugin files.
//!
//! One uniquely named exclusive temporary file lives next to the target,
//! is closed exactly once, and is removed only by the call that created it.
//! A failed write therefore never leaves a fixed temp name behind that would
//! block the next retry, and a pre-existing entry at the temp path is treated
//! as someone else's and left untouched.
const std = @import("std");
const io = @import("io.zig");

pub const FailAt = enum {
    none,
    /// Fail after writing part of the temporary file.
    write,
    /// Fail with a complete temporary file, before the rename.
    rename,
};

pub const Options = struct {
    /// Test seam for deterministic failure injection.
    fail_at: FailAt = .none,
    /// Test seam: use this exact temp path so a test can pre-create a foreign
    /// collision. Production always derives a unique path.
    tmp_path: ?[]const u8 = null,
};

var tmp_counter: std.atomic.Value(u64) = .init(0);

/// Replace `path` with `data` atomically. A symlink destination is refused so
/// the write cannot be routed through a link the user controls. Any failure
/// removes only the temp file this call created.
pub fn install(path: []const u8, data: []const u8, opts: Options) !void {
    const io_ = io.get();

    const existing = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |st| {
        if (st.kind == .sym_link) return error.SymlinkNotAllowed;
    }

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = opts.tmp_path orelse std.fmt.bufPrint(
        &tmp_buf,
        "{s}.seance-{d}-{d}.tmp",
        .{ path, io.milliTimestamp(), tmp_counter.fetchAdd(1, .monotonic) },
    ) catch return error.NameTooLong;

    const tmp = std.Io.Dir.createFileAbsolute(io_, tmp_path, .{ .exclusive = true }) catch |err| return err;
    // Close exactly once through the defer: success renames the still-open
    // file, failure deletes it; a second close could hit a recycled handle.
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
    // Flush before the rename: without this the rename can reach the journal
    // while the data blocks are still dirty, so a power loss would expose an
    // intact directory entry pointing at a truncated file.
    try tmp.sync(io_);
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

fn readSmall(path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(io.get(), path, .{});
    defer file.close(io.get());
    const n = try io.readAll(file, buf);
    return buf[0..n];
}

fn countOwnedTemps(tmp: *testing.TmpDir) !usize {
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".seance-") != null) count += 1;
    }
    return count;
}

fn countOpenDescriptors() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io.get(), "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io.get());
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io.get())) |_| count += 1;
    return count;
}

test "install writes bytes and leaves no owned temp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);

    try install(path, "bundled content\n", .{});

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("bundled content\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "install replaces an existing regular file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "plugin.ts", .data = "old\n" });

    try install(path, "new\n", .{});

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "install refuses a symlink destination" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "target.ts", .data = "target\n" });
    try tmp.dir.symLink(io.get(), "target.ts", "plugin.ts", .{});

    try testing.expectError(error.SymlinkNotAllowed, install(path, "evil\n", .{}));

    var buf: [256]u8 = undefined;
    const target = try absPath(&tmp, "target.ts", &path_buf);
    try testing.expectEqualStrings("target\n", try readSmall(target, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "install write failure removes its temp and retry succeeds" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);

    try testing.expectError(error.WriteFailed, install(path, "new content\n", .{ .fail_at = .write }));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));

    // The retry is not blocked by a leftover fixed temp name.
    try install(path, "new content\n", .{});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new content\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "install rename failure removes its temp and retry succeeds" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);

    try testing.expectError(error.RenameFailed, install(path, "new\n", .{ .fail_at = .rename }));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));

    try install(path, "new\n", .{});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "install leaves a foreign temp collision untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const collision = try absPath(&tmp, "plugin.ts.seance-1-1.tmp", &tmp_path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "plugin.ts.seance-1-1.tmp", .data = "foreign\n" });

    try testing.expectError(error.PathAlreadyExists, install(path, "new\n", .{ .tmp_path = collision }));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("foreign\n", try readSmall(collision, &buf));
    // The live destination was never created by the failed call.
    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io.get(), path, .{}));
}

test "install propagates a real rename failure without leftovers" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);
    try tmp.dir.createDir(io.get(), "plugin.ts", .default_dir);

    const result = install(path, "new\n", .{});
    try testing.expect(std.meta.isError(result));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));

    // Removing the obstruction lets the same target install.
    try tmp.dir.deleteDir(io.get(), "plugin.ts");
    try install(path, "new\n", .{});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new\n", try readSmall(path, &buf));
}

test "repeated installs do not grow open descriptors" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "plugin.ts", &path_buf);

    const baseline = try countOpenDescriptors();

    for (0..64) |i| {
        var name_buf: [32]u8 = undefined;
        const content = try std.fmt.bufPrint(&name_buf, "content {d}\n", .{i});
        try install(path, content, .{});
    }

    try testing.expectEqual(baseline, try countOpenDescriptors());
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}
