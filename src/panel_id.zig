//! Single id space for every panel — terminal panes and browser panels —
//! so id-keyed lookups can never confuse two live panels. Ids are
//! per-process and ephemeral: never persist them or compare them across
//! runs.
const std = @import("std");

var counter: std.atomic.Value(u64) = .init(0);

/// Next panel id, starting at 1, unique across all panel kinds.
pub fn next() u64 {
    return counter.fetchAdd(1, .monotonic) + 1;
}

test "ids are issued from one monotonic sequence starting at one" {
    const first = next();
    const second = next();
    try std.testing.expectEqual(first + 1, second);
}
