//! Owned temporary files created in a private directory.
//!
//! Ghostty's C API only accepts a filesystem path, so seance must write
//! generated config to disk.  Using a predictable filename in a shared
//! runtime directory lets another process replace or observe the file; this
//! module creates an unpredictable owner-only directory and exclusive
//! owner-only files instead.  The handle owns every pathname it creates and
//! removes only those on cleanup.
const std = @import("std");
const io = @import("io.zig");

pub const max_path = std.fs.max_path_bytes;

pub const OwnedTempFile = struct {
    dir_path: [max_path]u8 = undefined,
    dir_len: usize = 0,
    file_path: [max_path + 1]u8 = undefined,
    file_len: usize = 0,
    file: ?std.Io.File = null,
    owned: bool = false,

    pub fn deinit(self: *OwnedTempFile) void {
        if (self.file) |f| {
            f.close(io.get());
            self.file = null;
        }
        if (self.owned) {
            if (self.file_len > 0) {
                std.Io.Dir.deleteFileAbsolute(io.get(), self.file_path[0..self.file_len]) catch {};
            }
            if (self.dir_len > 0) {
                std.Io.Dir.deleteDirAbsolute(io.get(), self.dir_path[0..self.dir_len]) catch {};
            }
            self.owned = false;
        }
    }

    /// Create an unpredictable owner-only directory under `base_dir`, then an
    /// exclusive 0600 file named `prefix`.  Returns a handle that owns both.
    pub fn create(base_dir: []const u8, prefix: []const u8) !OwnedTempFile {
        var self = OwnedTempFile{};
        // Build a private directory name.  Retry on collision so a stale or
        // hostile entry can never be followed.
        var attempts: u32 = 0;
        while (attempts < 16) : (attempts += 1) {
            const ts = io.timestamp();
            const pid = std.c.getpid();
            const rand_part = @as(u64, @bitCast(ts)) ^ (@as(u64, @intCast(pid)) << 32);
            const dir_name = std.fmt.bufPrint(&self.dir_path, "{s}/seance-private-{x}-{d}", .{ base_dir, rand_part, attempts }) catch return error.PathTooLong;
            self.dir_len = dir_name.len;
            // Ensure null termination not needed for dir; store slice length.
            std.Io.Dir.createDirAbsolute(io.get(), self.dir_path[0..self.dir_len], .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => return e,
            };
            // Restrict to owner-only.
            var dir_z: [max_path + 1]u8 = undefined;
            if (self.dir_len >= dir_z.len) return error.PathTooLong;
            @memcpy(dir_z[0..self.dir_len], self.dir_path[0..self.dir_len]);
            dir_z[self.dir_len] = 0;
            if (std.c.chmod(@ptrCast(dir_z[0..self.dir_len].ptr), 0o700) != 0) {
                std.Io.Dir.deleteDirAbsolute(io.get(), self.dir_path[0..self.dir_len]) catch {};
                continue;
            }
            self.owned = true;
            break;
        }
        if (!self.owned) return error.UnableToCreatePrivateDir;

        // Create exclusive file inside the private directory.
        const file_name = std.fmt.bufPrint(self.file_path[0..], "{s}/{s}", .{ self.dir_path[0..self.dir_len], prefix }) catch return error.PathTooLong;
        // file_path buffer needs null terminator for ghostty; append.
        if (file_name.len >= self.file_path.len) return error.PathTooLong;
        self.file_path[file_name.len] = 0;
        self.file_len = file_name.len;

        const file = std.Io.Dir.createFileAbsolute(io.get(), self.file_path[0..self.file_len], .{
            .read = true,
            .truncate = true,
            .exclusive = true,
        }) catch |e| {
            self.deinit();
            return e;
        };
        // Restrict to 0600.
        posix_fchmod(file.handle, 0o600) catch {};
        self.file = file;
        return self;
    }

    pub fn writeAll(self: *OwnedTempFile, bytes: []const u8) !void {
        const f = self.file orelse return error.FileClosed;
        try f.writeStreamingAll(io.get(), bytes);
    }

    /// Close the file descriptor while keeping the pathname valid.  Required
    /// so ghostty can read the complete contents after writing.
    pub fn closeFile(self: *OwnedTempFile) void {
        if (self.file) |f| {
            f.close(io.get());
            self.file = null;
        }
    }

    pub fn path(self: *const OwnedTempFile) []const u8 {
        return self.file_path[0..self.file_len];
    }

    pub fn pathZ(self: *const OwnedTempFile) [*:0]const u8 {
        return @ptrCast(self.file_path[0..].ptr);
    }
};

fn posix_fchmod(fd: std.Io.File.Handle, mode: u32) !void {
    if (std.c.fchmod(fd, @intCast(mode)) != 0) return error.ChmodFailed;
}

test "OwnedTempFile creates private dir and exclusive 0600 file" {
    var handle = try OwnedTempFile.create("/tmp", "cfg.tmp");
    defer handle.deinit();
    try handle.writeAll("hello");
    handle.closeFile();
    // path should exist
    const f = try std.Io.Dir.openFileAbsolute(io.get(), handle.path(), .{});
    f.close(io.get());
}

test "OwnedTempFile refuses existing path collision" {
    // Creating two handles yields different directories
    var a = try OwnedTempFile.create("/tmp", "cfg.tmp");
    defer a.deinit();
    var b = try OwnedTempFile.create("/tmp", "cfg.tmp");
    defer b.deinit();
    try std.testing.expect(!std.mem.eql(u8, a.path(), b.path()));
}