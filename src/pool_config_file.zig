//! Pool settings preservation: a bounded, format-specific merge of the
//! seance-owned hook handlers into `~/.config/poolside/settings.yaml`, plus
//! the transaction that backs up and atomically replaces the file.
//!
//! The merge is purely textual and refuses anything it cannot transform
//! losslessly (flow mappings, anchors, inline event values, duplicate keys,
//! tab indentation, unbalanced markers). Refusal is non-mutating: callers get
//! `unsupported` and must leave the user's bytes alone. Handlers are owned
//! only when their command invokes `seance ctl pool-hook`, so user handlers and
//! their event keys survive both install and remove.
const std = @import("std");
const io = @import("io.zig");

/// Prefix that identifies a handler as seance-owned.
const owned_command = "seance ctl pool-hook";

pub const Unsupported = enum {
    duplicate_hooks,
    inline_hooks,
    sequence_hooks,
    duplicate_event,
    inline_event,
    ambiguous_event,
    event_mapping,
    tab_indent,
    unbalanced_marker,
};

pub const Outcome = union(enum) {
    /// Nothing changed; no bytes need writing.
    unchanged,
    /// New file content, owned by the caller's allocator.
    updated: []const u8,
    /// Input shape this helper will not rewrite losslessly.
    unsupported: Unsupported,
};

pub const Mode = enum { install, remove };

pub const SyncOutcome = union(enum) {
    unchanged,
    updated,
    unsupported: Unsupported,
    /// Remove mode found no settings file.
    absent,
};

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
};

// ── Line view ──────────────────────────────────────────────────────────────

const Line = struct {
    start: usize,
    body: []const u8, // excludes the trailing newline and `\r`
    has_newline: bool,
};

fn splitLines(alloc: std.mem.Allocator, content: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(alloc);
    var pos: usize = 0;
    while (pos < content.len) {
        const nl = std.mem.indexOfScalar(u8, content[pos..], '\n');
        const end = if (nl) |n| pos + n else content.len;
        var body = content[pos..end];
        if (body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
        try lines.append(alloc, .{ .start = pos, .body = body, .has_newline = nl != null });
        pos = if (nl) |n| pos + n + 1 else content.len;
    }
    return lines.toOwnedSlice(alloc);
}

fn indentOf(body: []const u8) struct { spaces: usize, tab: bool } {
    var i: usize = 0;
    var tab = false;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {
        if (body[i] == '\t') tab = true;
    }
    return .{ .spaces = i, .tab = tab };
}

fn isBlank(body: []const u8) bool {
    for (body) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

fn trimmed(body: []const u8) []const u8 {
    return std.mem.trim(u8, body, " \t");
}

/// Text after a `key:` separator, ignoring a trailing YAML comment.
/// Returns null when the value is a real scalar/flow value.
fn emptyValue(rest: []const u8) bool {
    const value = std.mem.trim(u8, rest, " \t");
    return value.len == 0 or value[0] == '#';
}

fn eolOf(content: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, content, "\r\n") != null) "\r\n" else "\n";
}

// ── Structure ──────────────────────────────────────────────────────────────

const Item = struct { start: usize, end: usize };

const Event = struct {
    line: usize,
    name: []const u8,
    item_indent: usize = 0,
    items: []Item = &.{},
    /// Line index where an appended item belongs (after the last content line).
    content_end: usize,
    owned_removed: usize = 0,
};

const Block = struct {
    hooks_line: usize,
    event_indent: usize,
    events: []Event,
    block_end: usize,
};

const Parsed = union(enum) {
    none,
    block: Block,
    unsupported: Unsupported,
};

const HooksKey = union(enum) {
    none,
    line: usize,
    unsupported: Unsupported,
};

fn findHooksKey(lines: []const Line) HooksKey {
    var found: ?usize = null;
    for (lines, 0..) |line, i| {
        const ind = indentOf(line.body);
        if (ind.tab) return .{ .unsupported = .tab_indent };
        if (ind.spaces != 0) continue;
        const text = trimmed(line.body);
        if (text.len == 0 or text[0] == '#') continue;
        if (!std.mem.startsWith(u8, text, "hooks")) continue;
        const rest = text["hooks".len..];
        if (rest.len == 0 or rest[0] != ':') continue;
        if (!emptyValue(rest[1..])) return .{ .unsupported = .inline_hooks };
        if (found != null) return .{ .unsupported = .duplicate_hooks };
        found = i;
    }
    return if (found) |idx| .{ .line = idx } else .none;
}

/// Parse the `hooks:` block into event keys and their sequence items.
/// All returned slices are allocated from `arena`.
fn parseBlock(arena: std.mem.Allocator, lines: []const Line, hooks_line: usize) !Parsed {
    var block_end = lines.len;
    var i = hooks_line + 1;
    while (i < lines.len) : (i += 1) {
        const ind = indentOf(lines[i].body);
        if (ind.tab) return .{ .unsupported = .tab_indent };
        if (ind.spaces == 0 and !isBlank(lines[i].body) and trimmed(lines[i].body)[0] != '#') {
            block_end = i;
            break;
        }
    }

    var event_indent: ?usize = null;
    var events: std.ArrayList(Event) = .empty;
    var current: ?*Event = null;
    var item_indent: usize = 0;
    var open_item: ?*Item = null;

    i = hooks_line + 1;
    while (i < block_end) : (i += 1) {
        const body = lines[i].body;
        if (isBlank(body)) continue;
        const ind = indentOf(body);
        if (ind.tab) return .{ .unsupported = .tab_indent };
        const text = trimmed(body);
        const is_comment = text.len > 0 and text[0] == '#';

        if (event_indent == null) {
            if (is_comment) continue;
            if (text[0] == '-') return .{ .unsupported = .sequence_hooks };
            event_indent = ind.spaces;
        }

        // Comments never carry structure, at any indentation.
        if (is_comment) {
            if (current) |ev| ev.content_end = i + 1;
            continue;
        }

        if (ind.spaces == event_indent.?) {
            if (text[0] == '-') return .{ .unsupported = .ambiguous_event };
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse
                return .{ .unsupported = .ambiguous_event };
            if (!emptyValue(text[colon + 1 ..])) return .{ .unsupported = .inline_event };
            const name = std.mem.trim(u8, text[0..colon], " \t");
            if (name.len == 0) return .{ .unsupported = .ambiguous_event };
            for (events.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) return .{ .unsupported = .duplicate_event };
            }
            try events.append(arena, .{
                .line = i,
                .name = name,
                .content_end = i + 1,
            });
            current = &events.items[events.items.len - 1];
            item_indent = 0;
            open_item = null;
            continue;
        }

        const ev = current orelse return .{ .unsupported = .ambiguous_event };
        if (ind.spaces < event_indent.?) return .{ .unsupported = .ambiguous_event };
        if (item_indent == 0) {
            if (text[0] != '-') return .{ .unsupported = .event_mapping };
            item_indent = ind.spaces;
            ev.item_indent = item_indent;
        }
        if (ind.spaces == item_indent) {
            if (text[0] != '-') return .{ .unsupported = .event_mapping };
            var items: std.ArrayList(Item) = .empty;
            try items.ensureTotalCapacity(arena, ev.items.len + 1);
            items.appendSliceAssumeCapacity(ev.items);
            try items.append(arena, .{ .start = i, .end = i + 1 });
            ev.items = items.items;
            open_item = &ev.items[ev.items.len - 1];
        } else if (ind.spaces > item_indent) {
            const item = open_item orelse return .{ .unsupported = .ambiguous_event };
            item.end = i + 1;
        } else {
            return .{ .unsupported = .ambiguous_event };
        }
        ev.content_end = i + 1;
    }

    return .{ .block = .{
        .hooks_line = hooks_line,
        .event_indent = event_indent orelse 2,
        .events = events.items,
        .block_end = block_end,
    } };
}

fn parseContent(arena: std.mem.Allocator, lines: []const Line) !Parsed {
    switch (findHooksKey(lines)) {
        .none => return .none,
        .unsupported => |reason| return .{ .unsupported = reason },
        .line => |idx| return parseBlock(arena, lines, idx),
    }
}

// ── Owned template ─────────────────────────────────────────────────────────

const OwnedLine = struct {
    /// Extra indentation relative to the event's sequence indent.
    rel: usize,
    text: []const u8,
};

const OwnedEvent = struct {
    name: []const u8,
    item_lines: []const OwnedLine,
};

/// Extract the owned event blocks from the bundled template. The template is
/// our own asset, so a malformed shape is an internal error rather than a
/// user-facing refusal.
fn parseTemplate(arena: std.mem.Allocator, template: []const u8) ![]OwnedEvent {
    const lines = try splitLines(arena, template);
    const block = switch (try parseContent(arena, lines)) {
        .block => |b| b,
        else => return error.InvalidTemplate,
    };
    var owned: std.ArrayList(OwnedEvent) = .empty;
    for (block.events) |ev| {
        // Keep the item lines verbatim; the writer re-indents them.
        var item_lines: std.ArrayList(OwnedLine) = .empty;
        for (lines[ev.line + 1 .. ev.content_end]) |line| {
            const ind = indentOf(line.body);
            if (ind.spaces < ev.item_indent) continue;
            try item_lines.append(arena, .{
                .rel = ind.spaces - ev.item_indent,
                .text = line.body[ind.spaces..],
            });
        }
        if (item_lines.items.len == 0) continue;
        try owned.append(arena, .{
            .name = ev.name,
            .item_lines = item_lines.items,
        });
    }
    if (owned.items.len == 0) return error.InvalidTemplate;
    return owned.items;
}

fn containsOwnedCommand(text: []const u8) bool {
    return std.mem.indexOf(u8, text, owned_command) != null;
}

// ── Transform ──────────────────────────────────────────────────────────────

const Inserter = struct {
    at: usize,
    /// At one offset, handler insertions (0) precede new event blocks (1),
    /// and `seq` keeps template order among equals.
    rank: u8,
    seq: usize,
    text: []const u8,
};

fn transform(alloc: std.mem.Allocator, content: []const u8, template: ?[]const u8) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const eol = eolOf(content);
    const lines = try splitLines(arena, content);
    var skip = try arena.alloc(bool, lines.len);
    @memset(skip, false);

    // 1. Strip a legacy marker block. Markers are only removed when balanced.
    var marker_start: ?usize = null;
    for (lines, 0..) |line, i| {
        const text = trimmed(line.body);
        if (std.mem.startsWith(u8, text, "# seance-pool-hooks-start")) {
            if (marker_start != null) return .{ .unsupported = .unbalanced_marker };
            marker_start = i;
        } else if (std.mem.startsWith(u8, text, "# seance-pool-hooks-end")) {
            const start = marker_start orelse return .{ .unsupported = .unbalanced_marker };
            for (start..i + 1) |hit| skip[hit] = true;
            marker_start = null;
        }
    }
    if (marker_start != null) return .{ .unsupported = .unbalanced_marker };

    // 2. Parse what remains.
    const parsed = try parseContent(arena, lines);
    const block = switch (parsed) {
        .unsupported => |reason| return .{ .unsupported = reason },
        .none => null,
        .block => |b| b,
    };

    var insertions: std.ArrayList(Inserter) = .empty;
    var insertion_seq: usize = 0;
    var remaining_events: usize = 0;

    if (block) |b| {
        // 3. Drop every owned handler (any event), regardless of the template.
        for (b.events) |*ev| {
            var dropped: usize = 0;
            for (ev.items) |item| {
                var owned = false;
                for (lines[item.start..item.end]) |line| {
                    if (containsOwnedCommand(line.body)) owned = true;
                }
                if (owned) {
                    for (item.start..item.end) |hit| skip[hit] = true;
                    dropped += 1;
                }
            }
            ev.owned_removed = dropped;
        }

        const owned_events = if (template) |tpl| try parseTemplate(arena, tpl) else &[_]OwnedEvent{};

        for (b.events) |*ev| {
            var kept: usize = 0;
            for (ev.items) |item| {
                if (!skip[item.start]) kept += 1;
            }
            if (kept == 0 and ev.items.len > 0 and ev.owned_removed > 0) {
                // The event only carried our handlers; the key itself is the
                // scaffolding we created, so it goes too (it is re-added below
                // when the template still owns this event).
                skip[ev.line] = true;
            } else {
                remaining_events += 1;
            }
        }

        // 4. Re-add one canonical handler per owned event.
        for (owned_events) |owned_ev| {
            const target = findEvent(b.events, owned_ev.name);
            var text: std.ArrayList(u8) = .empty;
            if (target) |ev| {
                if (skip[ev.line]) {
                    // The key itself was ours: keep it and put the canonical
                    // handler directly under it.
                    skip[ev.line] = false;
                    remaining_events += 1;
                    appendOwnedItems(arena, &text, b.event_indent + 2, owned_ev, eol) catch
                        return error.OutOfMemory;
                    const at = if (ev.line + 1 < lines.len) lines[ev.line + 1].start else content.len;
                    try insertions.append(arena, .{ .at = at, .rank = 0, .seq = insertion_seq, .text = text.items });
                    insertion_seq += 1;
                } else {
                    const indent = if (ev.item_indent != 0) ev.item_indent else b.event_indent + 2;
                    appendOwnedItems(arena, &text, indent, owned_ev, eol) catch return error.OutOfMemory;
                    const at = if (ev.content_end < lines.len) lines[ev.content_end].start else content.len;
                    try insertions.append(arena, .{ .at = at, .rank = 0, .seq = insertion_seq, .text = text.items });
                    insertion_seq += 1;
                }
            } else {
                appendEventBlock(arena, &text, b.event_indent, owned_ev.name, owned_ev, eol) catch
                    return error.OutOfMemory;
                const at = if (b.block_end < lines.len) lines[b.block_end].start else content.len;
                try insertions.append(arena, .{ .at = at, .rank = 1, .seq = insertion_seq, .text = text.items });
                insertion_seq += 1;
            }
        }

        // 5. An emptied hooks block loses its key as well.
        if (remaining_events == 0) skip[b.hooks_line] = true;
    } else if (template) |tpl| {
        const owned_events = try parseTemplate(arena, tpl);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, "hooks:");
        try text.appendSlice(arena, eol);
        for (owned_events) |owned_ev| {
            appendEventBlock(arena, &text, 2, owned_ev.name, owned_ev, eol) catch
                return error.OutOfMemory;
        }
        try insertions.append(arena, .{ .at = content.len, .rank = 1, .seq = insertion_seq, .text = text.items });
        insertion_seq += 1;
    }

    // 6. Assemble.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var ins_idx: usize = 0;
    sortInsertions(insertions.items);
    for (lines, 0..) |line, i| {
        while (ins_idx < insertions.items.len and insertions.items[ins_idx].at == line.start) {
            const text = insertions.items[ins_idx].text;
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(alloc, eol);
            try out.appendSlice(alloc, text);
            ins_idx += 1;
        }
        if (skip[i]) continue;
        try out.appendSlice(alloc, line.body);
        if (line.has_newline) try out.appendSlice(alloc, eol);
    }
    while (ins_idx < insertions.items.len) {
        const text = insertions.items[ins_idx].text;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(alloc, eol);
        try out.appendSlice(alloc, text);
        ins_idx += 1;
    }

    if (std.mem.eql(u8, out.items, content)) return .unchanged;
    return .{ .updated = try out.toOwnedSlice(alloc) };
}

fn findEvent(events: []Event, name: []const u8) ?*Event {
    for (events) |*ev| {
        if (std.mem.eql(u8, ev.name, name)) return ev;
    }
    return null;
}

fn sortInsertions(items: []Inserter) void {
    std.mem.sort(Inserter, items, {}, struct {
        fn lessThan(_: void, a: Inserter, b: Inserter) bool {
            if (a.at != b.at) return a.at < b.at;
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.seq < b.seq;
        }
    }.lessThan);
}

fn appendOwnedItems(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: usize,
    owned_ev: OwnedEvent,
    eol: []const u8,
) !void {
    for (owned_ev.item_lines) |line| {
        try out.appendNTimes(arena, ' ', indent + line.rel);
        try out.appendSlice(arena, line.text);
        try out.appendSlice(arena, eol);
    }
}

fn appendEventBlock(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    event_indent: usize,
    name: []const u8,
    owned_ev: OwnedEvent,
    eol: []const u8,
) !void {
    try out.appendNTimes(arena, ' ', event_indent);
    try out.appendSlice(arena, name);
    try out.appendSlice(arena, ":");
    try out.appendSlice(arena, eol);
    try appendOwnedItems(arena, out, event_indent + 2, owned_ev, eol);
}

pub fn installHooks(alloc: std.mem.Allocator, content: []const u8, template: []const u8) !Outcome {
    return transform(alloc, content, template);
}

pub fn removeHooks(alloc: std.mem.Allocator, content: []const u8) !Outcome {
    return transform(alloc, content, null);
}

// ── Filesystem transaction ─────────────────────────────────────────────────

var tmp_counter: std.atomic.Value(u64) = .init(0);

/// Create `{path}.bak` once from the current bytes of `path`. An existing
/// regular backup is the original copy and is never overwritten; symlinks and
/// other non-regular entries at the backup path are refused. The backup keeps
/// the source file's permission bits.
fn backupOriginal(path: []const u8, alloc: std.mem.Allocator) !void {
    const io_ = io.get();
    const bak_path = try std.fmt.allocPrint(alloc, "{s}.bak", .{path});
    defer alloc.free(bak_path);

    const existing = std.Io.Dir.cwd().statFile(io_, bak_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |st| {
        switch (st.kind) {
            .file => return, // the original is already preserved
            .sym_link => return error.SymlinkNotAllowed,
            else => return error.UnexpectedBackupKind,
        }
    }

    const src = std.Io.Dir.openFileAbsolute(io_, path, .{}) catch |err| return err;
    defer src.close(io_);
    const content = try io.readToEndAlloc(src, alloc, 1024 * 1024);
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
    var renamed = false;
    defer {
        tmp.close(io_);
        if (!renamed) std.Io.Dir.deleteFileAbsolute(io_, tmp_path) catch {};
    }

    try tmp.writeStreamingAll(io_, content);
    try tmp.setPermissions(io_, mode);
    try std.Io.Dir.renameAbsolute(tmp_path, bak_path, io_);
    renamed = true;
}

fn writeAtomic(path: []const u8, data: []const u8, opts: Options) !void {
    const io_ = io.get();

    const existing = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
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
        try tmp.writeStreamingAll(io_, data[0 .. data.len / 2]);
        return error.WriteFailed;
    }
    try tmp.writeStreamingAll(io_, data);
    if (mode) |m| try tmp.setPermissions(io_, m);
    if (opts.fail_at == .rename) return error.RenameFailed;
    try std.Io.Dir.renameAbsolute(tmp_path, path, io_);
    renamed = true;
}

fn ensureParentDirs(dir_path: []const u8) !void {
    var i: usize = 1;
    while (i <= dir_path.len) : (i += 1) {
        if (i == dir_path.len or dir_path[i] == '/') {
            std.Io.Dir.createDirAbsolute(io.get(), dir_path[0..i], .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

/// Read, transform and (only when the result changes) back up + atomically
/// replace the settings file. Read, size, parse, backup and write failures all
/// propagate so the caller can report them; the live file keeps its bytes.
pub fn syncFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    template: []const u8,
    mode: Mode,
    opts: Options,
) !SyncOutcome {
    const io_ = io.get();

    const stat = std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var content: []const u8 = "";
    var own_content = false;
    if (stat) |st| {
        if (st.kind == .sym_link) return error.SymlinkNotAllowed;
        if (st.kind != .file) return error.UnsupportedDestination;
        const file = try std.Io.Dir.openFileAbsolute(io_, path, .{});
        defer file.close(io_);
        content = try io.readToEndAlloc(file, alloc, 1024 * 1024);
        own_content = true;
    } else if (mode == .remove) {
        return .absent;
    }
    defer if (own_content) alloc.free(content);

    const outcome = switch (mode) {
        .install => try installHooks(alloc, content, template),
        .remove => try removeHooks(alloc, content),
    };
    switch (outcome) {
        .unchanged => return .unchanged,
        .unsupported => |reason| return .{ .unsupported = reason },
        .updated => |new_content| {
            defer alloc.free(new_content);
            const settings_dir = std.fs.path.dirname(path) orelse return error.UnsupportedDestination;
            try ensureParentDirs(settings_dir);
            // Absent settings have no original bytes to preserve.
            if (stat != null) try backupOriginal(path, alloc);
            // The file may have been replaced since the read; refuse rather
            // than clobber an outside edit made during this transaction.
            if (stat) |_| {
                const recheck_file = std.Io.Dir.openFileAbsolute(io_, path, .{}) catch
                    return error.ConcurrentModification;
                defer recheck_file.close(io_);
                const current = io.readToEndAlloc(recheck_file, alloc, 1024 * 1024) catch
                    return error.ConcurrentModification;
                defer alloc.free(current);
                if (!std.mem.eql(u8, current, content)) return error.ConcurrentModification;
            } else if (std.Io.Dir.cwd().statFile(io_, path, .{ .follow_symlinks = false })) |_| {
                return error.ConcurrentModification;
            } else |_| {}
            if (mode == .remove and std.mem.trim(u8, new_content, " \t\r\n").len == 0) {
                std.Io.Dir.deleteFileAbsolute(io_, path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                return .updated;
            }
            try writeAtomic(path, new_content, opts);
            return .updated;
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_template =
    \\# Managed by seance — do not edit. Remove via Settings → Integrations.
    \\hooks:
    \\  SessionStart:
    \\    - matcher: "*"
    \\      command: "seance ctl pool-hook session-start"
    \\      timeout: 10
    \\  Stop:
    \\    - matcher: "*"
    \\      command: "seance ctl pool-hook stop"
    \\      timeout: 10
    \\
;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, haystack[pos..], needle)) |offset| {
        count += 1;
        pos += offset + needle.len;
    }
    return count;
}

fn expectUpdated(outcome: Outcome) ![]const u8 {
    return switch (outcome) {
        .updated => |text| text,
        .unchanged => error.TestExpectedUpdated,
        .unsupported => |reason| {
            std.debug.print("unexpected unsupported: {s}\n", .{@tagName(reason)});
            return error.TestExpectedUpdated;
        },
    };
}

fn expectSyncTag(outcome: SyncOutcome, tag: std.meta.Tag(SyncOutcome)) !void {
    if (std.meta.activeTag(outcome) != tag) {
        std.debug.print("unexpected sync outcome: {s}\n", .{@tagName(std.meta.activeTag(outcome))});
        return error.TestUnexpectedResult;
    }
}

fn expectUnsupportedTag(outcome: SyncOutcome, reason: Unsupported) !void {
    switch (outcome) {
        .unsupported => |actual| try testing.expectEqual(reason, actual),
        else => return error.TestUnexpectedResult,
    }
}

test "install into an empty file creates one mapping per owned event" {
    const alloc = testing.allocator;
    const installed = try expectUpdated(try installHooks(alloc, "", test_template));
    defer alloc.free(installed);

    try testing.expect(std.mem.startsWith(u8, installed, "hooks:\n"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "SessionStart:"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook session-start"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook stop"));
}

test "install preserves user handlers and appends exactly one owned handler" {
    const alloc = testing.allocator;
    const user =
        \\# my settings
        \\model: pool
        \\hooks:
        \\  SessionStart:
        \\    - matcher: "*"
        \\      command: "./user-start.sh"
        \\    - matcher: "bash"
        \\      command: "./user-bash.sh"
        \\  PreToolUse:
        \\    - matcher: "*"
        \\      command: "./audit.sh"
        \\other: true
        \\
    ;
    const installed = try expectUpdated(try installHooks(alloc, user, test_template));
    defer alloc.free(installed);

    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook session-start"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook stop"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./user-start.sh"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./user-bash.sh"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./audit.sh"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "SessionStart:"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "PreToolUse:"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "other: true"));

    // Re-running must not change a single byte.
    switch (try installHooks(alloc, installed, test_template)) {
        .unchanged => {},
        .updated => return error.TestUnexpectedResult,
        .unsupported => return error.TestUnexpectedResult,
    }
}

test "install without a hooks key appends a complete block" {
    const alloc = testing.allocator;
    const installed = try expectUpdated(try installHooks(alloc, "model: pool\n", test_template));
    defer alloc.free(installed);
    try testing.expect(std.mem.startsWith(u8, installed, "model: pool\nhooks:\n"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook stop"));
}

test "remove drops only seance handlers and their scaffolding" {
    const alloc = testing.allocator;
    const user =
        \\hooks:
        \\  SessionStart:
        \\    - matcher: "*"
        \\      command: "./user-start.sh"
        \\  Stop:
        \\    - matcher: "*"
        \\      command: "seance ctl pool-hook stop"
        \\      timeout: 10
        \\
    ;
    const removed = try expectUpdated(try removeHooks(alloc, user));
    defer alloc.free(removed);
    try testing.expectEqual(@as(usize, 1), countOccurrences(removed, "./user-start.sh"));
    try testing.expectEqual(@as(usize, 0), countOccurrences(removed, "pool-hook stop"));
    // Our event is re-added by a later install; the key itself was ours.
    try testing.expectEqual(@as(usize, 0), countOccurrences(removed, "Stop:"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(removed, "hooks:"));
}

test "remove of an owned-only file leaves no content behind" {
    const alloc = testing.allocator;
    const installed = try expectUpdated(try installHooks(alloc, "", test_template));
    defer alloc.free(installed);
    const removed = try expectUpdated(try removeHooks(alloc, installed));
    defer alloc.free(removed);
    try testing.expectEqualStrings("", removed);
}

test "legacy marker blocks migrate without duplicating handlers" {
    const alloc = testing.allocator;
    const legacy =
        \\# my settings
        \\hooks:
        \\# seance-pool-hooks-start
        \\  SessionStart:
        \\    - matcher: "*"
        \\      command: "seance ctl pool-hook session-start"
        \\      timeout: 10
        \\  Stop:
        \\    - matcher: "*"
        \\      command: "seance ctl pool-hook stop"
        \\      timeout: 10
        \\# seance-pool-hooks-end
        \\  UserPromptSubmit:
        \\    - matcher: "*"
        \\      command: "./prompt.sh"
        \\
    ;
    const installed = try expectUpdated(try installHooks(alloc, legacy, test_template));
    defer alloc.free(installed);
    try testing.expectEqual(@as(usize, 0), countOccurrences(installed, "seance-pool-hooks-start"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook session-start"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook stop"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./prompt.sh"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "SessionStart:"));
}

test "CRLF files keep their line endings and missing final newline is honored" {
    const alloc = testing.allocator;
    const user = "model: pool\r\nhooks:\r\n  SessionStart:\r\n    - matcher: \"*\"\r\n      command: \"./u.sh\"";
    const installed = try expectUpdated(try installHooks(alloc, user, test_template));
    defer alloc.free(installed);
    try testing.expect(countOccurrences(installed, "\n") == countOccurrences(installed, "\r\n"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook session-start"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./u.sh"));
}

test "unsupported shapes are refused without producing content" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        "hooks: [SessionStart]\n",
        "hooks: *anchor\n",
        "hooks:\n  - item\n",
        "hooks:\n  SessionStart:\n    - a\n  SessionStart:\n    - b\n",
        "hooks:\n  SessionStart: *anchor\n",
        "hooks:\n  SessionStart:\n    matcher: x\n",
        "hooks:\n  SessionStart:\n\t- a\n",
        "# seance-pool-hooks-start\nhooks:\n",
    };
    for (cases) |content| {
        switch (try installHooks(alloc, content, test_template)) {
            .unsupported => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

// ── Transaction tests ──────────────────────────────────────────────────────

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

fn writeFileMode(path: []const u8, data: []const u8, mode: u32) !void {
    const file = try std.Io.Dir.createFileAbsolute(io.get(), path, .{});
    defer file.close(io.get());
    try file.writeStreamingAll(io.get(), data);
    try file.setPermissions(io.get(), std.Io.File.Permissions.fromMode(mode));
}

fn fileMode(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(io.get(), path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

fn countOwnedTemps(tmp: *const testing.TmpDir) !usize {
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".seance-") != null) count += 1;
    }
    return count;
}

test "syncFile installs, backs up the original and preserves its mode" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.yaml", &path_buf);
    try writeFileMode(path, "model: pool\nhooks:\n  Stop:\n    - matcher: \"*\"\n      command: \"./u.sh\"\n", 0o600);

    const outcome = try syncFile(alloc, path, test_template, .install, .{});
    try expectSyncTag(outcome, .updated);

    var buf: [4096]u8 = undefined;
    const installed = try readSmall(path, &buf);
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "pool-hook stop"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(installed, "./u.sh"));
    try testing.expectEqual(@as(u32, 0o600), try fileMode(path));

    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path});
    var bak_content: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        "model: pool\nhooks:\n  Stop:\n    - matcher: \"*\"\n      command: \"./u.sh\"\n",
        try readSmall(bak, &bak_content),
    );
    try testing.expectEqual(@as(u32, 0o600), try fileMode(bak));

    // A second run is a byte-level no-op and leaves no scratch files.
    try expectSyncTag(try syncFile(alloc, path, test_template, .install, .{}), .unchanged);
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));
}

test "syncFile failures leave the original bytes and never stamp success" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "hooks:\n  Stop:\n    - matcher: \"*\"\n      command: \"./u.sh\"\n";

    var buf: [4096]u8 = undefined;
    for ([_]struct { name: []const u8, fail: FailAt, expected: anyerror }{
        .{ .name = "write.yaml", .fail = .write, .expected = error.WriteFailed },
        .{ .name = "rename.yaml", .fail = .rename, .expected = error.RenameFailed },
    }) |case| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try absPath(&tmp, case.name, &path_buf);
        try writeFileMode(path, original, 0o600);
        try testing.expectError(case.expected, syncFile(alloc, path, test_template, .install, .{ .fail_at = case.fail }));
        try testing.expectEqualStrings(original, try readSmall(path, &buf));
    }

    // A directory at the backup path blocks the transaction before any write.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "blocked.yaml", &path_buf);
    try writeFileMode(path, original, 0o600);
    try tmp.dir.createDir(io.get(), "blocked.yaml.bak", .default_dir);
    try testing.expectError(error.UnexpectedBackupKind, syncFile(alloc, path, test_template, .install, .{}));
    try testing.expectEqualStrings(original, try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));

    // Removing the obstruction makes the same transaction succeed.
    tmp.dir.deleteTree(io.get(), "blocked.yaml.bak") catch {};
    try expectSyncTag(try syncFile(alloc, path, test_template, .install, .{}), .updated);
}

test "syncFile refuses unsupported input, symlinks and oversized files" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.yaml", &path_buf);
    const flow = "hooks: [SessionStart]\n";
    try writeFileMode(path, flow, 0o600);

    try expectUnsupportedTag(try syncFile(alloc, path, test_template, .install, .{}), .inline_hooks);
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(flow, try readSmall(path, &buf));
    try testing.expectEqual(@as(usize, 0), try countOwnedTemps(&tmp));

    // Symlink destinations are never written through.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try absPath(&tmp, "link.yaml", &link_buf);
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try absPath(&tmp, "settings.yaml", &target_buf);
    tmp.dir.symLink(io.get(), target, "link.yaml", .{}) catch return error.SkipZigTest;
    try testing.expectError(error.SymlinkNotAllowed, syncFile(alloc, link, test_template, .install, .{}));

    // Oversized input is an error, not an empty-config rewrite.
    const big = try alloc.alloc(u8, 1024 * 1024 + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    var big_buf: [std.fs.max_path_bytes]u8 = undefined;
    const big_path = try absPath(&tmp, "big.yaml", &big_buf);
    try writeFileMode(big_path, big, 0o600);
    try testing.expectError(error.StreamTooLong, syncFile(alloc, big_path, test_template, .install, .{}));
    const st = try std.Io.Dir.cwd().statFile(io.get(), big_path, .{});
    try testing.expectEqual(@as(u64, big.len), st.size);
}

test "syncFile remove deletes an owned-only file and reports an absent file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&tmp, "settings.yaml", &path_buf);

    try expectSyncTag(try syncFile(alloc, path, test_template, .remove, .{}), .absent);

    try expectSyncTag(try syncFile(alloc, path, test_template, .install, .{}), .updated);
    try expectSyncTag(try syncFile(alloc, path, test_template, .remove, .{}), .updated);
    const stat = std.Io.Dir.cwd().statFile(io.get(), path, .{ .follow_symlinks = false });
    try testing.expectError(error.FileNotFound, stat);
}
