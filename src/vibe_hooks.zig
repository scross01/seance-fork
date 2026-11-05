//! Managed-hook ownership editing for Mistral Vibe's ~/.vibe/hooks.toml.
//!
//! Pure text transformation with explicit errors; filesystem transactions live
//! in app.zig. Ownership is claimed through an exact start/end marker pair or
//! a `[[hooks]]` block whose `name` key matches an owned hook name exactly.
//! Unrelated byte ranges are always preserved; ambiguous input is rejected
//! with an error (nothing written) rather than guessed at.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Start of the Séance-owned region in a managed hooks.toml.
pub const marker_begin = "# --- seance managed hooks: begin ---";
/// End of the Séance-owned region. The region between the pair is rewritten
/// wholesale; everything outside is user content.
pub const marker_end = "# --- seance managed hooks: end ---";

/// Hook names this installer owns, current and historical. Historical names
/// come from the pre-marker bundled templates and are needed to migrate
/// legacy installs. Exact-name only: entries whose names merely contain
/// "seance" are user content and stay untouched.
pub const owned_hook_names = [_][]const u8{
    "seance-post-agent",
    "seance-post-agent-turn",
    "seance-pre-tool",
    "seance-pre-tool-use",
    "seance-post-tool",
    "seance-post-tool-use",
};

pub const TransformError = error{ AmbiguousOwnership, OutOfMemory };

pub fn isOwnedHookName(name: []const u8) bool {
    for (owned_hook_names) |owned| {
        if (std.mem.eql(u8, owned, name)) return true;
    }
    return false;
}

/// Removes every Séance-owned region (marker pair plus any legacy managed
/// blocks matched by name). Returns a caller-owned allocation; empty when
/// nothing remains.
pub fn stripOwnedHooks(alloc: Allocator, content: []const u8) TransformError![]u8 {
    var analysis = try analyze(alloc, content);
    defer analysis.deinit();

    var keep = try collectKeepRanges(alloc, content, &analysis);
    defer keep.deinit(alloc);

    return spliceKept(alloc, content, keep.items);
}

/// Deletes owned regions from `content` and appends the marker-wrapped
/// `bundled` block at the end, separated by a newline. `bundled` must contain
/// a complete marker pair, otherwise the file that a first install produces
/// could never be classified again.
pub fn mergeBundledHooks(alloc: Allocator, content: []const u8, bundled: []const u8) TransformError![]u8 {
    if (!hasCompleteMarkerPair(bundled)) return error.AmbiguousOwnership;

    const stripped = try stripOwnedHooks(alloc, content);
    defer alloc.free(stripped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, stripped);
    if (stripped.len > 0 and stripped[stripped.len - 1] != '\n') {
        // Only byte ever added to user content: keep the appended managed
        // block on its own line when the original file lacks a newline.
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, bundled);
    return out.toOwnedSlice(alloc);
}

pub fn hasCompleteMarkerPair(content: []const u8) bool {
    return indexOfMarkerLine(content, marker_begin) != null and
        indexOfMarkerLine(content, marker_end) != null;
}

/// Full-file marker line search without string-state tracking. Only used on
/// contents that were produced by this module; untrusted input goes through
/// `analyze`, which proves ownership before any removal.
fn indexOfMarkerLine(content: []const u8, marker: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < content.len) {
        const rest = content[pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trimEnd(u8, content[pos .. pos + nl], " \t\r");
        if (std.mem.eql(u8, line, marker)) return pos;
        pos += nl + 1;
    }
    return null;
}

const StringState = enum { normal, basic, literal, ml_basic, ml_literal };

const TableHeader = struct { start: usize };

const KeyLine = struct {
    start: usize,
    name: []const u8,
    /// Raw slice between the quotes of a single-line basic or literal string
    /// value. Null for multiline/compound values, which never match owned
    /// names (fail-open: they stay user content).
    value: ?[]const u8,
};

const MarkerHit = struct { start: usize };

const Analysis = struct {
    alloc: Allocator,
    table_headers: std.ArrayList(TableHeader) = .empty,
    keys: std.ArrayList(KeyLine) = .empty,
    begin_hits: std.ArrayList(MarkerHit) = .empty,
    end_hits: std.ArrayList(MarkerHit) = .empty,
    /// A marker-shaped line appeared inside a multiline string, which can
    /// only mean a user payload mimics the marker: ownership is unprovable.
    marker_inside_string: bool = false,

    fn deinit(self: *Analysis) void {
        self.table_headers.deinit(self.alloc);
        self.keys.deinit(self.alloc);
        self.begin_hits.deinit(self.alloc);
        self.end_hits.deinit(self.alloc);
    }

    fn beginRegionStart(self: *const Analysis) ?usize {
        if (self.begin_hits.items.len != 1) return null;
        return self.begin_hits.items[0].start;
    }

    fn endRegionStart(self: *const Analysis) ?usize {
        if (self.end_hits.items.len != 1) return null;
        return self.end_hits.items[0].start;
    }
};

/// One scanning pass over the content. Quote states are tracked char-wise so
/// that `[[hooks]]` headers, `name = "…"` assignments and marker comments
/// inside multiline or quoted strings are never mistaken for structure.
fn analyze(alloc: Allocator, content: []const u8) TransformError!Analysis {
    var a: Analysis = .{ .alloc = alloc };
    errdefer a.deinit();

    var state: StringState = .normal;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i <= content.len) {
        if (i == content.len) {
            if (line_start < content.len) {
                try recordLine(&a, content, line_start, i, state);
                line_start = i + 1;
            }
            break;
        }
        const ch = content[i];
        switch (state) {
            .normal => switch (ch) {
                '\n' => {
                    try recordLine(&a, content, line_start, i, state);
                    line_start = i + 1;
                    i += 1;
                    continue;
                },
                '"' => {
                    if (std.mem.startsWith(u8, content[i..], "\"\"\"")) {
                        state = .ml_basic;
                        i += 2;
                    } else {
                        state = .basic;
                    }
                },
                '\'' => {
                    if (std.mem.startsWith(u8, content[i..], "'''")) {
                        state = .ml_literal;
                        i += 2;
                    } else {
                        state = .literal;
                    }
                },
                '#' => {
                    // Comment: the rest of the line carries no structure, but
                    // the line boundary must still flush so the next line
                    // records independently (marker lines are comments).
                    const end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
                    try recordLine(&a, content, line_start, end, .normal);
                    line_start = end + 1;
                    if (end == content.len) {
                        i += 1;
                        continue;
                    }
                    i = end;
                },
                else => {},
            },
            .basic => switch (ch) {
                '\\' => i += 1,
                '"' => state = .normal,
                '\n' => {
                    // Unterminated quoted string (invalid TOML): fail-open.
                    state = .normal;
                    try recordLine(&a, content, line_start, i, .normal);
                    line_start = i + 1;
                    i += 1;
                    continue;
                },
                else => {},
            },
            .literal => switch (ch) {
                '\'' => state = .normal,
                '\n' => {
                    state = .normal;
                    try recordLine(&a, content, line_start, i, .normal);
                    line_start = i + 1;
                    i += 1;
                    continue;
                },
                else => {},
            },
            .ml_basic => {
                if (std.mem.startsWith(u8, content[i..], "\"\"\"")) {
                    state = .normal;
                    i += 2;
                } else {
                    if (ch == '\\') i += 1;
                    if (ch == '\n') {
                        try recordLine(&a, content, line_start, i, state);
                        line_start = i + 1;
                    }
                }
            },
            .ml_literal => {
                if (std.mem.startsWith(u8, content[i..], "'''")) {
                    state = .normal;
                    i += 2;
                } else {
                    if (ch == '\n') {
                        try recordLine(&a, content, line_start, i, state);
                        line_start = i + 1;
                    }
                }
            },
        }
        i += 1;
    }

    try finishAnalysis(&a);
    return a;
}

fn recordLine(a: *Analysis, content: []const u8, line_start: usize, line_end: usize, state: StringState) !void {
    const structural = state == .normal;
    const line = content[line_start..line_end];
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    const is_begin_line = std.mem.eql(u8, trimmed, marker_begin);
    const is_marker_line = is_begin_line or std.mem.eql(u8, trimmed, marker_end);

    if (!structural) {
        if (is_marker_line) a.marker_inside_string = true;
        return;
    }

    if (is_marker_line) {
        if (is_begin_line) {
            try a.begin_hits.append(a.alloc, .{ .start = line_start });
        } else {
            try a.end_hits.append(a.alloc, .{ .start = line_start });
        }
        return;
    }

    const body = std.mem.trimStart(u8, trimmed, " \t");
    if (body.len > 0 and body[0] == '[') {
        try a.table_headers.append(a.alloc, .{ .start = line_start });
        return;
    }

    if (classifyKeyLine(body)) |key| {
        try a.keys.append(a.alloc, .{
            .start = line_start,
            .name = key.name,
            .value = key.value,
        });
    }
}

const ClassifiedKey = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Parses a bare `key = value` line whose chars sit outside any comment.
/// Only plain keys with a single-line quoted string value are reported.
fn classifyKeyLine(line: []const u8) ?ClassifiedKey {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key_name = std.mem.trim(u8, line[0..eq], " \t");
    if (key_name.len == 0) return null;
    // Dotted/quoted keys are never owned names; keep the simple contract.
    if (key_name[0] == '"' or key_name[0] == '\'' or key_name[0] == '.') return null;

    const rest = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
    if (rest.len == 0) return null;

    if (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))
        return .{ .name = key_name, .value = null };

    const quote = rest[0];
    if (quote != '"' and quote != '\'') return .{ .name = key_name, .value = null };

    const close = valueClose(rest, quote) orelse return .{ .name = key_name, .value = null };
    return .{ .name = key_name, .value = rest[1..close] };
}

/// Index of the quote that terminates a single-line string value, honoring
/// backslash escapes in basic strings.
fn valueClose(rest: []const u8, quote: u8) ?usize {
    var j: usize = 1;
    while (j < rest.len) : (j += 1) {
        if (quote == '"' and rest[j] == '\\' and j + 1 < rest.len) {
            j += 1;
            continue;
        }
        if (rest[j] == quote) return j;
        if (rest[j] == '\n') return null;
    }
    return null;
}

fn finishAnalysis(a: *Analysis) TransformError!void {
    if (a.marker_inside_string) return error.AmbiguousOwnership;

    if ((a.begin_hits.items.len == 1) != (a.end_hits.items.len == 1)) {
        // A half-owned file (begin without end or vice versa) cannot prove
        // where managed bytes stop; rewriting could discard user hooks.
        return error.AmbiguousOwnership;
    }
    if (a.begin_hits.items.len > 1 or a.end_hits.items.len > 1) return error.AmbiguousOwnership;

    const begin = a.beginRegionStart();
    const end = a.endRegionStart();
    if (begin != null and end != null and begin.? > end.?) return error.AmbiguousOwnership;
}

const KeepRange = struct { start: usize, end: usize };

/// Computes the complementary ranges of every owned region in `content`.
fn collectKeepRanges(
    alloc: Allocator,
    content: []const u8,
    a: *const Analysis,
) TransformError!std.ArrayList(KeepRange) {
    var remove: std.ArrayList(KeepRange) = .empty;
    errdefer remove.deinit(alloc);

    // Marker region: exact bytes through the end marker's line. While the
    // region is owned as a whole, block windows extend at most this far so
    // user content appended after the region is always kept.
    const region_end: ?usize = if (a.begin_hits.items.len == 1 and a.end_hits.items.len == 1)
        lineEnd(content, a.endRegionStart().?)
    else
        null;
    if (region_end) |re| {
        try remove.append(alloc, .{ .start = a.beginRegionStart().?, .end = re });
    }

    // Name-matched managed `[[hooks]]` blocks. These cover legacy entries
    // installed before the marker era plus stray duplicates anywhere.
    for (a.table_headers.items) |header| {
        const stop = blockStop(content, a, header.start, region_end);
        if (stop <= header.start) continue;
        if (blockContainsOwnedName(a, header.start, stop)) {
            try remove.append(alloc, .{ .start = header.start, .end = stop });
        }
    }

    // Sort, then compact overlapping windows in place so a legacy block that
    // started before `marker_begin` but continues into the managed region
    // collapses into one exact range instead of duplicated splices.
    std.mem.sortUnstable(KeepRange, remove.items, {}, struct {
        fn lessThan(_: void, x: KeepRange, y: KeepRange) bool {
            return x.start < y.start;
        }
    }.lessThan);
    var write: usize = 0;
    for (remove.items) |r| {
        if (write > 0 and r.start <= remove.items[write - 1].end) {
            remove.items[write - 1].end = @max(remove.items[write - 1].end, r.end);
        } else {
            remove.items[write] = r;
            write += 1;
        }
    }

    // Invert removal windows into keep ranges. Both errdefers fire on error
    // return only; the success path frees `remove` explicitly and transfers
    // ownership of `keep` to the caller.
    var keep: std.ArrayList(KeepRange) = .empty;
    errdefer keep.deinit(alloc);
    var cursor: usize = 0;
    for (remove.items[0..write]) |r| {
        if (r.start > cursor) try keep.append(alloc, .{ .start = cursor, .end = r.start });
        cursor = @max(cursor, r.end);
    }
    if (cursor < content.len) try keep.append(alloc, .{ .start = cursor, .end = content.len });
    remove.deinit(alloc);
    return keep;
}

fn lineEnd(content: []const u8, line_start: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
    return @min(nl + 1, content.len);
}

/// The removal window of a `[[hooks]]` block stops at the next structural
/// table header (which includes `[[hooks]]` and user tables) or the file end,
/// matching TOML's rule that a new table header ends the previous entry.
/// With a proven marker region, windows never reach past the region so user
/// content after the end marker is always kept.
fn blockStop(content: []const u8, a: *const Analysis, block_start: usize, region_end: ?usize) usize {
    var stop: usize = content.len;
    for (a.table_headers.items) |h| {
        if (h.start > block_start) {
            stop = h.start;
            break;
        }
    }
    if (region_end) |re| stop = @min(stop, re);
    return stop;
}

fn blockContainsOwnedName(a: *const Analysis, block_start: usize, block_end: usize) bool {
    for (a.keys.items) |key| {
        if (key.start < block_start or key.start >= block_end) continue;
        if (!std.mem.eql(u8, key.name, "name")) continue;
        const value = key.value orelse continue;
        if (isOwnedHookName(value)) return true;
    }
    return false;
}

fn spliceKept(alloc: Allocator, content: []const u8, keep: []const KeepRange) TransformError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, content.len);
    for (keep) |r| try out.appendSlice(alloc, content[r.start..r.end]);
    return out.toOwnedSlice(alloc);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const test_bundle =
    "# --- seance managed hooks: begin ---\n" ++
    "[[hooks]]\n" ++
    "name = \"seance-pre-tool\"\n" ++
    "type = \"pre_tool\"\n" ++
    "command = \"seance ctl vibe-hook pre-tool-use\"\n" ++
    "# --- seance managed hooks: end ---\n";

fn expectStripEqual(input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const out = try stripOwnedHooks(alloc, input);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn expectStripError(input: []const u8) !void {
    try std.testing.expectError(error.AmbiguousOwnership, stripOwnedHooks(std.testing.allocator, input));
}

test "missing and empty files strip to empty" {
    try expectStripEqual("", "");
}

test "fresh install merge produces only the bundled block" {
    const alloc = std.testing.allocator;
    const out = try mergeBundledHooks(alloc, "", test_bundle);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(test_bundle, out);
}

test "merge validates the bundle carries an ownership marker pair" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.AmbiguousOwnership, mergeBundledHooks(alloc, "", "# no markers here\n"));
}

test "user hooks before and after managed region are preserved byte-for-byte" {
    const input =
        "[[hooks]]\n" ++
        "name = \"user-early\"\n" ++
        "command = \"echo early\"\n" ++
        "# --- seance managed hooks: begin ---\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "# --- seance managed hooks: end ---\n" ++
        "[[hooks]]\n" ++
        "name = \"user-late\"\n" ++
        "command = \"echo late\"\n";
    const expected =
        "[[hooks]]\n" ++
        "name = \"user-early\"\n" ++
        "command = \"echo early\"\n" ++
        "[[hooks]]\n" ++
        "name = \"user-late\"\n" ++
        "command = \"echo late\"\n";
    try expectStripEqual(input, expected);
    try expectStripEqual(expected, expected);
}

test "user content appended after the end marker is kept" {
    const input =
        "# --- seance managed hooks: begin ---\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "# --- seance managed hooks: end ---\n" ++
        "[[hooks]]\n" ++
        "name = \"user-after\"\n" ++
        "command = \"echo\"\n";
    const expected =
        "[[hooks]]\n" ++
        "name = \"user-after\"\n" ++
        "command = \"echo\"\n";
    try expectStripEqual(input, expected);
}

test "legacy managed blocks are removed by exact name" {
    for (owned_hook_names) |owned| {
        const alloc = std.testing.allocator;
        const input = try std.fmt.allocPrint(
            alloc,
            "[[hooks]]\nname = \"{s}\"\ntype = \"pre_tool\"\ncommand = \"seance ctl vibe-hook pre-tool-use\"\n[[hooks]]\nname = \"user-hook\"\ncommand = \"echo\"\n",
            .{owned},
        );
        defer alloc.free(input);
        try expectStripEqual(
            input,
            "[[hooks]]\nname = \"user-hook\"\ncommand = \"echo\"\n",
        );
    }
}

test "legacy managed blocks are removed by exact name (literal quotes)" {
    const input =
        "[[hooks]]\n" ++
        "name = 'seance-post-agent'\n" ++
        "command = \"seance ctl vibe-hook stop\"\n";
    try expectStripEqual(input, "");
}

test "duplicate managed entries are all removed" {
    const input =
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "command = \"a\"\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "command = \"b\"\n";
    try expectStripEqual(input, "");
}

test "hooks whose names merely contain seance stay untouched" {
    const input =
        "[[hooks]]\n" ++
        "name = \"my-seance-thing\"\n" ++
        "command = \"echo\"\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool-extra\"\n" ++
        "command = \"echo\"\n";
    try expectStripEqual(input, input);
}

test "comments in user regions are preserved" {
    const input =
        "# user header comment\n" ++
        "[[hooks]]\n" ++
        "name = \"user-hook\" # trailing comment\n" ++
        "# user footer comment\n";
    try expectStripEqual(input, input);
}

test "CRLF line endings are handled and preserved" {
    const input =
        "[[hooks]]\r\n" ++
        "name = \"user-hook\"\r\n" ++
        "# --- seance managed hooks: begin ---\r\n" ++
        "[[hooks]]\r\n" ++
        "name = \"seance-pre-tool\"\r\n" ++
        "# --- seance managed hooks: end ---\r\n";
    const expected = "[[hooks]]\r\nname = \"user-hook\"\r\n";
    try expectStripEqual(input, expected);
}

test "file without trailing newline round-trips" {
    const input = "a = 1\n[[hooks]]\nname = \"seance-pre-tool\"";
    try expectStripEqual(input, "a = 1\n");
}

test "merge separates appended block from user content lacking a final newline" {
    const alloc = std.testing.allocator;
    const out = try mergeBundledHooks(alloc, "a = 1", test_bundle);
    defer alloc.free(out);
    const expected = "a = 1\n" ++ test_bundle;
    try std.testing.expectEqualStrings(expected, out);
}

test "nested user tables survive a managed strip" {
    const input =
        "[profile.deep]\n" ++
        "option = true\n" ++
        "[[hooks]]\n" ++
        "name = \"user-hook\"\n" ++
        "command = \"echo\"\n" ++
        "# --- seance managed hooks: begin ---\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "# --- seance managed hooks: end ---\n";
    const expected = input[0 .. std.mem.indexOf(u8, input, "\n# --- seance managed hooks: begin").? + 1];
    try expectStripEqual(input, expected);
}

test "multiline user strings hide fake keys and table headers" {
    const input =
        "[[hooks]]\n" ++
        "name = \"user-hook\"\n" ++
        "description = \"\"\"\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "[[hooks]]\n" ++
        "\"\"\"\n" ++
        "command = \"echo\"\n";
    try expectStripEqual(input, input);
}

test "marker text inside a multiline string is ambiguous and rejected" {
    const input =
        "[[hooks]]\n" ++
        "name = \"user-hook\"\n" ++
        "description = \"\"\"\n" ++
        "# --- seance managed hooks: end ---\n" ++
        "\"\"\"\n";
    try expectStripError(input);
}

test "half-owned marker regions are rejected" {
    try expectStripError(
        "# --- seance managed hooks: begin ---\n" ++
            "[[hooks]]\n" ++
            "name = \"seance-pre-tool\"\n",
    );
    try expectStripError(
        "# --- seance managed hooks: end ---\n" ++
            "[[hooks]]\n" ++
            "name = \"user-hook\"\n",
    );
}

test "reversed marker order is rejected" {
    try expectStripError(
        "# --- seance managed hooks: end ---\n" ++
            "[[hooks]]\n" ++
            "name = \"seance-pre-tool\"\n" ++
            "# --- seance managed hooks: begin ---\n",
    );
}

test "duplicate marker pairs are rejected" {
    try expectStripError(
        "# --- seance managed hooks: begin ---\n" ++
            "# --- seance managed hooks: begin ---\n" ++
            "# --- seance managed hooks: end ---\n" ++
            "# --- seance managed hooks: end ---\n",
    );
}

test "legacy block before the marker region merges into one removal window" {
    const input =
        "[[hooks]]\n" ++
        "name = \"seance-pre-tool\"\n" ++
        "command = \"legacy\"\n" ++
        "# --- seance managed hooks: begin ---\n" ++
        "[[hooks]]\n" ++
        "name = \"seance-post-tool\"\n" ++
        "# --- seance managed hooks: end ---\n" ++
        "[[hooks]]\n" ++
        "name = \"user-hook\"\n" ++
        "command = \"echo\"\n";
    const expected =
        "[[hooks]]\n" ++
        "name = \"user-hook\"\n" ++
        "command = \"echo\"\n";
    try expectStripEqual(input, expected);
}

test "merge is idempotent" {
    const alloc = std.testing.allocator;
    const user = "[[hooks]]\nname = \"user-hook\"\ncommand = \"echo\"\n";
    const once = try mergeBundledHooks(alloc, user, test_bundle);
    defer alloc.free(once);
    const twice = try mergeBundledHooks(alloc, once, test_bundle);
    defer alloc.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "strip is idempotent" {
    const alloc = std.testing.allocator;
    const input = "keep = 1\n" ++ test_bundle;
    const once = try stripOwnedHooks(alloc, input);
    defer alloc.free(once);
    try std.testing.expectEqualStrings("keep = 1\n", once);
    const twice = try stripOwnedHooks(alloc, once);
    defer alloc.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "disabled integration leaves unrecognized content untouched" {
    const input =
        "root = true\n" ++
        "[hooks]\n" ++
        "name = \"plain-table-entry\"\n";
    try expectStripEqual(input, input);
}
