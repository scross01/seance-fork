const std = @import("std");
const io = @import("io.zig");
const port_allocation = @import("port_allocation.zig");
const c = @import("c.zig").c;
const ErrorBuf = @import("error_buf.zig").ErrorBuf;
const Pane = @import("pane.zig").Pane;
const Panel = @import("panel.zig").Panel;
const PaneGroup = @import("pane_group.zig").PaneGroup;
const Workspace = @import("workspace.zig").Workspace;
const Allocator = std.mem.Allocator;

pub const MAX_SCROLLBACK_LINES: usize = 4000;
pub const MAX_SCROLLBACK_CHARS: usize = 400_000;
pub const AUTOSAVE_INTERVAL_SECS: u32 = 8;
pub const SESSION_VERSION: u32 = 1;

var load_error: ErrorBuf("Session restore error (details too long)") = .{};

const session_storage = @import("session_storage.zig");

/// Snapshot writer coordination. saveAll is only ever called from the GTK
/// main thread, so the store's handle field is single-threaded; the
/// background writer touches only its own atomics and file IO.
var storage: session_storage.Store = .{ .alloc = std.heap.page_allocator };

/// Wait for any background snapshot write to finish. Shutdown calls this
/// before the forced process exit so storage coordination is complete.
pub fn storageDrain() void {
    storage.joinAll();
}

pub fn getLoadError() ?[*:0]const u8 {
    return load_error.get();
}

pub fn clearLoadError() void {
    load_error.clear();
}

pub fn getSessionPath(buf: []u8) ?[]const u8 {
    const home = io.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/seance/session.json", .{home}) catch null;
}

// ── Save (multi-window) ──────────────────────────────────────────────

pub fn saveAll(wm: anytype, include_scrollback: bool, async_write: bool) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getSessionPath(&path_buf) orelse {
        std.log.warn("session: cannot save — session path unavailable", .{});
        return;
    };

    const alloc = wm.allocator;

    if (async_write) {
        // Admission happens before capture: a busy store skips the
        // expensive history export entirely, and a rejection never alters
        // the state of the writer that owns the file.
        storage.admit() catch return;
        const composed = composeSnapshot(alloc, wm, include_scrollback) catch |e| {
            std.log.warn("session: failed to compose snapshot: {s}", .{@errorName(e)});
            storage.release();
            return;
        };
        defer alloc.free(composed);
        const payload = std.heap.page_allocator.dupe(u8, composed) catch {
            std.log.warn("session: failed to allocate snapshot payload", .{});
            storage.release();
            return;
        };
        // spawnAsync takes over admission and payload ownership from here:
        // the worker releases and frees both when its file work finishes,
        // and every failure path does the same itself.
        storage.spawnAsync(path, payload) catch |e| {
            std.log.warn("session: failed to start session write: {s}", .{@errorName(e)});
        };
        return;
    }

    // Synchronous write used for shutdown / window close: let any
    // in-flight background commit finish first so this newer snapshot is
    // the last rename on disk, then replace atomically.
    storage.joinAll();
    storage.admit() catch |e| {
        std.log.warn("session: cannot save — {s}", .{@errorName(e)});
        return;
    };
    defer storage.release();
    const composed = composeSnapshot(alloc, wm, include_scrollback) catch |e| {
        std.log.warn("session: failed to compose snapshot: {s}", .{@errorName(e)});
        return;
    };
    defer alloc.free(composed);
    storage.replace(path, composed) catch |e| {
        std.log.warn("session: failed to write session file: {s}", .{@errorName(e)});
    };
}

/// Per-terminal-pane scrollback data threaded through serialization.
/// `items` is in exact traversal order (null = no history); `allowance`
/// caps each entry's JSON-escaped cost. The cursor is consumed as terminal
/// panels are written, so capture and serialization must walk the same
/// tree in the same order.
const HistoryContext = struct {
    items: []const ?[]u8,
    allowance: []const usize,
    cursor: usize = 0,
};

/// The loader reads snapshots with `.limited(MAX_SNAPSHOT_BYTES + 1)`, so
/// a file above MAX_SNAPSHOT_BYTES would be written but never restored.
/// Rejecting here preserves the previous snapshot instead.
fn enforceSnapshotBudget(len: usize) error{SnapshotTooLarge}!void {
    if (len > session_storage.MAX_SNAPSHOT_BYTES) return error.SnapshotTooLarge;
}

/// Exact byte cost of `s` once JSON-escaped — must stay in lockstep with
/// `writeJsonEscaped` so budget math never under-allocates.
fn jsonEscapedLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| n += escapeCost(ch);
    return n;
}

fn escapeCost(ch: u8) usize {
    return switch (ch) {
        '"', '\\', '\n', '\r', '\t' => 2,
        else => if (ch < 0x20) 6 else 1,
    };
}

/// Newest suffix of `text` whose escaped form costs at most `max_escaped`
/// bytes. The slice always ends at the file end (the newest output); its
/// start is snapped off partial UTF-8 characters and ANSI sequences, which
/// only shrinks the cost further.
fn sliceNewestEscaped(text: []const u8, max_escaped: usize) []const u8 {
    if (max_escaped == 0) return "";
    var cost: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        cost += escapeCost(text[i]);
        if (cost > max_escaped) {
            i += 1;
            break;
        }
    }
    return ansiSafeTruncationStart(utf8SafeStart(text[i..]));
}

/// Deterministically divide `available` bytes across per-history costs:
/// every allowance is ≤ its cost and the total never exceeds `available`.
/// When everything fits, full costs pass through unchanged; otherwise each
/// pane gets an equal share of what remains, left to right. Starved panes
/// fall back to no history — never to a truncated layout.
fn distributeHistoryBudget(available: usize, costs: []const usize, out: []usize) void {
    std.debug.assert(costs.len == out.len);
    var total: usize = 0;
    for (costs) |cost| total +|= cost;
    if (total <= available) {
        @memcpy(out, costs);
        return;
    }
    var remaining = available;
    for (costs, 0..) |cost, i| {
        const share = remaining / (costs.len - i);
        const take = @min(cost, share);
        out[i] = take;
        remaining -= take;
    }
}

/// Export and read one pane's scrollback into owned bytes (null when there
/// is nothing to replay). Runs on the main thread only: the ghostty export
/// callback fills bridge.captured_clipboard synchronously.
fn capturePaneScrollback(pane: *Pane, alloc: Allocator) ?[]u8 {
    const surface = pane.surface orelse return null;

    const bridge = @import("ghostty_bridge.zig");

    // Export scrollback with palette-indexed colors (not resolved to RGB)
    // so that theme changes after restore update the colors correctly.
    // Ghostty writes to a temp file and calls writeClipboardCb with the
    // path. We read the path from the bridge's captured_clipboard
    // (bypassing GDK, which fails on Wayland).
    bridge.captured_clipboard_len = 0;
    const action = "write_screen_file:copy,vt_indexed";
    const ok = c.ghostty_surface_binding_action(surface, action, action.len);

    if (!ok or bridge.captured_clipboard_len == 0) return null;

    const file_path = bridge.captured_clipboard[0..bridge.captured_clipboard_len];
    if (file_path.len == 0 or file_path[0] != '/') return null;

    const file = std.Io.Dir.openFileAbsolute(io.get(), file_path, .{}) catch return null;
    defer {
        file.close(io.get());
        std.Io.Dir.deleteFileAbsolute(io.get(), file_path) catch {};
    }

    const window = readScrollbackWindow(file, alloc) catch return null;
    defer alloc.free(window.buffer);
    if (window.text.len == 0) return null;
    return alloc.dupe(u8, window.text) catch return null;
}

/// Walk the window tree in serialization order and capture every terminal
/// pane's scrollback exactly once (null entries keep the list aligned with
/// the serializer's cursor). History is captured before any budgeting so no
/// path can re-run the ghostty export in a retry loop.
fn captureHistories(alloc: Allocator, wm: anytype, out: *std.ArrayList(?[]u8)) !void {
    for (wm.windows.items) |state| {
        for (state.workspaces.items) |ws| {
            for (ws.columns.items) |col| {
                for (col.groups.items) |grp| {
                    for (grp.panels.items) |panel| {
                        switch (panel) {
                            .terminal => |pane| {
                                const text = capturePaneScrollback(pane, alloc);
                                out.append(alloc, text) catch |err| {
                                    if (text) |bytes| alloc.free(bytes);
                                    return err;
                                };
                            },
                            .webkit => {},
                        }
                    }
                }
            }
        }
    }
}

fn freeHistories(alloc: Allocator, list: *std.ArrayList(?[]u8)) void {
    for (list.items) |maybe| {
        if (maybe) |bytes| alloc.free(bytes);
    }
    list.deinit(alloc);
}

/// Capture histories once, measure the layout floor, and compose final
/// snapshot bytes that fit MAX_SNAPSHOT_BYTES. If the layout alone exceeds
/// the limit the error propagates without touching the previous snapshot;
/// if history cannot be afforded, entries become null (layout-only
/// fallback) — panes are never dropped. Caller owns the result.
fn composeSnapshot(alloc: Allocator, wm: anytype, include_scrollback: bool) ![]u8 {
    var histories: std.ArrayList(?[]u8) = .empty;
    defer freeHistories(alloc, &histories);
    if (include_scrollback) try captureHistories(alloc, wm, &histories);

    // Pass 1: layout with null scrollbacks — the floor every snapshot
    // must fit.
    var layout_buf: std.ArrayList(u8) = .empty;
    defer layout_buf.deinit(alloc);
    try writeMultiWindowJson(&layout_buf, alloc, wm, null);
    try enforceSnapshotBudget(layout_buf.items.len);

    var any_history = false;
    for (histories.items) |maybe| {
        if (maybe != null) {
            any_history = true;
            break;
        }
    }
    // Nothing captured: the layout pass is already the final snapshot.
    if (!any_history) return layout_buf.toOwnedSlice(alloc);

    // Budget the remainder by exact escaped cost, deterministically.
    const costs = try alloc.alloc(usize, histories.items.len);
    defer alloc.free(costs);
    for (histories.items, 0..) |maybe, i| {
        costs[i] = if (maybe) |text| 2 + jsonEscapedLen(text) else 0;
    }
    const allowances = try alloc.alloc(usize, histories.items.len);
    defer alloc.free(allowances);
    const available = session_storage.MAX_SNAPSHOT_BYTES - layout_buf.items.len;
    distributeHistoryBudget(available, costs, allowances);

    // Pass 2: compose with allowance-sliced histories.
    var ctx = HistoryContext{ .items = histories.items, .allowance = allowances };
    var final_buf: std.ArrayList(u8) = .empty;
    defer final_buf.deinit(alloc);
    try writeMultiWindowJson(&final_buf, alloc, wm, &ctx);
    // The conservative costs above make this unreachable; keep the
    // invariant explicit so an unreadable snapshot can never be committed.
    try enforceSnapshotBudget(final_buf.items.len);
    return final_buf.toOwnedSlice(alloc);
}

/// Write one terminal pane's consumed history slot: slice it to its
/// escaped-cost allowance and fall back to `null` when there is nothing
/// affordable to replay.
fn writeHistory(w: anytype, ctx: *HistoryContext) !void {
    const idx = ctx.cursor;
    ctx.cursor += 1;
    const maybe = if (idx < ctx.items.len) ctx.items[idx] else null;
    const text = maybe orelse {
        try writeKvNull(w, "scrollback", false);
        return;
    };
    const allowance = if (idx < ctx.allowance.len) ctx.allowance[idx] else 0;
    const slice = sliceNewestEscaped(text, allowance);
    if (slice.len == 0) {
        try writeKvNull(w, "scrollback", false);
        return;
    }
    try writeKvStr(w, "scrollback", slice, false);
}

fn writeMultiWindowJson(buf: *std.ArrayList(u8), alloc: Allocator, wm: anytype, histories: ?*HistoryContext) !void {
    var output: std.Io.Writer.Allocating = .fromArrayList(alloc, buf);
    defer buf.* = output.toArrayList();
    const w = &output.writer;
    try w.writeAll("{");
    try writeKvInt(w, "version", SESSION_VERSION, true);
    try writeKvInt(w, "created_at", @intCast(io.timestamp()), false);
    try w.writeAll(",\"windows\":[");

    for (wm.windows.items, 0..) |state, i| {
        if (i > 0) try w.writeByte(',');
        try writeWindowJson(w, state, histories);
    }

    try w.writeAll("]}");
}

fn writeWindowJson(w: anytype, state: anytype, histories: ?*HistoryContext) !void {
    try w.writeAll("{");
    try writeKvBool(w, "sidebar_visible", state.sidebar_visible, true);
    try writeKvInt(w, "active_workspace", @intCast(state.active_workspace), false);

    // Save window dimensions
    const gtk_w: *c.GtkWidget = state.gtk_window;
    try writeKvInt(w, "width", @intCast(c.gtk_widget_get_width(gtk_w)), false);
    try writeKvInt(w, "height", @intCast(c.gtk_widget_get_height(gtk_w)), false);

    try w.writeAll(",\"workspaces\":[");
    for (state.workspaces.items, 0..) |ws, i| {
        if (i > 0) try w.writeByte(',');
        try writeWorkspace(w, ws, histories);
    }
    try w.writeAll("]}");
}

fn writeWorkspace(w: anytype, ws: *Workspace, histories: ?*HistoryContext) !void {
    try w.writeAll("{");
    try writeKvStr(w, "title", ws.getTitle(), true);
    if (ws.title_is_custom) {
        try writeKvStr(w, "custom_title", ws.getTitle(), false);
    } else {
        try writeKvNull(w, "custom_title", false);
    }
    if (ws.getCustomColor()) |color| {
        try writeKvStr(w, "custom_color", color, false);
    } else {
        try writeKvNull(w, "custom_color", false);
    }
    try writeKvBool(w, "is_pinned", ws.is_pinned, false);
    try writeKvInt(w, "port_ordinal", @intCast(ws.port_ordinal), false);
    try writeKvFloat(w, "camera", ws.camera, false);
    try w.writeAll(",\"layout\":");
    try writeLayout(w, ws, histories);
    try w.writeByte('}');
}

fn writeLayout(w: anytype, ws: *Workspace, histories: ?*HistoryContext) !void {
    try w.writeAll("{\"type\":\"columns\"");
    try writeKvInt(w, "focused_column", @intCast(ws.focused_column), false);
    try w.writeAll(",\"columns\":[");
    for (ws.columns.items, 0..) |col, ci| {
        if (ci > 0) try w.writeByte(',');
        try w.writeAll("{");
        try writeKvFloat(w, "width", col.target_width, true);
        if (col.layout_mode == .tabbed) {
            try writeKvStr(w, "layout_mode", "tabbed", false);
        }
        try w.writeAll(",\"groups\":[");
        for (col.groups.items, 0..) |grp, gi| {
            if (gi > 0) try w.writeByte(',');
            try writeGroup(w, grp, histories);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

fn writeKvFloat(w: anytype, key: []const u8, val: f64, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.print("{d:.4}", .{val});
}

fn writeGroup(w: anytype, grp: *PaneGroup, histories: ?*HistoryContext) !void {
    try w.writeAll("{");
    try writeKvInt(w, "active_panel", @intCast(grp.active_panel), true);
    try w.writeAll(",\"panels\":[");
    for (grp.panels.items, 0..) |panel, i| {
        if (i > 0) try w.writeByte(',');
        try writePanel(w, panel, histories);
    }
    try w.writeAll("]}");
}

fn writePanel(w: anytype, panel: Panel, histories: ?*HistoryContext) !void {
    switch (panel) {
        .terminal => |pane| {
            try w.writeAll("{\"type\":\"terminal\"");
            if (pane.getCwd()) |cwd_val| {
                try writeKvStr(w, "cwd", cwd_val, false);
            } else {
                try writeKvNull(w, "cwd", false);
            }
            if (pane.custom_title_len > 0) {
                try writeKvStr(w, "custom_title", pane.custom_title[0..pane.custom_title_len], false);
            }
            if (pane.height_weight != 1.0) {
                try writeKvFloat(w, "height_weight", pane.height_weight, false);
            }
            if (histories) |ctx| {
                try writeHistory(w, ctx);
            } else {
                try writeKvNull(w, "scrollback", false);
            }
            try w.writeByte('}');
        },
        .webkit => |wp| {
            try w.writeAll("{\"type\":\"webkit\"");
            try writeKvStr(w, "url", wp.url, false);
            try writeKvInt(w, "id", @intCast(wp.id), false);
            try w.writeByte('}');
        },
    }
}

/// Owned result of a bounded scrollback read: `buffer` must be freed with
/// the same allocator; `text` is a view into it.
const ScrollbackWindow = struct {
    buffer: []u8,
    text: []const u8,
};

/// Read the newest bounded window of a scrollback export. Only the last
/// `MAX_SCROLLBACK_CHARS + 64 KiB` bytes are ever read (file size + seek),
/// so a huge history yields its actual newest output instead of an old
/// prefix; `truncateScrollback` then applies the line/char caps and snaps
/// the start off partial UTF-8 characters and ANSI sequences.
fn readScrollbackWindow(file: std.Io.File, alloc: Allocator) !ScrollbackWindow {
    const max_read = MAX_SCROLLBACK_CHARS + 64 * 1024;
    const stat = try file.stat(io.get());
    const size: usize = @intCast(stat.size);
    const start = if (size > max_read) size - max_read else 0;

    const buffer = try alloc.alloc(u8, max_read);
    errdefer alloc.free(buffer);

    var fr = file.reader(io.get(), &.{});
    try fr.seekTo(start);
    const n = try fr.interface.readSliceShort(buffer);
    if (n == 0) return .{ .buffer = buffer, .text = "" };

    return .{ .buffer = buffer, .text = truncateScrollback(buffer[0..n]) };
}

fn truncateScrollback(text: []const u8) []const u8 {
    var t = text;
    if (t.len > MAX_SCROLLBACK_CHARS) {
        t = t[t.len - MAX_SCROLLBACK_CHARS ..];
    }
    var line_count: usize = 0;
    var i = t.len;
    while (i > 0) {
        i -= 1;
        if (t[i] == '\n') {
            line_count += 1;
            if (line_count >= MAX_SCROLLBACK_LINES) {
                t = t[i + 1 ..];
                break;
            }
        }
    }
    // Ensure truncation didn't land inside a multi-byte UTF-8 character
    // or an ANSI escape sequence
    return ansiSafeTruncationStart(utf8SafeStart(t));
}

/// If `text` starts inside an ANSI escape sequence (ESC [ ... final_byte),
/// advance past it so replay doesn't emit a broken partial sequence.
fn ansiSafeTruncationStart(text: []const u8) []const u8 {
    if (text.len == 0) return text;

    // Fast path: if first byte is ESC, we're at a sequence boundary (OK)
    // or at the start of one (also OK — it'll be complete or we skip it).
    if (text[0] == 0x1b) return text;

    // Detect mid-CSI: if truncation landed inside a CSI sequence
    // (ESC [ params... intermediates... final_byte), the text will start
    // with parameter bytes (0x30-0x3F) and/or intermediate bytes (0x20-0x2F)
    // followed by a final byte (0x40-0x7E), without a preceding ESC [.
    // Scan forward through the expected CSI structure to find the final byte.
    var j: usize = 0;

    // Skip parameter bytes (0x30-0x3F): digits 0-9, : ; < = > ?
    while (j < text.len and j < 64) : (j += 1) {
        if (text[j] < 0x30 or text[j] > 0x3F) break;
    }
    // Skip intermediate bytes (0x20-0x2F): space through /
    while (j < text.len and j < 64) : (j += 1) {
        if (text[j] < 0x20 or text[j] > 0x2F) break;
    }
    // If we consumed at least one byte and hit a final byte, we were
    // mid-CSI — advance past the final byte.
    if (j > 0 and j < text.len and text[j] >= 0x40 and text[j] <= 0x7E) {
        return text[j + 1 ..];
    }

    // Fallback: scan forward for ESC before a newline (handles other
    // partial sequences like OSC). May skip up to 64 bytes of visible
    // text — acceptable for scrollback replay at a truncation boundary.
    j = 0;
    while (j < text.len and j < 64) : (j += 1) {
        if (text[j] == 0x1b) return text[j..];
        if (text[j] == '\n') break;
    }

    return text;
}

/// Advance past leading UTF-8 continuation bytes so a truncation that
/// landed inside a multi-byte character starts on a character boundary.
fn utf8SafeStart(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
    return text[i..];
}

// ── Scrollback replay file helpers ────────────────────────────────────

var replay_dir_path: [std.fs.max_path_bytes]u8 = undefined;
var replay_dir_path_len: usize = 0;
var replay_file_counter: u32 = 0;

/// Ensure the temp directory for scrollback replay files exists.
/// Returns the directory path, or null on failure.
fn ensureReplayDir() ?[]const u8 {
    if (replay_dir_path_len > 0) return replay_dir_path[0..replay_dir_path_len];

    const pid = std.c.getpid();
    const config_mod = @import("config.zig");
    const runtime_dir = config_mod.runtimeDir();

    const len = std.fmt.bufPrint(&replay_dir_path, "{s}/seance-scrollback-{d}", .{ runtime_dir, pid }) catch return null;

    replay_dir_path_len = len.len;

    std.Io.Dir.cwd().createDirPath(io.get(), len) catch return null;
    return len;
}

/// Write scrollback text to a temp file and set the path on the pane.
fn setScrollbackOnPane(pane: *Pane, scrollback: []const u8) void {
    if (scrollback.len == 0) return;
    const dir_path = ensureReplayDir() orelse return;

    // Ghostty's VT export prepends OSC 10/11/12 sequences that set the
    // terminal's fg/bg/cursor color to hardcoded RGB values from the
    // theme that was active at export time.  These override the config
    // defaults and prevent live theme changes from taking effect.
    // Strip them so the terminal uses whatever theme is currently active.
    const data = skipLeadingOscColors(scrollback);

    replay_file_counter += 1;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/pane-{d}.txt", .{ dir_path, replay_file_counter }) catch return;

    const file = std.Io.Dir.cwd().createFile(io.get(), file_path, .{}) catch |e| {
        std.log.warn("session: failed to create scrollback replay file: {s}", .{@errorName(e)});
        return;
    };
    // Wrap with SGR resets: leading reset clears partial style state from
    // truncation, trailing reset prevents scrollback styles leaking into prompt.
    file.writeStreamingAll(io.get(), "\x1b[0m") catch |e| {
        std.log.warn("session: failed to write scrollback replay data: {s}", .{@errorName(e)});
        file.close(io.get());
        return;
    };
    file.writeStreamingAll(io.get(), data) catch |e| {
        std.log.warn("session: failed to write scrollback replay data: {s}", .{@errorName(e)});
        file.close(io.get());
        return;
    };
    file.writeStreamingAll(io.get(), "\x1b[0m") catch |e| {
        std.log.warn("session: failed to write scrollback replay data: {s}", .{@errorName(e)});
        file.close(io.get());
        return;
    };
    file.close(io.get());

    if (file_path.len >= pane.replay_scrollback_path.len) return;
    @memcpy(pane.replay_scrollback_path[0..file_path.len], file_path);
    pane.replay_scrollback_path[file_path.len] = 0;
}

/// Remove the replay temp directory and all files in it.
pub fn cleanupReplayDir() void {
    if (replay_dir_path_len == 0) return;
    const path = replay_dir_path[0..replay_dir_path_len];

    var dir = std.Io.Dir.cwd().openDir(io.get(), path, .{ .iterate = true }) catch return;
    defer dir.close(io.get());
    var iter = dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        dir.deleteFile(io.get(), entry.name) catch {};
    }
    std.Io.Dir.cwd().deleteDir(io.get(), path) catch {};
    replay_dir_path_len = 0;
}

/// Clean stale replay dirs left by crashed instances.
pub fn cleanupStaleReplayDirs() void {
    // Scan the runtime directory for dirs matching the prefix and
    // remove those whose PID is no longer alive.
    const config_mod = @import("config.zig");
    const parent_dir_path = config_mod.runtimeDir();

    var dir = std.Io.Dir.cwd().openDir(io.get(), parent_dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io.get());
    var iter = dir.iterate();
    while (iter.next(io.get()) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "seance-scrollback-")) {
            const pid_str = entry.name["seance-scrollback-".len..];
            const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;
            // kill(pid, 0) returns 0 if process exists; returns negative errno otherwise.
            // ESRCH (-3) means no such process. EPERM means it exists but we can't signal it.
            std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => removeReplayDirEntries(dir, entry.name),
                else => {},
            };
        }
    }
}

fn removeReplayDirEntries(parent: std.Io.Dir, name: []const u8) void {
    var stale_dir = parent.openDir(io.get(), name, .{ .iterate = true }) catch return;
    defer stale_dir.close(io.get());
    var stale_iter = stale_dir.iterate();
    while (stale_iter.next(io.get()) catch null) |f| {
        stale_dir.deleteFile(io.get(), f.name) catch {};
    }
    parent.deleteDir(io.get(), name) catch {};
}

// ── JSON helpers ──────────────────────────────────────────────────────

fn writeKvStr(w: anytype, key: []const u8, val: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try writeJsonEscaped(w, val);
    try w.writeByte('"');
}

fn writeKvInt(w: anytype, key: []const u8, val: i64, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.print("{d}", .{val});
}

fn writeKvBool(w: anytype, key: []const u8, val: bool, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.writeAll(if (val) "true" else "false");
}

fn writeKvNull(w: anytype, key: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":null");
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

// ── Restore (multi-window) ───────────────────────────────────────────

const WindowState = @import("window.zig").WindowState;
const Window = @import("window.zig");

pub fn shouldRestore() bool {
    if (io.getenv("SEANCE_DISABLE_SESSION_RESTORE")) |_| return false;
    return true;
}

/// Load and restore session into the WindowManager, creating windows as needed.
pub fn loadAndRestoreAll(wm: anytype) bool {
    load_error.clear(); // Clear previous error
    if (!shouldRestore()) return false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getSessionPath(&path_buf) orelse {
        std.log.warn("session: cannot determine session path (HOME not set?)", .{});
        return false;
    };

    const alloc = wm.allocator;
    // The writer guarantees snapshots ≤ MAX_SNAPSHOT_BYTES; `.limited`
    // fails when the size reaches its argument, so read one byte past the
    // limit to accept exactly-at-limit files while still rejecting larger
    // ones.
    const data = std.Io.Dir.cwd().readFileAlloc(io.get(), path, alloc, .limited(session_storage.MAX_SNAPSHOT_BYTES + 1)) catch |e| {
        if (e != error.FileNotFound) {
            std.log.err("session: failed to read session file: {s}", .{@errorName(e)});
            load_error.set("Could not read session file: {s}", .{@errorName(e)});
        }
        return false;
    };
    defer alloc.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch {
        std.log.err("session: JSON parse error in session file", .{});
        load_error.set("Session file is corrupted (JSON parse error)", .{});
        return false;
    };
    defer parsed.deinit();

    return restoreFromJsonAll(wm, parsed.value);
}

fn restoreFromJsonAll(wm: anytype, root: std.json.Value) bool {
    const obj = switch (root) {
        .object => |o| o,
        else => return false,
    };

    const version = jsonInt(obj, "version") orelse return false;
    if (version != SESSION_VERSION) return false;

    const win_array = switch (obj.get("windows") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    if (win_array.items.len == 0) return false;

    var restored_count: usize = 0;
    for (win_array.items) |win_val| {
        const win_obj = switch (win_val) {
            .object => |o| o,
            else => continue,
        };

        const state = Window.create(wm) catch continue;
        wm.windows.append(wm.allocator, state) catch continue;
        wm.active_window = state;

        // Restore window dimensions. Ignore corrupt values so a bad session
        // file doesn't crash startup via an out-of-range @intCast.
        if (jsonInt(win_obj, "width")) |w| {
            if (jsonInt(win_obj, "height")) |h| {
                if (w > 0 and h > 0 and w <= 16384 and h <= 16384) {
                    c.gtk_window_set_default_size(
                        @as(*c.GtkWindow, @ptrCast(state.gtk_window)),
                        @intCast(w),
                        @intCast(h),
                    );
                }
            }
        }

        if (restoreWindowContent(state, win_obj)) {
            c.gtk_window_present(@as(*c.GtkWindow, @ptrCast(state.gtk_window)));
            restored_count += 1;
        } else {
            // Failed to restore — remove phantom window from list.
            // Mark destroyed first so onCloseRequest won't re-enter closeWindow.
            state.destroyed = true;
            for (wm.windows.items, 0..) |w, wi| {
                if (w == state) {
                    _ = wm.windows.orderedRemove(wi);
                    break;
                }
            }
            c.gtk_window_destroy(@as(*c.GtkWindow, @ptrCast(state.gtk_window)));
            wm.active_window = if (wm.windows.items.len > 0) wm.windows.items[wm.windows.items.len - 1] else null;
        }
    }

    return restored_count > 0;
}

/// Restore workspaces, sidebar visibility, etc. into a WindowState.
fn restoreWindowContent(state: *WindowState, obj: std.json.ObjectMap) bool {
    const ws_array = switch (obj.get("workspaces") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    if (ws_array.items.len == 0) return false;

    // Restore sidebar visibility
    if (jsonBool(obj, "sidebar_visible")) |vis| {
        state.sidebar_visible = vis;
    }

    var restored_count: usize = 0;
    for (ws_array.items) |ws_val| {
        if (restoreWorkspace(state, ws_val)) {
            restored_count += 1;
        }
    }

    if (restored_count == 0) return false;

    // Next ordinal after every restored workspace. nextOrdinal saturates at
    // the unallocated sentinel, so a saved maximum ordinal can be restored and
    // still leave the counter representable.
    var max_ord: u32 = 0;
    for (state.workspaces.items) |ws| {
        max_ord = @max(max_ord, port_allocation.nextOrdinal(ws.port_ordinal));
    }
    state.next_port_ordinal = max_ord;

    // Apply sidebar visibility to GTK widgets
    c.gtk_revealer_set_reveal_child(state.sidebar_revealer, if (state.sidebar_visible) 1 else 0);

    // Select active workspace
    const active_idx = jsonIndex(obj, "active_workspace");
    const clamped = if (state.workspaces.items.len > 0)
        @min(active_idx, state.workspaces.items.len - 1)
    else
        0;
    state.selectWorkspace(clamped);

    state.sidebar.refresh();
    state.sidebar.setActive(state.active_workspace);

    return true;
}

fn restoreWorkspace(state: *WindowState, ws_val: std.json.Value) bool {
    const obj = switch (ws_val) {
        .object => |o| o,
        else => return false,
    };

    const layout_val = obj.get("layout") orelse return false;
    const layout_obj = switch (layout_val) {
        .object => |o| o,
        else => return false,
    };
    const type_str = jsonStr(layout_obj, "type") orelse return false;
    if (!std.mem.eql(u8, type_str, "columns")) return false;

    return restoreWorkspaceColumns(state, obj, layout_obj);
}

/// Restore column layout.
fn restoreWorkspaceColumns(state: *WindowState, obj: std.json.ObjectMap, layout_obj: std.json.ObjectMap) bool {
    const Column = @import("column.zig").Column;
    const columns_array = switch (layout_obj.get("columns") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    if (columns_array.items.len == 0) return false;

    // Get CWD from first group of first column
    const first_cwd = blk: {
        const first_col = switch (columns_array.items[0]) {
            .object => |o| o,
            else => break :blk @as(?[]const u8, null),
        };
        const groups = switch (first_col.get("groups") orelse break :blk @as(?[]const u8, null)) {
            .array => |a| a,
            else => break :blk @as(?[]const u8, null),
        };
        if (groups.items.len == 0) break :blk @as(?[]const u8, null);
        const grp_obj = switch (groups.items[0]) {
            .object => |o| o,
            else => break :blk @as(?[]const u8, null),
        };
        break :blk getFirstCwdFromGroupObj(grp_obj);
    };

    var cwd_buf: [Pane.cwd_cap + 1]u8 = undefined;
    const cwd_z: ?[*:0]const u8 = if (first_cwd) |cwd_s| cwdblk: {
        const len = @min(cwd_s.len, cwd_buf.len - 1);
        @memcpy(cwd_buf[0..len], cwd_s[0..len]);
        cwd_buf[len] = 0;
        break :cwdblk @ptrCast(&cwd_buf);
    } else null;

    const ws = Workspace.createForRestore(state.alloc, cwd_z) catch return false;

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch "ws";
    _ = c.gtk_stack_add_named(state.content_stack, ws.container, name.ptr);
    state.workspaces.append(state.alloc, ws) catch {
        ws.destroy();
        return false;
    };

    applyWorkspaceMetadata(ws, obj);

    // Restore first column (already created with workspace)
    if (ws.columns.items.len > 0) {
        const first_col_obj = switch (columns_array.items[0]) {
            .object => |o| o,
            else => null,
        };
        if (first_col_obj) |co| {
            if (jsonFloat(co, "width")) |w| {
                const clamped = std.math.clamp(w, Column.min_width, Column.max_width);
                ws.columns.items[0].width = clamped;
                ws.columns.items[0].target_width = clamped;
            }
            if (jsonStr(co, "layout_mode")) |mode| {
                if (std.mem.eql(u8, mode, "tabbed")) {
                    ws.columns.items[0].layout_mode = .tabbed;
                    ws.columns.items[0].stacked_anim = 0.0;
                }
            }
            if (co.get("groups")) |groups_val| {
                const ga = switch (groups_val) {
                    .array => |a| a,
                    else => null,
                };
                if (ga) |groups| {
                    if (groups.items.len > 0) {
                        const go = switch (groups.items[0]) {
                            .object => |o| o,
                            else => null,
                        };
                        if (go) |grp_obj| {
                            restoreGroupPanels(ws.columns.items[0].groups.items[0], grp_obj, ws);
                        }
                    }
                }
            }
            // addColumn always enters stacked mode; if this column was saved
            // as tabbed, move panels back into AdwTabView now.  The onTick
            // animation won't trigger exitStackedMode because stacked_anim
            // is already at the target (0.0).
            if (ws.columns.items[0].layout_mode == .tabbed) {
                ws.columns.items[0].groups.items[0].exitStackedMode();
            }
        }
    }

    // Additional columns
    for (columns_array.items[1..]) |col_val| {
        const col_obj = switch (col_val) {
            .object => |o| o,
            else => continue,
        };
        const groups = switch (col_obj.get("groups") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        if (groups.items.len == 0) continue;

        const grp_obj = switch (groups.items[0]) {
            .object => |o| o,
            else => continue,
        };
        const grp_cwd = getFirstCwdFromGroupObj(grp_obj);
        var grp_cwd_buf: [Pane.cwd_cap + 1]u8 = undefined;
        const grp_cwd_z: ?[*:0]const u8 = if (grp_cwd) |s| grpblk: {
            const grplen = @min(s.len, grp_cwd_buf.len - 1);
            @memcpy(grp_cwd_buf[0..grplen], s[0..grplen]);
            grp_cwd_buf[grplen] = 0;
            break :grpblk @ptrCast(&grp_cwd_buf);
        } else null;

        const new_grp = ws.addColumn(grp_cwd_z) catch continue;

        // Set column width and layout mode
        const new_col_idx = ws.columns.items.len - 1;
        if (jsonFloat(col_obj, "width")) |w| {
            const clamped = std.math.clamp(w, Column.min_width, Column.max_width);
            ws.columns.items[new_col_idx].width = clamped;
            ws.columns.items[new_col_idx].target_width = clamped;
        }
        if (jsonStr(col_obj, "layout_mode")) |mode| {
            if (std.mem.eql(u8, mode, "tabbed")) {
                ws.columns.items[new_col_idx].layout_mode = .tabbed;
                ws.columns.items[new_col_idx].stacked_anim = 0.0;
            }
        }
        restoreGroupPanels(new_grp, grp_obj, ws);
        // Same as above: exit stacked mode for tabbed columns.
        if (ws.columns.items[new_col_idx].layout_mode == .tabbed) {
            new_grp.exitStackedMode();
        }
    }

    // Restore focused column
    const focused = jsonIndex(layout_obj, "focused_column");
    ws.focused_column = @min(focused, if (ws.columns.items.len > 0) ws.columns.items.len - 1 else 0);

    // Restore camera position
    if (jsonFloat(obj, "camera")) |cam| {
        ws.camera = cam;
        ws.camera_target = cam;
    }

    return true;
}

fn getFirstCwdFromGroupObj(obj: std.json.ObjectMap) ?[]const u8 {
    const panels_array = switch (obj.get("panels") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (panels_array.items.len == 0) return null;
    const first_panel = switch (panels_array.items[0]) {
        .object => |o| o,
        else => return null,
    };
    return jsonStr(first_panel, "cwd");
}

fn restoreGroupPanels(group: *PaneGroup, obj: std.json.ObjectMap, ws: *Workspace) void {
    const panels_array = switch (obj.get("panels") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (panels_array.items.len == 0) return;

    // Check first panel type — if it's webkit, replace the pre-existing terminal
    const first_panel_obj = switch (panels_array.items[0]) {
        .object => |o| o,
        else => null,
    };

    if (first_panel_obj) |fpo| {
        const first_type = jsonStr(fpo, "type");
        if (first_type) |t| {
            if (std.mem.eql(u8, t, "webkit")) {
                // Remove the default terminal pane and replace with webkit
                if (group.panels.items.len > 0) {
                    _ = group.removePanel(0);
                }
                const url = jsonStr(fpo, "url") orelse "about:blank";
                const wp = group.newBrowserPanel(url) catch return;
                wp.setCloseCallback(&Workspace.closeBrowserColumn, @ptrCast(ws));
                wp.setFocusCallback(&Workspace.onBrowserEntryFocus, @ptrCast(ws));
            } else {
                // Terminal: restore scrollback, title, weight as before
                if (group.panels.items.len > 0) {
                    restorePanelScrollback(group.panels.items[0], fpo);
                    restorePanelCustomTitle(group, group.panels.items[0], fpo);
                    restorePanelHeightWeight(group.panels.items[0], fpo);
                }
            }
        } else {
            // No type field — backward compat, treat as terminal
            if (group.panels.items.len > 0) {
                restorePanelScrollback(group.panels.items[0], fpo);
                restorePanelCustomTitle(group, group.panels.items[0], fpo);
                restorePanelHeightWeight(group.panels.items[0], fpo);
            }
        }
    }

    // Restore additional panels
    for (panels_array.items[1..]) |panel_val| {
        const panel_obj = switch (panel_val) {
            .object => |o| o,
            else => continue,
        };
        const panel_type = jsonStr(panel_obj, "type") orelse continue;
        if (std.mem.eql(u8, panel_type, "terminal")) {
            var panel_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = getTerminalPanelCwd(&panel_cwd_buf, panel_obj);
            const pane = group.newPanel(cwd) catch continue;
            const panel = Panel{ .terminal = pane };
            restorePanelScrollback(panel, panel_obj);
            restorePanelCustomTitle(group, panel, panel_obj);
            restorePanelHeightWeight(panel, panel_obj);
        } else if (std.mem.eql(u8, panel_type, "webkit")) {
            const url = jsonStr(panel_obj, "url") orelse "about:blank";
            const wp = group.newBrowserPanel(url) catch continue;
            wp.setCloseCallback(&Workspace.closeBrowserColumn, @ptrCast(ws));
            wp.setFocusCallback(&Workspace.onBrowserEntryFocus, @ptrCast(ws));
        }
    }

    // Restore active panel
    const active = jsonIndex(obj, "active_panel");
    group.switchToPanel(@min(active, if (group.panels.items.len > 0) group.panels.items.len - 1 else 0));

    // Each panel is seated as it is inserted, before its saved weight is
    // applied, so the rows do not match the saved layout until re-seated.
    if (group.in_stacked_mode) {
        group.tileStackedRows();
        group.needs_stacked_layout = true;
    }
}

fn applyWorkspaceMetadata(ws: *Workspace, obj: std.json.ObjectMap) void {
    if (jsonStr(obj, "title")) |t| ws.setTitle(t);
    if (jsonStr(obj, "custom_title")) |t| ws.setCustomTitle(t);
    if (jsonStr(obj, "custom_color")) |col| ws.setCustomColor(col);
    if (jsonBool(obj, "is_pinned")) |p| {
        if (p) ws.is_pinned = true;
    }
    if (jsonInt(obj, "port_ordinal")) |ord| {
        const clamped = @min(@max(@as(i64, 0), ord), @as(i64, std.math.maxInt(u32)));
        ws.port_ordinal = @intCast(clamped);
    }
}

fn restorePanelScrollback(panel: Panel, obj: std.json.ObjectMap) void {
    switch (panel) {
        .terminal => |pane| {
            const scrollback = jsonStr(obj, "scrollback") orelse return;
            if (scrollback.len == 0) return;
            setScrollbackOnPane(pane, scrollback);
        },
        .webkit => {},
    }
}

fn restorePanelCustomTitle(group: *PaneGroup, panel: Panel, obj: std.json.ObjectMap) void {
    const title = jsonStr(obj, "custom_title") orelse return;
    if (title.len == 0) return;
    const pane = panel.asTerminal() orelse return;
    pane.setCustomTitle(title);
    group.updateTitleForPane(pane.id, title);
}

fn restorePanelHeightWeight(panel: Panel, obj: std.json.ObjectMap) void {
    const w = jsonFloat(obj, "height_weight") orelse return;
    const pane = panel.asTerminal() orelse return;
    pane.height_weight = std.math.clamp(w, 0.1, 10.0);
}

fn getTerminalPanelCwd(buf: *[std.fs.max_path_bytes]u8, obj: std.json.ObjectMap) ?[*:0]const u8 {
    const cwd = jsonStr(obj, "cwd") orelse return null;
    return getCwdZ(buf, cwd);
}

/// Convert a CWD slice to a null-terminated pointer using a caller-provided buffer.
fn getCwdZ(buf: *[std.fs.max_path_bytes]u8, cwd: []const u8) ?[*:0]const u8 {
    if (cwd.len == 0 or cwd.len >= buf.len) return null;
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0;
    return @ptrCast(buf);
}

// ── JSON read helpers ─────────────────────────────────────────────────

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Read a non-negative list index from JSON. Negative or missing values yield 0;
/// values larger than i32 max are capped. Callers still clamp against list length.
fn jsonIndex(obj: std.json.ObjectMap, key: []const u8) usize {
    const v = jsonInt(obj, key) orelse return 0;
    if (v < 0) return 0;
    return @intCast(@min(v, @as(i64, std.math.maxInt(i32))));
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Skip leading OSC 10/11/12 color-setting sequences that ghostty's VT
/// export prepends.  These bake in RGB values from the export-time theme
/// and would override the terminal's configured defaults, preventing live
/// theme changes.  Returns the slice starting after the last skipped OSC.
fn skipLeadingOscColors(input: []const u8) []const u8 {
    var i: usize = 0;
    while (i < input.len) {
        // OSC starts with ESC ]
        if (i + 1 < input.len and input[i] == 0x1b and input[i + 1] == ']') {
            const osc_start = i;
            i += 2;
            // Check for OSC 10, 11, or 12 followed by ';'
            const is_color_osc = blk: {
                if (i + 2 < input.len and input[i] == '1' and (input[i + 1] == '0' or input[i + 1] == '1' or input[i + 1] == '2') and input[i + 2] == ';')
                    break :blk true;
                break :blk false;
            };
            if (!is_color_osc) return input[osc_start..];
            // Skip until ST (\x1b\\) or BEL (\x07)
            while (i < input.len) {
                if (input[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            // Continue checking for more OSC color sequences
        } else {
            break;
        }
    }
    return input[i..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// --- truncateScrollback ---

test "truncateScrollback: short text unchanged" {
    const text = "Hello\nWorld\n";
    const result = truncateScrollback(text);
    try testing.expectEqualStrings(text, result);
}

test "truncateScrollback: enforces line limit" {
    const excess = 10;
    const total_lines = MAX_SCROLLBACK_LINES + excess;
    // Build "X\n" repeated total_lines times
    var text: [total_lines * 2]u8 = undefined;
    for (0..total_lines) |i| {
        text[i * 2] = 'X';
        text[i * 2 + 1] = '\n';
    }
    const result = truncateScrollback(&text);
    var newline_count: usize = 0;
    for (result) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    try testing.expect(result.len < text.len);
    try testing.expect(newline_count <= MAX_SCROLLBACK_LINES);
    // Should still be close to the limit (only trimmed `excess` lines)
    try testing.expect(newline_count >= MAX_SCROLLBACK_LINES - excess);
}

test "truncateScrollback: enforces char limit" {
    const alloc = testing.allocator;
    const size = MAX_SCROLLBACK_CHARS + 1000;
    const text = try alloc.alloc(u8, size);
    defer alloc.free(text);
    @memset(text, 'A');
    // Few newlines — line limit won't trigger
    text[size - 50] = '\n';
    const result = truncateScrollback(text);
    try testing.expect(result.len <= MAX_SCROLLBACK_CHARS);
}

test "truncateScrollback: both limits — char applied first then lines" {
    const alloc = testing.allocator;
    // Exceed char limit with many short lines
    const line = "ABCDEFGHIJ\n"; // 11 bytes per line
    const lines_needed = (MAX_SCROLLBACK_CHARS / line.len) + 100;
    const size = lines_needed * line.len;
    const text = try alloc.alloc(u8, size);
    defer alloc.free(text);
    for (0..lines_needed) |i| {
        @memcpy(text[i * line.len ..][0..line.len], line);
    }
    const result = truncateScrollback(text);
    try testing.expect(result.len <= MAX_SCROLLBACK_CHARS);
    var newline_count: usize = 0;
    for (result) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    try testing.expect(newline_count <= MAX_SCROLLBACK_LINES);
}

// --- skipLeadingOscColors ---

test "skipLeadingOscColors: no OSC sequences" {
    const text = "hello world";
    try testing.expectEqualStrings(text, skipLeadingOscColors(text));
}

test "skipLeadingOscColors: strips OSC 10 (fg color)" {
    const text = "\x1b]10;rgb:dd/dd/dd\x1b\\hello";
    try testing.expectEqualStrings("hello", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: strips OSC 11 (bg color)" {
    const text = "\x1b]11;rgb:10/20/40\x1b\\hello";
    try testing.expectEqualStrings("hello", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: strips OSC 12 (cursor color)" {
    const text = "\x1b]12;rgb:ff/ff/00\x1b\\hello";
    try testing.expectEqualStrings("hello", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: strips multiple OSC color sequences" {
    const text = "\x1b]10;rgb:dd/dd/dd\x1b\\\x1b]11;rgb:10/20/40\x1b\\content";
    try testing.expectEqualStrings("content", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: strips BEL-terminated OSC" {
    const text = "\x1b]10;rgb:dd/dd/dd\x07hello";
    try testing.expectEqualStrings("hello", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: preserves non-color OSC (e.g. title)" {
    const text = "\x1b]0;my title\x1b\\hello";
    try testing.expectEqualStrings(text, skipLeadingOscColors(text));
}

test "skipLeadingOscColors: preserves OSC after non-OSC content" {
    const text = "x\x1b]10;rgb:dd/dd/dd\x1b\\hello";
    try testing.expectEqualStrings(text, skipLeadingOscColors(text));
}

test "skipLeadingOscColors: realistic ghostty VT export header" {
    const text = "\x1b]10;rgb:dd/dd/dd\x1b\\\x1b]11;rgb:10/20/40\x1b\\\r\n\x1b[0m\x1b[1m\x1b[38;5;6m~\x1b[0m";
    try testing.expectEqualStrings("\r\n\x1b[0m\x1b[1m\x1b[38;5;6m~\x1b[0m", skipLeadingOscColors(text));
}

test "skipLeadingOscColors: empty input" {
    try testing.expectEqualStrings("", skipLeadingOscColors(""));
}

test "skipLeadingOscColors: unterminated OSC is consumed" {
    const text = "\x1b]10;rgb:dd/dd/dd";
    try testing.expectEqualStrings("", skipLeadingOscColors(text));
}

// --- ansiSafeTruncationStart ---

test "ansiSafeTruncationStart: empty text" {
    const result = ansiSafeTruncationStart("");
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "ansiSafeTruncationStart: starts with ESC is unchanged" {
    const text = "\x1b[31mHello";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings(text, result);
}

test "ansiSafeTruncationStart: mid-CSI skips past final byte" {
    // Simulates truncation landing after ESC[ in "\x1b[31;1mHello"
    const text = "31;1mHello";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings("Hello", result);
}

test "ansiSafeTruncationStart: mid-CSI with intermediate bytes" {
    // CSI with intermediate byte: e.g. cursor style ESC[0 q
    // Truncation lands at "0 qText"
    const text = "0 qText";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings("Text", result);
}

test "ansiSafeTruncationStart: normal text unchanged" {
    const text = "Hello World";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings(text, result);
}

test "ansiSafeTruncationStart: text with nearby ESC skips to it" {
    const text = "ab\x1b[32mGreen";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings("\x1b[32mGreen", result);
}

test "ansiSafeTruncationStart: newline before ESC stops fallback scan" {
    // Fallback scan stops at newline, so text is returned as-is
    const text = "ab\ncd\x1b[0m";
    const result = ansiSafeTruncationStart(text);
    try testing.expectEqualStrings(text, result);
}

// --- writeJsonEscaped ---

test "writeJsonEscaped: normal text passthrough" {
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&fbs, "hello world");
    try testing.expectEqualStrings("hello world", fbs.buffered());
}

test "writeJsonEscaped: quotes and backslashes" {
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&fbs, "say \"hello\" \\ there");
    try testing.expectEqualStrings("say \\\"hello\\\" \\\\ there", fbs.buffered());
}

test "writeJsonEscaped: named control characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&fbs, "a\nb\tc\rd");
    try testing.expectEqualStrings("a\\nb\\tc\\rd", fbs.buffered());
}

test "writeJsonEscaped: other control characters use unicode escape" {
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&fbs, "\x01\x1f");
    try testing.expectEqualStrings("\\u0001\\u001f", fbs.buffered());
}

test "writeJsonEscaped: round trip with JSON parser" {
    const alloc = testing.allocator;
    const original = "line1\nline2\ttab\r\n\"quoted\" and \\backslash\x01";

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const w = &fbs;
    try w.writeByte('"');
    try writeJsonEscaped(w, original);
    try w.writeByte('"');

    const json_str = fbs.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .string => |s| try testing.expectEqualStrings(original, s),
        else => return error.TestUnexpectedResult,
    }
}

test "writeJsonEscaped: NUL character" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&fbs, "\x00");
    try testing.expectEqualStrings("\\u0000", fbs.buffered());
}

// --- readScrollbackWindow ---

fn writeFixture(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const file = try tmp.dir.createFile(io.get(), name, .{});
    defer file.close(io.get());
    try file.writeStreamingAll(io.get(), bytes);
}

fn readWindowFixture(tmp: *testing.TmpDir, name: []const u8, alloc: Allocator) !ScrollbackWindow {
    const file = try tmp.dir.openFile(io.get(), name, .{});
    defer file.close(io.get());
    return readScrollbackWindow(file, alloc);
}

test "readScrollbackWindow: keeps the newest suffix of a huge history" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const max_read = MAX_SCROLLBACK_CHARS + 64 * 1024;

    // Fixture exceeds the read window; the head marker falls out of range
    // while the newest tail marker must be retained.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "OLDEST_HEAD_MARKER\n");
    const filler_line = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    while (list.items.len < max_read + 1000) {
        try list.appendSlice(testing.allocator, filler_line);
    }
    try list.appendSlice(testing.allocator, "NEWEST_TAIL_MARKER\n");
    try writeFixture(&tmp, "big.txt", list.items);

    const window = try readWindowFixture(&tmp, "big.txt", testing.allocator);
    defer testing.allocator.free(window.buffer);

    try testing.expect(window.text.len > 0);
    try testing.expect(window.text.len <= MAX_SCROLLBACK_CHARS);
    try testing.expect(std.mem.indexOf(u8, window.text, "NEWEST_TAIL_MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, window.text, "OLDEST_HEAD_MARKER") == null);
}

test "readScrollbackWindow: snaps a mid-CSI cut onto the next sequence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const max_read = MAX_SCROLLBACK_CHARS + 64 * 1024;
    const size = max_read + 500; // exceeds the window so the suffix path seeks
    // The char cut keeps file index `size - MAX_SCROLLBACK_CHARS`; place
    // "\x1b[31m" so that index lands on its parameter bytes.
    const cut_index = size - MAX_SCROLLBACK_CHARS;
    const csi_and_tail = "\x1b[31mTAIL_AFTER_CSI\n";

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendNTimes(testing.allocator, 'A', cut_index - 2);
    try list.appendSlice(testing.allocator, csi_and_tail);
    try list.appendNTimes(testing.allocator, 'B', size - (cut_index - 2 + csi_and_tail.len));
    try writeFixture(&tmp, "csi.txt", list.items);

    const window = try readWindowFixture(&tmp, "csi.txt", testing.allocator);
    defer testing.allocator.free(window.buffer);

    try testing.expect(std.mem.startsWith(u8, window.text, "TAIL_AFTER_CSI"));
    try testing.expect(!std.mem.startsWith(u8, window.text, "31m"));
}

test "readScrollbackWindow: snaps a mid-character cut onto a UTF-8 boundary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const max_read = MAX_SCROLLBACK_CHARS + 64 * 1024;
    const size = max_read; // read whole: cut happens inside the file
    const cut_index = size - MAX_SCROLLBACK_CHARS;
    // Straddle the cut with a two-byte character: keep its lead byte
    // before the cut and land the cut on the continuation byte.
    const marker_and_tail = "\xC3\xA9TAIL_UTF8_BOUNDARY\n";

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendNTimes(testing.allocator, 'A', cut_index - 1);
    try list.appendSlice(testing.allocator, marker_and_tail);
    try list.appendNTimes(testing.allocator, 'B', size - (cut_index - 1 + marker_and_tail.len));
    try writeFixture(&tmp, "utf8.txt", list.items);

    const window = try readWindowFixture(&tmp, "utf8.txt", testing.allocator);
    defer testing.allocator.free(window.buffer);

    try testing.expect(std.mem.startsWith(u8, window.text, "TAIL_UTF8_BOUNDARY"));
    try testing.expect(std.unicode.utf8ValidateSlice(window.text));
}

test "readScrollbackWindow: short and empty files are read whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixture(&tmp, "short.txt", "line one\nline two\n");
    const window = try readWindowFixture(&tmp, "short.txt", testing.allocator);
    defer testing.allocator.free(window.buffer);
    try testing.expectEqualStrings("line one\nline two\n", window.text);

    try writeFixture(&tmp, "empty.txt", "");
    const empty = try readWindowFixture(&tmp, "empty.txt", testing.allocator);
    defer testing.allocator.free(empty.buffer);
    try testing.expectEqual(@as(usize, 0), empty.text.len);
}

// --- snapshot size budget ---

test "jsonEscapedLen: matches the writer's escaped output exactly" {
    const samples = [_][]const u8{
        "",
        "plain text",
        "quote\" back\\slash",
        "new\nline\ttab\rret",
        "\x01\x1f\x7f",
        "ünïcödé ✓ 日本語",
    };
    for (samples) |s| {
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        try writeJsonEscaped(&fbs, s);
        try testing.expectEqual(fbs.buffered().len, jsonEscapedLen(s));
    }
    // Control-heavy: every byte costs the six-byte \u00XX form.
    const heavy = try testing.allocator.alloc(u8, 1_000);
    defer testing.allocator.free(heavy);
    @memset(heavy, 0x01);
    var heavy_buf: [6_000]u8 = undefined;
    var heavy_fbs = std.Io.Writer.fixed(&heavy_buf);
    try writeJsonEscaped(&heavy_fbs, heavy);
    try testing.expectEqual(@as(usize, 6_000), heavy_fbs.buffered().len);
    try testing.expectEqual(heavy_fbs.buffered().len, jsonEscapedLen(heavy));
}

test "sliceNewestEscaped: exact-at-limit keeps the text, over-limit keeps only the newest suffix" {
    const text = "line1\nline2\nquote\"done\"";
    const full = jsonEscapedLen(text);
    try testing.expectEqualStrings(text, sliceNewestEscaped(text, full));

    const sliced = sliceNewestEscaped(text, full - 1);
    try testing.expect(sliced.len < text.len);
    try testing.expect(std.mem.endsWith(u8, text, sliced));
    try testing.expect(jsonEscapedLen(sliced) <= full - 1);
}

test "sliceNewestEscaped: a budget cut inside a character snaps to a valid boundary" {
    const text = "AAAAéTAIL";
    // Budget 5 lands the backward walk on the continuation byte of "é".
    const sliced = sliceNewestEscaped(text, 5);
    try testing.expect(std.mem.startsWith(u8, sliced, "TAIL"));
    try testing.expect(std.unicode.utf8ValidateSlice(sliced));
    try testing.expect(jsonEscapedLen(sliced) <= 5);
}

test "distributeHistoryBudget: passes full costs through when everything fits" {
    const costs = [_]usize{ 5, 10, 15 };
    var out: [3]usize = undefined;
    distributeHistoryBudget(100, &costs, &out);
    try testing.expectEqualSlices(usize, &costs, &out);
}

test "distributeHistoryBudget: many over-budget histories stay bounded and deterministic" {
    var costs: [37]usize = undefined;
    for (&costs, 0..) |*cost, i| cost.* = 1_000 + i * 17;
    const available = 20_000; // total is ~48k: forced over budget
    var out: [37]usize = undefined;
    distributeHistoryBudget(available, &costs, &out);

    var total: usize = 0;
    for (out, costs) |allowance, cost| {
        try testing.expect(allowance <= cost);
        total += allowance;
    }
    try testing.expect(total <= available);

    var again: [37]usize = undefined;
    distributeHistoryBudget(available, &costs, &again);
    try testing.expectEqualSlices(usize, &out, &again);
}

test "enforceSnapshotBudget: rejects anything above the shared limit" {
    try testing.expectError(error.SnapshotTooLarge, enforceSnapshotBudget(session_storage.MAX_SNAPSHOT_BYTES + 1));
    try enforceSnapshotBudget(session_storage.MAX_SNAPSHOT_BYTES);
    try enforceSnapshotBudget(0);
}

test "budgeted histories: a many-pane snapshot parses, fits and keeps every entry" {
    const n = 33;
    const text_len = 500_000;
    const text = try testing.allocator.alloc(u8, text_len);
    defer testing.allocator.free(text);
    @memset(text, 'A');

    // Metadata-heavy layout floor with null histories.
    var layout: std.ArrayList(u8) = .empty;
    defer layout.deinit(testing.allocator);
    try layout.appendSlice(testing.allocator, "{\"version\":1,\"created_at\":0,\"pad\":\"");
    try layout.appendNTimes(testing.allocator, 'A', 100_000);
    try layout.appendSlice(testing.allocator, "\",\"windows\":[");
    for (0..n) |i| {
        if (i > 0) try layout.appendSlice(testing.allocator, ",");
        var id_buf: [48]u8 = undefined;
        const head = try std.fmt.bufPrint(&id_buf, "{{\"id\":{d},\"history\":null}}", .{i});
        try layout.appendSlice(testing.allocator, head);
    }
    try layout.appendSlice(testing.allocator, "]}");
    try enforceSnapshotBudget(layout.items.len);

    // The full histories (~16.5 MB) exceed the remaining budget, so the
    // deterministic division must slice every one of them.
    var costs: [n]usize = undefined;
    for (&costs) |*cost| cost.* = 2 + jsonEscapedLen(text);
    var allowances: [n]usize = undefined;
    const available = session_storage.MAX_SNAPSHOT_BYTES - layout.items.len;
    distributeHistoryBudget(available, &costs, &allowances);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(testing.allocator);
    try doc.appendSlice(testing.allocator, "{\"version\":1,\"created_at\":0,\"pad\":\"");
    try doc.appendNTimes(testing.allocator, 'A', 100_000);
    try doc.appendSlice(testing.allocator, "\",\"windows\":[");
    for (0..n) |i| {
        if (i > 0) try doc.appendSlice(testing.allocator, ",");
        var id_buf: [48]u8 = undefined;
        const head = try std.fmt.bufPrint(&id_buf, "{{\"id\":{d},\"history\":\"", .{i});
        try doc.appendSlice(testing.allocator, head);
        const slice = sliceNewestEscaped(text, allowances[i]);
        try testing.expect(slice.len > 0);
        try doc.appendSlice(testing.allocator, slice);
        try doc.appendSlice(testing.allocator, "\"}");
    }
    try doc.appendSlice(testing.allocator, "]}");

    try testing.expect(doc.items.len <= session_storage.MAX_SNAPSHOT_BYTES);
    try enforceSnapshotBudget(doc.items.len);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc.items, .{});
    defer parsed.deinit();
    const wins = switch (parsed.value) {
        .object => |o| o.get("windows") orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    const arr = switch (wins) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, n), arr.items.len);
    for (arr.items) |wv| {
        const obj = switch (wv) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const hist = obj.get("history") orelse return error.TestUnexpectedResult;
        try testing.expect(hist == .string);
        try testing.expect(hist.string.len > 0);
    }
}
