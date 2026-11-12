const std = @import("std");
const io = @import("io.zig");
const text_mod = @import("text.zig");

/// Identity 0 is never assigned, so it can stand for "no notification".
pub const invalid_id: u64 = 0;
/// Highest identity the store will assign; hitting it refuses new pushes
/// instead of wrapping onto a live record.
pub const max_notification_id: u64 = std.math.maxInt(u64) - 1;

pub const Notification = struct {
    /// Stable identity, assigned by `NotificationStore.push`.
    id: u64 = invalid_id,
    pane_id: u64,
    workspace_id: u64,
    pane_group_id: u64,
    title: [256]u8 = [_]u8{0} ** 256,
    title_len: usize = 0,
    subtitle: [256]u8 = [_]u8{0} ** 256,
    subtitle_len: usize = 0,
    body: [512]u8 = [_]u8{0} ** 512,
    body_len: usize = 0,
    timestamp: i64,
    read: bool = false,

    pub fn getTitle(self: *const Notification) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getSubtitle(self: *const Notification) []const u8 {
        return self.subtitle[0..self.subtitle_len];
    }

    pub fn getBody(self: *const Notification) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn setTitle(self: *Notification, text: []const u8) void {
        self.title_len = text_mod.copy(&self.title, text);
    }

    pub fn setSubtitle(self: *Notification, text: []const u8) void {
        self.subtitle_len = text_mod.copy(&self.subtitle, text);
    }

    pub fn setBody(self: *Notification, text: []const u8) void {
        self.body_len = text_mod.copy(&self.body, text);
    }
};

pub const NotificationStore = struct {
    items: [100]?Notification = [_]?Notification{null} ** 100,
    head: usize = 0,
    count: usize = 0,
    next_id: u64 = 1,

    /// Assign the next identity and store `notif`; any id on the argument is
    /// ignored. Returns false when identities are exhausted, in which case the
    /// notification is dropped rather than reusing a live identity.
    pub fn push(self: *NotificationStore, notif: Notification) bool {
        const id = self.allocateId() orelse {
            std.log.warn("notification: identity space exhausted; dropping notification", .{});
            return false;
        };
        var stored = notif;
        stored.id = id;
        self.items[self.head] = stored;
        self.head = (self.head + 1) % self.items.len;
        if (self.count < self.items.len) {
            self.count += 1;
        }
        return true;
    }

    fn allocateId(self: *NotificationStore) ?u64 {
        if (self.next_id == invalid_id or self.next_id > max_notification_id) return null;
        const id = self.next_id;
        self.next_id = id + 1;
        return id;
    }

    pub fn unreadCount(self: *const NotificationStore) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (!item.read) n += 1;
            }
        }
        return n;
    }

    pub fn unreadForWorkspace(self: *const NotificationStore, ws_id: u64) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (!item.read and item.workspace_id == ws_id) n += 1;
            }
        }
        return n;
    }

    pub fn markAllRead(self: *NotificationStore, ws_id: u64) void {
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (item.workspace_id == ws_id) item.read = true;
            }
        }
    }

    /// Mark all notifications for a pane as read, preserving them as history.
    pub fn markAllReadForPane(self: *NotificationStore, pane_id: u64) void {
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (item.pane_id == pane_id) item.read = true;
            }
        }
    }

    pub fn unreadForPane(self: *const NotificationStore, pane_id: u64) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (!item.read and item.pane_id == pane_id) n += 1;
            }
        }
        return n;
    }

    /// Mark the notification at logical index (0 = newest) as read.
    pub fn markReadAt(self: *NotificationStore, index: usize) void {
        if (self.getByIndex(index)) |item| item.read = true;
    }

    pub fn mostRecentUnread(self: *const NotificationStore) ?*const Notification {
        if (self.count == 0) return null;
        // Iterate from newest to oldest
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (!item.read) return item;
            }
        }
        return null;
    }

    /// Return the latest notification for a workspace, prioritizing unread.
    /// Falls back to the latest read notification if no unread exist (seance behavior).
    pub fn latestForWorkspace(self: *const NotificationStore, ws_id: u64) ?*const Notification {
        if (self.count == 0) return null;
        var latest_any: ?*const Notification = null;
        // Iterate from newest to oldest
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (item.workspace_id == ws_id) {
                    if (!item.read) return item; // Unread found — return immediately
                    if (latest_any == null) latest_any = item; // Track latest (any status)
                }
            }
        }
        return latest_any;
    }

    /// Get notification by logical index (0 = newest, count-1 = oldest).
    pub fn getByIndex(self: *NotificationStore, index: usize) ?*Notification {
        if (index >= self.count) return null;
        // Map display index (0=newest) to ring offset (count-1=newest)
        const offset = self.count - 1 - index;
        const idx = self.ringIndex(offset);
        if (self.items[idx]) |*item| return item else return null;
    }

    /// Identity of the record at logical index (0 = newest).
    pub fn idAtIndex(self: *const NotificationStore, index: usize) ?u64 {
        if (index >= self.count) return null;
        const offset = self.count - 1 - index;
        const idx = self.ringIndex(offset);
        if (self.items[idx]) |item| return item.id;
        return null;
    }

    /// Logical index (0 = newest) of a live identity.
    pub fn indexOfId(self: *const NotificationStore, id: u64) ?usize {
        if (id == invalid_id) return null;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (item.id == id) return self.count - 1 - i;
            }
        }
        return null;
    }

    /// Live record for an identity; null for invalid, evicted or cleared ids.
    pub fn findById(self: *NotificationStore, id: u64) ?*Notification {
        const index = self.indexOfId(id) orelse return null;
        return self.getByIndex(index);
    }

    /// Mark one record read by identity. False when the id is no longer live.
    pub fn markReadById(self: *NotificationStore, id: u64) bool {
        const item = self.findById(id) orelse return false;
        item.read = true;
        return true;
    }

    /// Remove one record by identity. False when the id is no longer live.
    pub fn removeById(self: *NotificationStore, id: u64) bool {
        const index = self.indexOfId(id) orelse return false;
        self.removeAt(index);
        return true;
    }

    /// Remove notification at logical index (0 = newest).
    pub fn removeAt(self: *NotificationStore, index: usize) void {
        if (index >= self.count) return;
        const offset = self.count - 1 - index;
        // Shift items to fill the gap: move items at offset+1..count-1 down by one
        var i: usize = offset;
        while (i + 1 < self.count) : (i += 1) {
            const dst = self.ringIndex(i);
            const src = self.ringIndex(i + 1);
            self.items[dst] = self.items[src];
        }
        // Clear the last slot (was newest before shift)
        const last = self.ringIndex(self.count - 1);
        self.items[last] = null;
        self.count -= 1;
        // Adjust head: the newest slot was vacated, so head retreats by one.
        self.head = (self.head + self.items.len - 1) % self.items.len;
    }

    /// Remove all notifications whose workspace_id matches.
    pub fn removeForWorkspace(self: *NotificationStore, workspace_id: u64) usize {
        return self.removeMatching(.workspace, workspace_id);
    }

    /// Remove all notifications whose pane_id matches.
    pub fn removeForPane(self: *NotificationStore, pane_id: u64) usize {
        return self.removeMatching(.pane, pane_id);
    }

    const MatchKind = enum { workspace, pane };

    fn removeMatching(self: *NotificationStore, kind: MatchKind, id: u64) usize {
        if (self.count == 0) return 0;
        // Collect surviving items into a temporary array, then copy back.
        var survivors: [100]Notification = undefined;
        var survivor_count: usize = 0;
        var removed: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                const matches = switch (kind) {
                    .workspace => item.workspace_id == id,
                    .pane => item.pane_id == id,
                };
                if (matches) {
                    removed += 1;
                } else {
                    survivors[survivor_count] = item;
                    survivor_count += 1;
                }
            }
        }
        if (removed == 0) return 0;
        // Reset and repopulate
        for (0..self.items.len) |i| self.items[i] = null;
        self.head = 0;
        self.count = 0;
        for (0..survivor_count) |i| {
            self.items[self.head] = survivors[i];
            self.head = (self.head + 1) % self.items.len;
            self.count += 1;
        }
        return removed;
    }

    /// Remove all notifications.
    pub fn clearAll(self: *NotificationStore) void {
        for (0..self.items.len) |i| {
            self.items[i] = null;
        }
        self.head = 0;
        self.count = 0;
    }

    fn ringIndex(self: *const NotificationStore, offset: usize) usize {
        // offset 0 = oldest, offset count-1 = newest
        // General formula that works whether the ring has wrapped or not.
        return (self.head + self.items.len - self.count + offset) % self.items.len;
    }
};

pub const NotificationCenter = struct {
    store: NotificationStore = .{},
    ctx: ?*anyopaque = null, // WindowState pointer (opaque to avoid circular import)
    // Set when a notification is activated, so the focus churn the jump
    // produces does not blanket-mark the pane's sibling alerts read: only the
    // record the user acted on was read. Activating a row focuses its pane and
    // GTK focuses the pane again when the popover closes, and how many
    // transitions occur depends on scheduling, so the suppression is bounded by
    // time rather than by a count of focus events. Once the window expires,
    // focusing the pane marks its alerts read as usual.
    suppress_focus_mark_read: bool = false,
    suppress_focus_pane_id: ?u64 = null,
    suppress_focus_until_ms: i64 = 0,

    // Callbacks (wired by window.zig during init)
    on_sidebar_refresh: ?*const fn (*anyopaque) void = null,
    on_play_sound: ?*const fn (*anyopaque) void = null,
    on_pane_notify: ?*const fn (*anyopaque, bool) void = null,
    on_pane_trigger_flash: ?*const fn (*anyopaque) void = null,
    on_tab_badge_update: ?*const fn (*anyopaque, u64, bool) void = null,
    on_desktop_notify: ?*const fn ([*:0]const u8, [*:0]const u8) void = null,
    on_find_pane: ?*const fn (*anyopaque, u64) ?*anyopaque = null,
    on_check_visible: ?*const fn (*anyopaque, u64, u64) Visibility = null,
    on_clear_ws_visuals: ?*const fn (*anyopaque) void = null,
    on_clear_all_visuals: ?*const fn (*anyopaque) void = null,
    /// Called once after a mutation that changes what the panel should show.
    /// Reentrant mutations are coalesced: the outer call refreshes.
    on_store_changed: ?*const fn (*anyopaque) void = null,
    store_change_depth: u32 = 0,

    pub const Visibility = struct { visible: bool, in_active_group: bool };

    pub const EmitOptions = struct {
        title: []const u8 = "Notification",
        subtitle: []const u8 = "",
        body: []const u8 = "",
        pane_id: u64,
        workspace_id: u64,
        pane_group_id: u64 = 0,
        play_sound: bool = true,
        flash: bool = true,
        desktop_notify: bool = true,
        check_visibility: bool = true,
    };

    /// Central notification creation. ALL notification sources call this.
    pub fn emit(self: *NotificationCenter, opts: EmitOptions) void {
        const ctx = self.ctx orelse return;

        // 1. Visibility check — skip if pane is currently focused
        var vis: Visibility = .{ .visible = false, .in_active_group = false };
        if (opts.check_visibility) {
            if (self.on_check_visible) |cb| {
                vis = cb(ctx, opts.pane_id, opts.workspace_id);
                if (vis.visible) return;
            }
        }

        // 2. Create and push Notification to store
        var notif = Notification{
            .pane_id = opts.pane_id,
            .workspace_id = opts.workspace_id,
            .pane_group_id = opts.pane_group_id,
            .timestamp = io.timestamp(),
            .read = false,
        };
        notif.setTitle(opts.title);
        notif.setSubtitle(opts.subtitle);
        notif.setBody(opts.body);
        if (!self.store.push(notif)) return;

        // 3. Mark pane as unread + CSS
        if (self.on_find_pane) |find| {
            if (find(ctx, opts.pane_id)) |pane_ptr| {
                if (self.on_pane_notify) |cb| cb(pane_ptr, true);
                // 4. Trigger flash
                if (opts.flash) {
                    if (self.on_pane_trigger_flash) |cb| cb(pane_ptr);
                }
            }
        }

        // 5. Tab badge
        if (self.on_tab_badge_update) |cb| cb(ctx, opts.pane_id, true);

        // 6. Sidebar
        if (self.on_sidebar_refresh) |cb| cb(ctx);

        // 7. Sound
        if (opts.play_sound) {
            if (self.on_play_sound) |cb| cb(ctx);
        }

        // 8. Desktop notification (libnotify) — only if not in active group
        if (opts.desktop_notify and !vis.in_active_group) {
            if (self.on_desktop_notify) |cb| {
                // Reserve the trailing slot for the terminator: `opts.title` is
                // caller-supplied and unbounded (notification.create passes the
                // raw JSON string straight through), so copying into the whole
                // array could return len == 257 and put the NUL one past the end.
                var title_z: [257]u8 = undefined;
                const tlen = text_mod.copy(title_z[0 .. title_z.len - 1], opts.title);
                title_z[tlen] = 0;

                // Build combined body: subtitle + body
                var body_z: [770]u8 = undefined;
                var bpos: usize = 0;
                if (opts.subtitle.len > 0) {
                    const sub = text_mod.prefix(opts.subtitle, 256).text;
                    @memcpy(body_z[bpos..][0..sub.len], sub);
                    bpos += sub.len;
                    if (opts.body.len > 0) {
                        body_z[bpos] = '\n';
                        bpos += 1;
                    }
                }
                if (opts.body.len > 0) {
                    const body = text_mod.prefix(opts.body, 512).text;
                    @memcpy(body_z[bpos..][0..body.len], body);
                    bpos += body.len;
                }
                body_z[bpos] = 0;

                cb(@ptrCast(title_z[0..tlen :0]), @ptrCast(body_z[0..bpos :0]));
            }
        }

        self.notifyStoreChanged();
    }

    /// Long enough to cover a notification jump plus the popover's close
    /// sequence, short enough that a deliberate later focus still marks read.
    const suppress_focus_window_ms: i64 = 3000;

    /// True while focusing `pane_id` must not blanket-mark its alerts read.
    pub fn suppressionActive(self: *const NotificationCenter, pane_id: u64) bool {
        if (!self.suppress_focus_mark_read) return false;
        if (self.suppress_focus_pane_id != pane_id) return false;
        return io.milliTimestamp() < self.suppress_focus_until_ms;
    }

    /// Record that a notification was activated for `pane_id`. Bounded by time
    /// rather than by a focus-event count: the jump focuses the pane and GTK
    /// focuses it again when the popover closes, and how many transitions occur
    /// depends on scheduling.
    pub fn noteActivatedPane(self: *NotificationCenter, pane_id: u64) void {
        self.suppress_focus_mark_read = true;
        self.suppress_focus_pane_id = pane_id;
        self.suppress_focus_until_ms = io.milliTimestamp() + suppress_focus_window_ms;
    }

    pub fn clearActivationSuppression(self: *NotificationCenter) void {
        self.suppress_focus_mark_read = false;
        self.suppress_focus_pane_id = null;
        self.suppress_focus_until_ms = 0;
    }

    /// Central mark-read for a pane (called on focus). Marks the pane's alerts
    /// read (kept as history), clears pane CSS, tab badge, and sidebar.
    pub fn markReadForPane(self: *NotificationCenter, pane_id: u64, pane_ptr: ?*anyopaque) void {
        const ctx = self.ctx orelse return;
        self.store.markAllReadForPane(pane_id);

        // Clear pane CSS
        if (pane_ptr) |pp| {
            if (self.on_pane_notify) |cb| cb(pp, false);
        }

        // Clear tab badge
        if (self.on_tab_badge_update) |cb| cb(ctx, pane_id, false);

        // Refresh sidebar
        if (self.on_sidebar_refresh) |cb| cb(ctx);

        self.notifyStoreChanged();
    }

    /// Mark all notifications read for a workspace + clear pane/tab visuals + refresh UI.
    pub fn markWorkspaceRead(self: *NotificationCenter, ws_id: u64, ws_ptr: *anyopaque) void {
        const ctx = self.ctx orelse return;
        self.store.markAllRead(ws_id);
        if (self.on_clear_ws_visuals) |cb| cb(ws_ptr);
        if (self.on_sidebar_refresh) |cb| cb(ctx);
        self.notifyStoreChanged();
    }

    /// Clear all notifications globally + clear pane/tab visuals + refresh UI.
    pub fn clearAll(self: *NotificationCenter) void {
        const ctx = self.ctx orelse return;
        self.store.clearAll();
        if (self.on_clear_all_visuals) |cb| cb(ctx);
        if (self.on_sidebar_refresh) |cb| cb(ctx);
        self.notifyStoreChanged();
    }

    /// Remove one notification by panel index (ctl compatibility). The index
    /// is translated to the record's identity at call time.
    pub fn clearAt(self: *NotificationCenter, index: usize) void {
        const id = self.store.idAtIndex(index) orelse return;
        self.clearById(id);
    }

    /// Remove one notification by identity. A stale or evicted id is a no-op,
    /// so a row that outlived its record can never remove a replacement.
    pub fn clearById(self: *NotificationCenter, id: u64) void {
        const ctx = self.ctx orelse return;
        const item = self.store.findById(id) orelse return;
        const pane_id = item.pane_id;
        if (!self.store.removeById(id)) return;
        self.refreshPaneVisuals(pane_id);
        if (self.on_sidebar_refresh) |cb| cb(ctx);
        self.notifyStoreChanged();
    }

    /// Mark one notification read by identity. Siblings for the same pane keep
    /// their unread state.
    pub fn markReadById(self: *NotificationCenter, id: u64) void {
        const ctx = self.ctx orelse return;
        const item = self.store.findById(id) orelse return;
        const pane_id = item.pane_id;
        if (!self.store.markReadById(id)) return;
        self.refreshPaneVisuals(pane_id);
        if (self.on_sidebar_refresh) |cb| cb(ctx);
        self.notifyStoreChanged();
    }

    /// Recompute one pane's unread visuals from the surviving records, so
    /// dismissing one alert does not clear a sibling that is still unread.
    pub fn refreshPaneVisuals(self: *NotificationCenter, pane_id: u64) void {
        const ctx = self.ctx orelse return;
        const unread = self.store.unreadForPane(pane_id) > 0;
        if (self.on_find_pane) |find| {
            if (find(ctx, pane_id)) |pane_ptr| {
                if (self.on_pane_notify) |cb| cb(pane_ptr, unread);
            }
        }
        if (self.on_tab_badge_update) |cb| cb(ctx, pane_id, unread);
    }

    fn notifyStoreChanged(self: *NotificationCenter) void {
        const ctx = self.ctx orelse return;
        if (self.store_change_depth > 0) return;
        self.store_change_depth += 1;
        defer self.store_change_depth -= 1;
        if (self.on_store_changed) |cb| cb(ctx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeTestNotif(pane_id: u64, ws_id: u64) Notification {
    return .{ .pane_id = pane_id, .workspace_id = ws_id, .pane_group_id = 0, .timestamp = @intCast(pane_id) };
}

fn makeTestNotifRead(pane_id: u64, ws_id: u64) Notification {
    var n = makeTestNotif(pane_id, ws_id);
    n.read = true;
    return n;
}

// --- NotificationStore: push / getByIndex ---

test "NotificationStore: push and getByIndex ordering" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 10));
    _ = store.push(makeTestNotif(3, 10));

    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(0).?.pane_id); // newest
    try testing.expectEqual(@as(u64, 2), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id); // oldest
    try testing.expect(store.getByIndex(3) == null);
}

test "NotificationStore: push past capacity evicts oldest" {
    var store = NotificationStore{};
    for (0..100) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 99), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 0), store.getByIndex(99).?.pane_id);

    // Push one more — item 0 evicted
    _ = store.push(makeTestNotif(100, 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 100), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(99).?.pane_id);
}

test "NotificationStore: full scan after multiple wraps" {
    var store = NotificationStore{};
    // Push 250 items — wraps twice
    for (0..250) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    // Buffer should contain items 150..249
    for (0..100) |i| {
        const expected: u64 = 249 - @as(u64, @intCast(i));
        try testing.expectEqual(expected, store.getByIndex(i).?.pane_id);
    }
}

// --- unreadCount / markAllRead ---

test "NotificationStore: unreadCount and markAllRead" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10)); // unread, ws 10
    _ = store.push(makeTestNotifRead(2, 10)); // read, ws 10
    _ = store.push(makeTestNotif(3, 20)); // unread, ws 20
    _ = store.push(makeTestNotif(4, 10)); // unread, ws 10

    try testing.expectEqual(@as(usize, 3), store.unreadCount());
    try testing.expectEqual(@as(usize, 2), store.unreadForWorkspace(10));
    try testing.expectEqual(@as(usize, 1), store.unreadForWorkspace(20));

    store.markAllRead(10);
    try testing.expectEqual(@as(usize, 1), store.unreadCount());
    try testing.expectEqual(@as(usize, 0), store.unreadForWorkspace(10));
    try testing.expectEqual(@as(usize, 1), store.unreadForWorkspace(20));
}

// --- removeAt ---

test "NotificationStore: removeAt from non-full buffer" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 1));
    _ = store.push(makeTestNotif(2, 1));
    _ = store.push(makeTestNotif(3, 1));

    store.removeAt(1); // remove middle (pane_id=2)
    try testing.expectEqual(@as(usize, 2), store.count);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(1).?.pane_id);
}

test "NotificationStore: removeAt newest from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    // Contains items 5..104
    store.removeAt(0); // remove 104
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 103), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(98).?.pane_id);
}

test "NotificationStore: removeAt oldest from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(99); // remove oldest (5)
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 104), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 6), store.getByIndex(98).?.pane_id);
}

test "NotificationStore: removeAt middle from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    // Item at index 50 has pane_id 104-50=54
    try testing.expectEqual(@as(u64, 54), store.getByIndex(50).?.pane_id);
    store.removeAt(50);
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 104), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(98).?.pane_id);
    // Neighbors of removed item shifted
    try testing.expectEqual(@as(u64, 55), store.getByIndex(49).?.pane_id);
    try testing.expectEqual(@as(u64, 53), store.getByIndex(50).?.pane_id);
}

test "NotificationStore: full scan after removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    // Should be 103, 102, ..., 5
    for (0..99) |i| {
        const expected: u64 = 103 - @as(u64, @intCast(i));
        try testing.expectEqual(expected, store.getByIndex(i).?.pane_id);
    }
}

test "NotificationStore: push after removeAt from non-full buffer" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 1));
    _ = store.push(makeTestNotif(2, 1));
    _ = store.push(makeTestNotif(3, 1));
    store.removeAt(0); // remove newest (3)
    _ = store.push(makeTestNotif(10, 1));
    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 10), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 2), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id);
}

test "NotificationStore: push after removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    _ = store.push(makeTestNotif(200, 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 200), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(99).?.pane_id);
}

test "NotificationStore: multiple removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    store.removeAt(0); // remove 103
    store.removeAt(0); // remove 102
    try testing.expectEqual(@as(usize, 97), store.count);
    try testing.expectEqual(@as(u64, 101), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(96).?.pane_id);
}

// --- removeForWorkspace / removeForPane ---

test "NotificationStore: removeForWorkspace preserves order" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 20));
    _ = store.push(makeTestNotif(3, 10));
    _ = store.push(makeTestNotif(4, 20));
    _ = store.push(makeTestNotif(5, 30));

    const removed = store.removeForWorkspace(20);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id);
}

test "NotificationStore: removeForWorkspace from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| {
        _ = store.push(makeTestNotif(@intCast(i), if (i % 2 == 0) @as(u64, 10) else @as(u64, 20)));
    }
    const removed = store.removeForWorkspace(10);
    try testing.expect(removed > 0);
    for (0..store.count) |i| {
        try testing.expectEqual(@as(u64, 20), store.getByIndex(i).?.workspace_id);
    }
}

test "NotificationStore: removeForPane" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 10));
    _ = store.push(makeTestNotif(1, 20)); // same pane_id=1 as first
    const removed = store.removeForPane(1);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expectEqual(@as(u64, 2), store.getByIndex(0).?.pane_id);
}

// --- markAllReadForPane / markReadAt ---

test "NotificationStore: markAllReadForPane keeps history" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 10));
    _ = store.push(makeTestNotif(3, 20));

    store.markAllReadForPane(1);
    try testing.expectEqual(@as(usize, 3), store.count); // nothing removed
    try testing.expect(store.getByIndex(2).?.read); // pane 1, oldest
    try testing.expect(!store.getByIndex(1).?.read); // pane 2 untouched
    try testing.expectEqual(@as(usize, 2), store.unreadCount());
}

test "NotificationStore: markAllReadForPane from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| {
        _ = store.push(makeTestNotif(@intCast(1 + (i % 2)), 1)); // alternating pane_id 1/2
    }
    store.markAllReadForPane(1);
    try testing.expectEqual(@as(usize, 100), store.count);
    for (0..store.count) |i| {
        const item = store.getByIndex(i).?;
        if (item.pane_id == 1) try testing.expect(item.read);
    }
}

test "NotificationStore: markReadAt" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 10));
    _ = store.push(makeTestNotif(3, 10));

    store.markReadAt(1);
    try testing.expect(store.getByIndex(1).?.read);
    try testing.expect(!store.getByIndex(0).?.read);
    try testing.expectEqual(@as(usize, 2), store.unreadCount());
}

test "NotificationStore: markReadAt out of range is a no-op" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));

    store.markReadAt(5);
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expect(!store.getByIndex(0).?.read);
}

// --- latestForWorkspace ---

test "NotificationStore: latestForWorkspace returns newest unread" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotifRead(2, 10));
    _ = store.push(makeTestNotif(3, 10));
    try testing.expectEqual(@as(u64, 3), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace falls back to newest read" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotifRead(1, 10));
    _ = store.push(makeTestNotifRead(2, 10));
    _ = store.push(makeTestNotif(3, 20)); // different ws
    try testing.expectEqual(@as(u64, 2), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace prefers old unread over newer read" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10)); // older unread
    _ = store.push(makeTestNotifRead(2, 10)); // newer read
    try testing.expectEqual(@as(u64, 1), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace null for unknown workspace" {
    var store = NotificationStore{};
    try testing.expect(store.latestForWorkspace(10) == null);
    _ = store.push(makeTestNotif(1, 20));
    try testing.expect(store.latestForWorkspace(10) == null);
}

// --- mostRecentUnread ---

test "NotificationStore: mostRecentUnread" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotifRead(2, 20));
    _ = store.push(makeTestNotif(3, 30));
    try testing.expectEqual(@as(u64, 3), store.mostRecentUnread().?.pane_id);
}

test "NotificationStore: mostRecentUnread null when all read" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotifRead(1, 10));
    try testing.expect(store.mostRecentUnread() == null);
}

// --- clearAll ---

test "NotificationStore: clearAll" {
    var store = NotificationStore{};
    for (0..50) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    store.clearAll();
    try testing.expectEqual(@as(usize, 0), store.count);
    try testing.expect(store.getByIndex(0) == null);
}

// --- identities ---

test "NotificationStore: ids follow records as the ring shifts" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    // Pane 5 is the oldest survivor and was the sixth push, so its identity
    // is 6; identities move with the record, never with the slot index.
    try testing.expectEqual(@as(u64, 5), store.findById(6).?.pane_id);
    try testing.expectEqual(@as(u64, 105), store.getByIndex(0).?.id);
    try testing.expectEqual(@as(usize, 99), store.indexOfId(6).?);
    // Pane 4 (identity 5) was evicted with the ring wrap.
    try testing.expect(store.findById(5) == null);
}

test "NotificationStore: removeById targets the record, not its slot" {
    var store = NotificationStore{};
    for (0..105) |i| _ = store.push(makeTestNotif(@intCast(i), 1));
    const middle = store.getByIndex(50).?;
    const middle_id = middle.id;
    const middle_pane = middle.pane_id;

    try testing.expect(store.removeById(middle_id));
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expect(store.findById(middle_id) == null);
    try testing.expect(!store.removeById(middle_id)); // already gone

    // Neighbours shifted down a slot but kept their own identities.
    try testing.expectEqual(middle_pane + 1, store.getByIndex(49).?.pane_id);
    try testing.expectEqual(middle_pane - 1, store.getByIndex(50).?.pane_id);
}

test "NotificationStore: stale identities are inert and never reused" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 1));
    const old_id = store.getByIndex(0).?.id;
    store.clearAll();
    _ = store.push(makeTestNotif(2, 1));

    try testing.expect(store.findById(old_id) == null);
    try testing.expect(!store.removeById(old_id));
    try testing.expect(!store.markReadById(old_id));
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expect(store.getByIndex(0).?.id > old_id);
    try testing.expect(!store.getByIndex(0).?.read);
}

test "NotificationStore: markReadById preserves sibling unread alerts" {
    var store = NotificationStore{};
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(1, 10));
    _ = store.push(makeTestNotif(2, 10));
    const middle_id = store.getByIndex(1).?.id;

    try testing.expect(store.markReadById(middle_id));
    try testing.expect(store.findById(middle_id).?.read);
    try testing.expectEqual(@as(usize, 1), store.unreadForPane(1));
    try testing.expectEqual(@as(usize, 1), store.unreadForPane(2));
    try testing.expectEqual(@as(usize, 2), store.unreadCount());
}

test "NotificationStore: identity exhaustion refuses instead of reusing" {
    var store = NotificationStore{};
    store.next_id = max_notification_id;
    try testing.expect(store.push(makeTestNotif(1, 1)));
    try testing.expectEqual(max_notification_id, store.getByIndex(0).?.id);

    // The refusal logs a warning and leaves the live record untouched.
    try testing.expect(!store.push(makeTestNotif(2, 1)));
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expectEqual(max_notification_id, store.getByIndex(0).?.id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(0).?.pane_id);
}

test "bounded fields keep complete characters at capacity" {
    var notif = Notification{ .pane_id = 1, .workspace_id = 1, .pane_group_id = 1, .timestamp = 0 };
    const split_title = ("a" ** 253) ++ "\xf0\x9f\x98\x80"; // 257 bytes
    notif.setTitle(split_title);
    try std.testing.expectEqual(@as(usize, 253), notif.getTitle().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(notif.getTitle()));

    const exact_title = ("a" ** 252) ++ "\xf0\x9f\x98\x80"; // exactly 256 bytes
    notif.setTitle(exact_title);
    try std.testing.expectEqual(@as(usize, 256), notif.getTitle().len);
    try std.testing.expectEqualStrings(exact_title, notif.getTitle());

    const split_body = ("b" ** 510) ++ "\xe2\x82\xac"; // 513 bytes
    notif.setBody(split_body);
    try std.testing.expectEqual(@as(usize, 510), notif.getBody().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(notif.getBody()));

    notif.setSubtitle("\xc3\xa9\xc3\xa9");
    try std.testing.expectEqualStrings("\xc3\xa9\xc3\xa9", notif.getSubtitle());
}

test "desktop notification truncates an oversized title without overrunning" {
    // Regression: the title buffer is sized for 256 bytes plus a terminator.
    // An unbounded `notification.create` title used to copy up to the full 257
    // bytes and then write the NUL at index 257, one past the end.
    const Seam = struct {
        var title_len: usize = 0;
        var valid: bool = false;
        fn desktopNotify(title: [*:0]const u8, _: [*:0]const u8) void {
            const slice = std.mem.span(title);
            title_len = slice.len;
            valid = std.unicode.utf8ValidateSlice(slice);
        }
    };

    // `emit` requires a non-null ctx; the callbacks below ignore it, so any
    // stable address will do.
    var dummy: u8 = 0;
    var center = NotificationCenter{ .ctx = &dummy };
    center.on_desktop_notify = &Seam.desktopNotify;

    var long: [1024]u8 = undefined;
    @memset(&long, 't');
    center.emit(.{ .title = &long, .pane_id = 1, .workspace_id = 1 });
    try std.testing.expectEqual(@as(usize, 256), Seam.title_len);
    try std.testing.expect(Seam.valid);

    // A multibyte tail that would straddle the reserved terminator slot still
    // yields a valid prefix rather than a partial codepoint.
    const emoji_tail = ("t" ** 255) ++ "\xf0\x9f\x98\x80";
    center.emit(.{ .title = emoji_tail, .pane_id = 1, .workspace_id = 1 });
    try std.testing.expectEqual(@as(usize, 255), Seam.title_len);
    try std.testing.expect(Seam.valid);
}
