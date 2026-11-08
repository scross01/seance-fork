//! Narrow filesystem transactions for Command Code's settings.json: a
//! bounded read that tells absence apart from every failure, a generation
//! backup that is complete before the caller may replace anything, and an
//! atomic permission-preserving replace guarded by a source recheck. No JSON
//! editing lives here — callers own the transformation and must not mutate
//! the live file unless these helpers succeed.
const std = @import("std");
const io = @import("io.zig");

/// Settings files above this are refused rather than read into memory. The
/// limit is a product decision, not a test knob: a file that large is not a
/// Command Code settings file and must never be treated as absent.
pub const max_settings_bytes = 1024 * 1024;

pub const FailAt = enum {
    none,
    /// Fail after writing part of the temporary file.
    write,
    /// Fail with a complete temporary file, before the recheck and rename.
    rename,
};

pub const WriteOptions = struct {
    /// Test seam for deterministic failure injection.
    fail_at: FailAt = .none,
    /// Test seam: runs once the temporary file is complete and before the
    /// source recheck, standing in for a writer outside seance.
    mutate_before_recheck: ?*const fn (path: []const u8) void = null,
};

/// Bytes read from the settings file. `text` is null only when the file does
/// not exist; every other failure is returned as an error so a caller can
/// never mistake it for "no settings yet".
pub const Loaded = struct {
    text: ?[]u8,

    pub fn deinit(self: Loaded, alloc: std.mem.Allocator) void {
        if (self.text) |bytes| alloc.free(bytes);
    }
};

var tmp_counter: std.atomic.Value(u64) = .init(0);

pub fn readSettings(alloc: std.mem.Allocator, path: []const u8) !Loaded {
    const io_ = io.get();
    // No-follow stat first: a symlink is refused rather than read through,
    // because a later replace would swap the link for a regular file.
    const st = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = null },
        else => return err,
    };
    switch (st.kind) {
        .file => {},
        .sym_link => return error.SymlinkNotAllowed,
        else => return error.UnexpectedFileKind,
    }

    const file = try std.Io.Dir.openFileAbsolute(io_, path, .{});
    defer file.close(io_);
    return .{ .text = try io.readToEndAlloc(file, alloc, max_settings_bytes) };
}

fn statLive(path: []const u8) !std.Io.File.Stat {
    const st = try std.Io.Dir.cwd().statFile(io.get(), path, .{ .follow_symlinks = false });
    switch (st.kind) {
        .file => {},
        .sym_link => return error.SymlinkNotAllowed,
        else => return error.UnexpectedFileKind,
    }
    return st;
}

/// Preserve the bytes that `writeAtomic` is about to replace.
///
/// `{path}.seance-backup` holds the first original and is never overwritten.
/// When the live file has since moved on to other content, a versioned copy
/// is added beside it: a stale first backup is not proof that the current
/// generation is recoverable. The backup is written and closed before this
/// returns, so a caller that commits afterwards always has the bytes on disk.
pub fn backupGeneration(alloc: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    const io_ = io.get();
    const st = try statLive(path);
    const mode: std.Io.File.Permissions = @enumFromInt(st.permissions.toMode() & 0o777);

    const first_path = try std.fmt.allocPrint(alloc, "{s}.seance-backup", .{path});
    defer alloc.free(first_path);

    var target: []const u8 = first_path;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    const existing = std.Io.Dir.cwd().statFile(io_, first_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |es| switch (es.kind) {
        .sym_link => return error.SymlinkNotAllowed,
        .file => {
            const preserved = try readBounded(alloc, first_path);
            defer alloc.free(preserved);
            // Same generation: the first backup already holds these bytes.
            if (std.mem.eql(u8, preserved, source)) return;
            target = std.fmt.bufPrint(
                &target_buf,
                "{s}.seance-backup-{d}-{d}",
                .{ path, io.milliTimestamp(), tmp_counter.fetchAdd(1, .monotonic) },
            ) catch return error.NameTooLong;
        },
        else => return error.UnexpectedBackupKind,
    };

    const file = std.Io.Dir.createFileAbsolute(io_, target, .{
        .exclusive = true,
        .permissions = mode,
    }) catch |err| return err;
    // Close exactly once, and only ever remove the file this call created.
    var complete = false;
    defer {
        file.close(io_);
        if (!complete) std.Io.Dir.deleteFileAbsolute(io_, target) catch {};
    }
    try file.writeStreamingAll(io_, source);
    // Creation modes pass through the process umask; pin them explicitly.
    try file.setPermissions(io_, mode);
    complete = true;
}

/// Replace `path` with `content` atomically, but only if it still holds
/// `expected` (null means "was absent"). A symlink or non-regular destination
/// is refused. Failure leaves the live file untouched and removes only the
/// temp file this call created.
pub fn writeAtomic(alloc: std.mem.Allocator, path: []const u8, expected: ?[]const u8, content: []const u8, opts: WriteOptions) !void {
    const io_ = io.get();

    const existing = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    // null mode = destination absent: let the process umask decide.
    var mode: ?std.Io.File.Permissions = null;
    if (existing) |st| {
        if (st.kind == .sym_link) return error.SymlinkNotAllowed;
        if (st.kind != .file) return error.UnexpectedFileKind;
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
        try tmp.writeStreamingAll(io_, content[0 .. content.len / 2]);
        return error.WriteFailed;
    }
    try tmp.writeStreamingAll(io_, content);
    if (mode) |m| try tmp.setPermissions(io_, m);
    if (opts.fail_at == .rename) return error.RenameFailed;
    if (opts.mutate_before_recheck) |hook| hook(path);

    // Command Code writes this file itself (`cmd mods add` persists a mod
    // source), so newer bytes mean someone else won the race.
    if (!(try stillMatches(alloc, path, expected))) return error.ConcurrentModification;

    try std.Io.Dir.renameAbsolute(tmp_path, path, io_);
    renamed = true;
}

fn readBounded(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const io_ = io.get();
    const file = try std.Io.Dir.openFileAbsolute(io_, path, .{});
    defer file.close(io_);
    return io.readToEndAlloc(file, alloc, max_settings_bytes);
}

fn stillMatches(alloc: std.mem.Allocator, path: []const u8, expected: ?[]const u8) !bool {
    const current = try readSettings(alloc, path);
    defer current.deinit(alloc);
    const have = current.text orelse return expected == null;
    const want = expected orelse return false;
    return std.mem.eql(u8, want, have);
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

fn writeFile(tmp: *testing.TmpDir, name: []const u8, data: []const u8, mode: ?u32) !void {
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
        if (std.mem.indexOf(u8, entry.name, ".seance-") != null and
            std.mem.endsWith(u8, entry.name, ".tmp")) count += 1;
    }
    return count;
}

fn countVersionedBackups(tmp: *testing.TmpDir) !usize {
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "settings.json.seance-backup-")) count += 1;
    }
    return count;
}

test "readSettings reports an absent file as absence" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);

    const loaded = try readSettings(testing.allocator, path);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), loaded.text);
}

test "readSettings returns the exact bytes on disk" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"model\":\"m\"}\n", 0o600);

    const loaded = try readSettings(testing.allocator, path);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"model\":\"m\"}\n", loaded.text.?);
}

test "readSettings rejects a file over the size limit instead of returning absence" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    const big = try testing.allocator.alloc(u8, max_settings_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try writeFile(&tmp, "settings.json", big, null);

    try testing.expectError(error.StreamTooLong, readSettings(testing.allocator, path));
    // Still present and unchanged: a refusal never rewrites the source.
    try testing.expectEqual(@as(usize, max_settings_bytes + 1), (try std.Io.Dir.cwd().statFile(io.get(), path, .{})).size);
}

test "readSettings refuses a symlink and a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "target.json", "{\"a\":1}\n", null);
    try tmp.dir.symLink(io.get(), "target.json", "settings.json", .{});

    try testing.expectError(error.SymlinkNotAllowed, readSettings(testing.allocator, link));

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(&tmp, "as-dir.json", &dir_buf);
    try tmp.dir.createDir(io.get(), "as-dir.json", .default_dir);
    try testing.expectError(error.UnexpectedFileKind, readSettings(testing.allocator, dir_path));
}

test "readSettings treats a missing parent as absence but propagates ENOTDIR" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Nothing can exist at that path, so the settings file is absent.
    const missing = try absPath(&tmp, "missing/settings.json", &path_buf);
    const loaded = try readSettings(testing.allocator, missing);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), loaded.text);

    // A regular file where a directory is required is a real failure, not absence.
    try writeFile(&tmp, "blocker", "x", null);
    var blocked_buf: [std.fs.max_path_bytes]u8 = undefined;
    const blocked = try absPath(&tmp, "blocker/settings.json", &blocked_buf);
    try testing.expectError(error.NotDir, readSettings(testing.allocator, blocked));
}

test "backupGeneration creates the first backup with bytes and mode" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"original\":true}\n", 0o600);

    try backupGeneration(testing.allocator, path, "{\"original\":true}\n");

    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak_path = try std.fmt.bufPrint(&bak_buf, "{s}.seance-backup", .{path});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"original\":true}\n", try readSmall(bak_path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(bak_path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "backupGeneration keeps the first original and versions a later generation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"generation\":2}\n", 0o600);
    try writeFile(&tmp, "settings.json.seance-backup", "{\"generation\":1}\n", 0o600);

    try backupGeneration(testing.allocator, path, "{\"generation\":2}\n");

    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak_path = try std.fmt.bufPrint(&bak_buf, "{s}.seance-backup", .{path});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"generation\":1}\n", try readSmall(bak_path, &buf));
    try testing.expectEqual(@as(usize, 1), try countVersionedBackups(&tmp));
}

test "backupGeneration adds nothing when the first backup already holds these bytes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"same\":true}\n", 0o600);
    try writeFile(&tmp, "settings.json.seance-backup", "{\"same\":true}\n", 0o600);

    try backupGeneration(testing.allocator, path, "{\"same\":true}\n");

    try testing.expectEqual(@as(usize, 0), try countVersionedBackups(&tmp));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "backupGeneration refuses symlink and directory backup paths" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{}\n", null);
    try writeFile(&tmp, "elsewhere", "not a backup\n", null);
    try tmp.dir.symLink(io.get(), "elsewhere", "settings.json.seance-backup", .{});

    try testing.expectError(error.SymlinkNotAllowed, backupGeneration(testing.allocator, path, "{}\n"));

    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other = try absPath(&tmp, "other.json", &other_buf);
    try writeFile(&tmp, "other.json", "{}\n", null);
    try tmp.dir.createDir(io.get(), "other.json.seance-backup", .default_dir);
    try testing.expectError(error.UnexpectedBackupKind, backupGeneration(testing.allocator, other, "{}\n"));
}

test "backupGeneration fails on a missing live file without leaving anything" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "absent.json", &path_buf);

    try testing.expectError(error.FileNotFound, backupGeneration(testing.allocator, path, "{}\n"));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
    try testing.expectEqual(@as(usize, 0), try countVersionedBackups(&tmp));
}

test "writeAtomic replaces content and preserves permission bits" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"old\":1}\n", 0o600);

    try writeAtomic(testing.allocator, path, "{\"old\":1}\n", "{\"new\":1}\n", .{});

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"new\":1}\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "writeAtomic creates a file that was absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);

    try writeAtomic(testing.allocator, path, null, "{}\n", .{});

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{}\n", try readSmall(path, &buf));
}

test "writeAtomic refuses a symlink destination" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "target.json", "{\"target\":1}\n", null);
    try tmp.dir.symLink(io.get(), "target.json", "settings.json", .{});

    try testing.expectError(error.SymlinkNotAllowed, writeAtomic(testing.allocator, path, "{\"target\":1}\n", "{}\n", .{}));

    var buf: [256]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try absPath(&tmp, "target.json", &target_buf);
    try testing.expectEqualStrings("{\"target\":1}\n", try readSmall(target, &buf));
}

test "writeAtomic failures keep the original and remove their temp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"old\":1}\n", 0o600);

    try testing.expectError(error.WriteFailed, writeAtomic(testing.allocator, path, "{\"old\":1}\n", "{\"new\":1}\n", .{ .fail_at = .write }));
    try testing.expectError(error.RenameFailed, writeAtomic(testing.allocator, path, "{\"old\":1}\n", "{\"new\":1}\n", .{ .fail_at = .rename }));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"old\":1}\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

fn overwriteWithOutsideEdit(path: []const u8) void {
    const file = std.Io.Dir.createFileAbsolute(io.get(), path, .{ .truncate = true }) catch return;
    defer file.close(io.get());
    file.writeStreamingAll(io.get(), "{\"outside\":\"edit\"}\n") catch {};
}

test "writeAtomic refuses to clobber an outside edit detected before the rename" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);
    try writeFile(&tmp, "settings.json", "{\"old\":1}\n", 0o600);

    try testing.expectError(error.ConcurrentModification, writeAtomic(
        testing.allocator,
        path,
        "{\"old\":1}\n",
        "{\"new\":1}\n",
        .{ .mutate_before_recheck = overwriteWithOutsideEdit },
    ));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"outside\":\"edit\"}\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

fn createWithOutsideEdit(path: []const u8) void {
    const file = std.Io.Dir.createFileAbsolute(io.get(), path, .{ .exclusive = true }) catch return;
    defer file.close(io.get());
    file.writeStreamingAll(io.get(), "{\"outside\":\"created\"}\n") catch {};
}

test "writeAtomic refuses to replace a file that appeared while it prepared the write" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.json", &path_buf);

    try testing.expectError(error.ConcurrentModification, writeAtomic(
        testing.allocator,
        path,
        null,
        "{}\n",
        .{ .mutate_before_recheck = createWithOutsideEdit },
    ));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"outside\":\"created\"}\n", try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}
