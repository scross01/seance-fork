const std = @import("std");
const io = @import("io.zig");

const gitdir_prefix = "gitdir: ";

/// Read the current git branch from a working directory by walking up
/// to find .git (directory or gitdir file). Returns the branch name, short
/// SHA for detached HEAD, or null if not in a git repo.
pub fn getBranch(buf: []u8, cwd: []const u8) ?[]const u8 {
    var dir: []const u8 = cwd;

    while (true) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const dot_git = std.fmt.bufPrint(&path_buf, "{s}/.git", .{dir}) catch return null;

        // Try .git as a directory first.
        if (std.Io.Dir.openDirAbsolute(io.get(), dot_git, .{})) |d| {
            d.close(io.get());
            const head_path = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir}) catch return null;
            return parseHead(buf, head_path);
        } else |_| {}

        // Try .git as a file (worktree/submodule gitdir pointer).
        var pointer_buf: [4096]u8 = undefined;
        const git_file = std.Io.Dir.openFileAbsolute(io.get(), dot_git, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                // No .git entry here; walk up.
                const parent = std.fs.path.dirname(dir) orelse return null;
                if (std.mem.eql(u8, parent, dir)) return null;
                dir = parent;
                continue;
            },
            else => return null,
        };
        defer git_file.close(io.get());
        const n = git_file.readStreaming(io.get(), &.{&pointer_buf}) catch return null;
        if (n == 0) return null; // malformed boundary
        const content = pointer_buf[0..n];
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, gitdir_prefix)) {
            const raw = std.mem.trim(u8, trimmed[gitdir_prefix.len..], " \t\r\n");
            // Resolve relative to the directory containing .git.
            var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const git_dir = if (std.fs.path.isAbsolute(raw))
                raw
            else blk: {
                const parent = std.fs.path.dirname(dot_git) orelse return null;
                break :blk std.fmt.bufPrint(&git_dir_buf, "{s}/{s}", .{ parent, raw }) catch return null;
            };
            var head_buf: [std.fs.max_path_bytes]u8 = undefined;
            const head_path = std.fmt.bufPrint(&head_buf, "{s}/HEAD", .{git_dir}) catch return null;
            return parseHead(buf, head_path);
        }
        // A .git entry exists but is not a valid pointer: repository boundary.
        return null;
    }
}

fn parseHead(buf: []u8, head_path: []const u8) ?[]const u8 {
    const content = readFileContent(head_path, buf) orelse return null;
    const trimmed = std.mem.trimEnd(u8, content, "\n\r ");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const branch = trimmed[prefix.len..];
        if (branch.len > buf.len) return null;
        std.mem.copyForwards(u8, buf[0..branch.len], branch);
        return buf[0..branch.len];
    }
    // Detached HEAD — return short SHA.
    const n = @min(trimmed.len, 7);
    if (n == 0) return null;
    std.mem.copyForwards(u8, buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

/// Check if a git repo at `cwd` has uncommitted changes (staged or unstaged).
/// Uses `git diff-index --quiet HEAD --` which is a fast plumbing command.
/// Returns true if dirty, false if clean or on any error.
pub fn isDirty(alloc: std.mem.Allocator, cwd: []const u8) bool {
    const result = std.process.run(alloc, io.get(), .{
        .argv = &[_][]const u8{ "git", "-C", cwd, "diff-index", "--quiet", "HEAD", "--" },
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code != 0,
        else => false,
    };
}

fn readFileContent(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io.get(), path, .{}) catch return null;
    defer file.close(io.get());
    const n = file.readStreaming(io.get(), &.{buf}) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

fn readFileSlice(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io.get(), path, .{}) catch return null;
    defer file.close(io.get());
    const n = file.readStreaming(io.get(), &.{buf}) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

test "getBranch reads .git directory HEAD" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io.get(), "repo/.git");
    var f = try tmp.dir.createFile(io.get(), "repo/.git/HEAD", .{});
    try f.writeStreamingAll(io.get(), "ref: refs/heads/main\n");
    f.close(io.get());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io.get(), &path_buf);
    const base = path_buf[0..n];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/repo", .{base});

    var buf: [128]u8 = undefined;
    const branch = getBranch(&buf, cwd);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("main", branch.?);
}

test "getBranch resolves relative gitdir file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io.get(), "real/.git");
    var f = try tmp.dir.createFile(io.get(), "real/.git/HEAD", .{});
    try f.writeStreamingAll(io.get(), "ref: refs/heads/worktree-branch\n");
    f.close(io.get());

    try tmp.dir.createDirPath(io.get(), "worktree");
    var wf = try tmp.dir.createFile(io.get(), "worktree/.git", .{});
    try wf.writeStreamingAll(io.get(), "gitdir: ../real/.git\n");
    wf.close(io.get());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io.get(), &path_buf);
    const base = path_buf[0..n];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/worktree", .{base});

    var buf: [128]u8 = undefined;
    const branch = getBranch(&buf, cwd);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("worktree-branch", branch.?);
}

test "getBranch does not fall through malformed inner .git" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io.get(), "outer/.git");
    var of = try tmp.dir.createFile(io.get(), "outer/.git/HEAD", .{});
    try of.writeStreamingAll(io.get(), "ref: refs/heads/outer-branch\n");
    of.close(io.get());

    try tmp.dir.createDirPath(io.get(), "outer/inner");
    var mf = try tmp.dir.createFile(io.get(), "outer/inner/.git", .{});
    try mf.writeStreamingAll(io.get(), "not a gitdir pointer\n");
    mf.close(io.get());

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io.get(), &path_buf);
    const base = path_buf[0..n];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/outer/inner", .{base});

    var buf: [128]u8 = undefined;
    const branch = getBranch(&buf, cwd);
    try testing.expect(branch == null);
}
