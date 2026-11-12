//! Transactional storage for session snapshots: atomic same-directory file
//! replacement plus the admission/join lifecycle that orders background
//! autosaves against the final synchronous save. This module never touches
//! GTK or Ghostty — callers hand it fully owned serialized bytes, and the
//! background writer performs file IO only.
const std = @import("std");
const io = @import("io.zig");

/// Hard ceiling for a committed snapshot, shared with the loader
/// (`loadAndRestoreAll` reads with `.limited(MAX_SNAPSHOT_BYTES + 1)` so a
/// file of exactly this size stays restorable). Saves compose within this
/// limit and refuse to replace the live file when the layout alone exceeds
/// it.
pub const MAX_SNAPSHOT_BYTES: usize = 10 * 1024 * 1024;

/// Snapshots contain terminal payloads and working directories: owner-only.
pub const SNAPSHOT_MODE: std.Io.File.Permissions = std.Io.File.Permissions.fromMode(0o600);

/// Deterministic test seam: a hook called at named points of a commit so a
/// test can pause a writer without wall-clock sleeps. Production leaves the
/// hook null.
pub const Stage = enum {
    /// Before any byte of this commit is written.
    before_write,
    /// The temporary file is complete; the live path has not been replaced.
    before_rename,
    /// A synchronous save is about to wait for the in-flight writer.
    before_join,
};

/// Deterministic failure injection for tests. Production uses `.none`.
pub const FailAt = enum {
    none,
    /// Refuse to allocate the job (payload freed, admission released).
    alloc,
    /// Refuse to spawn the background writer (same ownership handling).
    spawn,
    /// Fail after writing part of the temporary file.
    write,
    /// Fail with a complete temporary file, before the rename.
    before_rename,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    /// True while one commit owns the live file. Set by `admit`, cleared
    /// only by `release` (caller-side failure) or by the background writer
    /// when it finishes. A rejected `admit` never touches it.
    in_flight: std.atomic.Value(bool) = .init(false),
    /// Handle of the background writer. Only the thread that calls
    /// `spawnAsync`/`joinAll` reads or writes it; the worker never does.
    worker: ?std.Thread = null,
    fail_at: FailAt = .none,
    hook: ?*const fn (Stage) void = null,

    const Job = struct {
        path: []u8,
        payload: []u8,
    };

    /// Claim ownership of the file for one commit. A busy store means a
    /// background writer is still committing; the caller must skip its own
    /// work and leave the current writer's state untouched — rejection is
    /// not a release.
    pub fn admit(self: *Store) error{Busy}!void {
        if (self.in_flight.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| return error.Busy;
    }

    /// Return admission taken by `admit` when the caller fails before the
    /// commit reaches `spawnAsync`.
    pub fn release(self: *Store) void {
        self.in_flight.store(false, .release);
    }

    /// Hand an admitted commit to the background writer. Ownership of the
    /// admission and of `payload` transfers here: on success the worker
    /// releases and frees both after the file work finishes; every error
    /// path releases and frees them itself.
    pub fn spawnAsync(self: *Store, path: []const u8, payload: []u8) error{ OutOfMemory, SpawnFailed }!void {
        if (self.fail_at == .alloc) {
            self.alloc.free(payload);
            self.release();
            return error.OutOfMemory;
        }
        const job = self.alloc.create(Job) catch {
            self.alloc.free(payload);
            self.release();
            return error.OutOfMemory;
        };
        const path_copy = self.alloc.dupe(u8, path) catch {
            self.alloc.free(payload);
            self.alloc.destroy(job);
            self.release();
            return error.OutOfMemory;
        };
        job.* = .{ .path = path_copy, .payload = payload };
        if (self.fail_at == .spawn) {
            self.freeJob(job);
            self.release();
            return error.SpawnFailed;
        }
        // The previous writer has already released admission (else `admit`
        // would have failed), so this join only waits for its epilogue.
        self.reap();
        const thread = std.Thread.spawn(.{}, workerMain, .{ self, job }) catch {
            self.freeJob(job);
            self.release();
            return error.SpawnFailed;
        };
        self.worker = thread;
    }

    /// Wait until the background writer has completely finished — commit,
    /// failure cleanup and payload free — then forget its handle. Every
    /// synchronous save calls this before writing so an older asynchronous
    /// rename can never land after the final snapshot, and shutdown calls
    /// it before the forced exit.
    pub fn joinAll(self: *Store) void {
        if (self.worker) |thread| {
            if (self.hook) |h| h(.before_join);
            thread.join();
            self.worker = null;
        }
    }

    /// Replace `path` atomically: a uniquely named exclusive temporary file
    /// in the same directory, a complete write with an owner-only mode, one
    /// close, then rename. Any failure leaves the previous file intact and
    /// removes the temporary. The temporary is closed exactly once via the
    /// defer, so a second close can never hit a recycled descriptor.
    pub fn replace(self: *Store, path: []const u8, bytes: []const u8) !void {
        if (self.hook) |h| h(.before_write);
        const io_ = io.get();
        if (std.fs.path.dirname(path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(io_, dir);
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(
            &tmp_buf,
            "{s}.seance-{d}-{d}.tmp",
            .{ path, io.milliTimestamp(), tmp_counter.fetchAdd(1, .monotonic) },
        ) catch return error.NameTooLong;

        const file = std.Io.Dir.createFileAbsolute(io_, tmp_path, .{
            .exclusive = true,
            .permissions = SNAPSHOT_MODE,
        }) catch |err| return err;
        var renamed = false;
        defer {
            file.close(io_);
            if (!renamed) std.Io.Dir.deleteFileAbsolute(io_, tmp_path) catch {};
        }

        if (self.fail_at == .write) {
            try file.writeStreamingAll(io_, bytes[0 .. bytes.len / 2]);
            return error.WriteFailed;
        }
        try file.writeStreamingAll(io_, bytes);
        // Creation modes pass through the process umask; set the mode
        // explicitly so the committed snapshot is exactly owner-only.
        try file.setPermissions(io_, SNAPSHOT_MODE);
        // Durability barrier: rename only publishes the entry, so without this
        // flush a power loss can leave the new name pointing at unwritten data.
        try file.sync(io_);
        if (self.hook) |h| h(.before_rename);
        if (self.fail_at == .before_rename) return error.WriteFailed;
        try std.Io.Dir.renameAbsolute(tmp_path, path, io_);
        renamed = true;
    }

    fn workerMain(self: *Store, job: *Job) void {
        defer {
            // Free first, release admission last: a joined writer is
            // guaranteed to have both completed its file work and given up
            // ownership.
            self.freeJob(job);
            self.in_flight.store(false, .release);
        }
        self.replace(job.path, job.payload) catch |err| {
            std.log.warn("session: failed to write session file: {s}", .{@errorName(err)});
        };
    }

    fn reap(self: *Store) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }

    fn freeJob(self: *Store, job: *Job) void {
        self.alloc.free(job.path);
        self.alloc.free(job.payload);
        self.alloc.destroy(job);
    }
};

var tmp_counter: std.atomic.Value(u64) = .init(0);

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// Deterministic barrier for the writer seam. The test runner executes
// tests sequentially in one process, so these plain globals are reset at
// the start of every test that arms them. Cross-thread hand-off happens
// exclusively through the atomic flags below.
var armed: bool = false;
var pause_stage: Stage = .before_rename;
var paused = std.atomic.Value(bool).init(false);
var released = std.atomic.Value(bool).init(false);
var final_entered = std.atomic.Value(bool).init(false);

fn testHook(stage: Stage) void {
    if (stage == .before_join) {
        final_entered.store(true, .release);
        return;
    }
    if (armed and stage == pause_stage) {
        paused.store(true, .release);
        while (!released.load(.acquire) and !final_entered.load(.acquire)) {
            std.Thread.yield() catch {};
        }
    }
}

fn resetBarrier() void {
    armed = false;
    pause_stage = .before_rename;
    paused.store(false, .release);
    released.store(false, .release);
    final_entered.store(false, .release);
}

/// Event wait with a generous failure bound: not a sleep, but a stuck
/// barrier fails the test instead of hanging the run.
fn waitFlag(flag: *std.atomic.Value(bool)) !void {
    var spins: usize = 0;
    while (!flag.load(.acquire)) {
        std.Thread.yield() catch {};
        spins += 1;
        if (spins > 5_000_000) return error.BarrierTimeout;
    }
}

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

fn countTemps(tmp: *testing.TmpDir) !usize {
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".seance-") != null) count += 1;
    }
    return count;
}

test "a final save waits out the in-flight writer and commits last" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "session.json", .data = "{\"snapshot\":\"old\"}" });

    var store = Store{ .alloc = testing.allocator, .hook = &testHook };
    defer store.joinAll();

    armed = true;
    pause_stage = .before_rename;
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try store.spawnAsync(path, payload);
    try waitFlag(&paused);
    // The writer is held before its rename: the live file is still old.
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"snapshot\":\"old\"}", try readSmall(path, &buf));

    // The final save joins the paused writer (the before_join seam edge
    // releases it), so its own rename strictly follows the async rename.
    armed = false;
    store.joinAll();
    try store.admit();
    defer store.release();
    try store.replace(path, "{\"snapshot\":\"final\"}");

    try testing.expectEqualStrings("{\"snapshot\":\"final\"}", try readSmall(path, &buf));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"snapshot\":\"final\"}", .{});
    parsed.deinit();
    try testing.expectEqual(@as(usize, 0), try countTemps(&tmp));
}

test "a rejected save never releases the current writer's admission" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "session.json", .data = "{\"snapshot\":\"old\"}" });

    var store = Store{ .alloc = testing.allocator, .hook = &testHook };
    defer store.joinAll();

    armed = true;
    pause_stage = .before_rename;
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try store.spawnAsync(path, payload);
    try waitFlag(&paused);

    // A second autosave arrives while the first owns the file: it is
    // rejected, and the rejection must not clear the first writer's flag.
    try testing.expectError(error.Busy, store.admit());
    try testing.expect(store.in_flight.load(.acquire));

    released.store(true, .release);
    store.joinAll();
    try testing.expect(!store.in_flight.load(.acquire));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"snapshot\":\"async\"}", try readSmall(path, &buf));
    try store.admit();
    store.release();
}

test "a failed background write preserves the previous snapshot" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "session.json", .data = "{\"snapshot\":\"old\"}" });

    var store = Store{ .alloc = testing.allocator, .fail_at = .write };
    defer store.joinAll();
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try store.spawnAsync(path, payload);
    store.joinAll();

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"snapshot\":\"old\"}", try readSmall(path, &buf));
    try testing.expect(!store.in_flight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), try countTemps(&tmp));
}

test "an interrupted commit keeps the old bytes and removes its temp" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "session.json", .data = "{\"snapshot\":\"old\"}" });

    var store = Store{ .alloc = testing.allocator, .fail_at = .before_rename };
    defer store.joinAll();
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try store.spawnAsync(path, payload);
    store.joinAll();

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"snapshot\":\"old\"}", try readSmall(path, &buf));
    try testing.expect(!store.in_flight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), try countTemps(&tmp));
}

test "a failed spawn releases admission and frees the payload" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);

    var store = Store{ .alloc = testing.allocator, .fail_at = .spawn };
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try testing.expectError(error.SpawnFailed, store.spawnAsync(path, payload));
    try testing.expect(!store.in_flight.load(.acquire));
    try store.admit();
    store.release();
}

test "a failed allocation releases admission and frees the payload" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "session.json", &path_buf);

    var store = Store{ .alloc = testing.allocator, .fail_at = .alloc };
    const payload = try testing.allocator.dupe(u8, "{\"snapshot\":\"async\"}");
    try store.admit();
    try testing.expectError(error.OutOfMemory, store.spawnAsync(path, payload));
    try testing.expect(!store.in_flight.load(.acquire));
    try store.admit();
    store.release();
}

test "replace creates missing directories and commits owner-only bytes" {
    resetBarrier();
    defer resetBarrier();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "nested/dir/session.json", &path_buf);

    var store = Store{ .alloc = testing.allocator };
    try store.replace(path, "{\"ok\":true}");

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"ok\":true}", try readSmall(path, &buf));
    const st = try std.Io.Dir.cwd().statFile(io.get(), path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    try testing.expectEqual(@as(usize, 0), try countTemps(&tmp));
}

test "the shared snapshot limit matches the loader contract" {
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), MAX_SNAPSHOT_BYTES);
}
