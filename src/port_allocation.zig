//! Checked TCP port arithmetic for the per-workspace SEANCE_PORT block.
//!
//! Workspaces export SEANCE_PORT, SEANCE_PORT_END and SEANCE_PORT_RANGE built
//! from a configured base/range pair and the workspace ordinal. Both the pair
//! and the ordinal are user or session data, so every consumer asks this module
//! instead of multiplying and dividing u32 values itself.

const std = @import("std");

/// Lowest port an allocation may start on. Reserved ports are allowed here:
/// the base is a manual configuration choice.
pub const min_port: u32 = 1;
pub const max_port: u32 = 65535;

/// Ordinal reserved to mean "this workspace owns no port block". Session files
/// and workspace state already use it, so it never allocates.
pub const unallocated: u32 = std.math.maxInt(u32);

pub const default_base: u32 = 9100;
pub const default_range: u32 = 10;

/// Largest range the settings UI offers, independent of the base.
pub const max_ui_range: u32 = 100;

pub const Block = struct {
    start: u16,
    end: u16,
};

pub const PairError = error{
    BaseOutOfRange,
    RangeOutOfRange,
    RangeExceedsSpace,
};

/// Validates a configured base/range pair as a whole. A pair is valid when the
/// whole block fits in the TCP port space.
pub fn validatePair(base: u32, range: u32) PairError!void {
    if (base < min_port or base > max_port) return error.BaseOutOfRange;
    if (range == 0) return error.RangeOutOfRange;
    if (range > max_port - base + 1) return error.RangeExceedsSpace;
}

/// Number of ports left from `base` to the top of the space.
pub fn available(base: u32) u32 {
    if (base < min_port or base > max_port) return 0;
    return max_port - base + 1;
}

/// Largest range the settings UI may offer for `base`.
pub fn uiRangeLimit(base: u32) u32 {
    return @min(max_ui_range, available(base));
}

/// Port block for `ordinal`, or null when the ordinal has no block left in the
/// TCP space (exhaustion) or is the unallocated sentinel. Arithmetic is done in
/// u64 so no ordinal can overflow the computation.
pub fn block(base: u32, range: u32, ordinal: u32) ?Block {
    if (ordinal == unallocated or range == 0) return null;
    const start: u64 = @as(u64, base) + @as(u64, ordinal) * @as(u64, range);
    const end: u64 = start + @as(u64, range) - 1;
    if (start < min_port or end > max_port) return null;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Ordinal for the next workspace. Saturates at the unallocated sentinel so a
/// restored maximum ordinal cannot wrap into a reused block.
pub fn nextOrdinal(ordinal: u32) u32 {
    if (ordinal >= unallocated - 1) return unallocated;
    return ordinal + 1;
}

const testing = std.testing;

test "defaults form ten-port blocks" {
    try validatePair(default_base, default_range);
    const first = block(default_base, default_range, 0).?;
    try testing.expectEqual(@as(u16, 9100), first.start);
    try testing.expectEqual(@as(u16, 9109), first.end);
    const second = block(default_base, default_range, 1).?;
    try testing.expectEqual(@as(u16, 9110), second.start);
    try testing.expectEqual(@as(u16, 9119), second.end);
}

test "the last valid block ends exactly at the top of the port space" {
    // 65000 + 536 - 1 == 65535.
    try validatePair(65000, 536);
    const last = block(65000, 536, 0).?;
    try testing.expectEqual(@as(u16, 65000), last.start);
    try testing.expectEqual(@as(u16, 65535), last.end);
    try testing.expectError(error.RangeExceedsSpace, validatePair(65000, 537));
}

test "single-port bases stay in range" {
    try validatePair(min_port, 1);
    try testing.expectEqual(@as(u16, 1), block(1, 1, 0).?.start);
    try testing.expectEqual(@as(u16, 65535), block(1, 1, 65534).?.start);
    try testing.expectEqual(@as(?Block, null), block(1, 1, 65535));

    try validatePair(max_port, 1);
    try testing.expectEqual(@as(u16, 65535), block(max_port, 1, 0).?.end);
    try testing.expectError(error.RangeExceedsSpace, validatePair(max_port, 2));
}

test "invalid pairs are rejected" {
    try testing.expectError(error.BaseOutOfRange, validatePair(0, 1));
    try testing.expectError(error.BaseOutOfRange, validatePair(65536, 1));
    try testing.expectError(error.BaseOutOfRange, validatePair(0, 0));
    try testing.expectError(error.RangeOutOfRange, validatePair(9100, 0));
    try testing.expectError(error.RangeExceedsSpace, validatePair(65535, 2));
}

test "exhaustion and the sentinel never allocate" {
    try testing.expectEqual(@as(?Block, null), block(default_base, default_range, unallocated));
    try testing.expectEqual(@as(?Block, null), block(1, 1, unallocated - 1));
    try testing.expectEqual(@as(?Block, null), block(1, 1, 65536));
    // A large range exhausts the space after one block: the second block
    // would end past 65535.
    try testing.expectEqual(@as(u16, 32768), block(1, 32768, 0).?.end);
    try testing.expectEqual(@as(?Block, null), block(1, 32768, 1));
    try testing.expectEqual(@as(?Block, null), block(9100, 10, 1_000_000));
}

test "ordinals saturate at the sentinel instead of wrapping" {
    try testing.expectEqual(@as(u32, 1), nextOrdinal(0));
    try testing.expectEqual(@as(u32, 6), nextOrdinal(5));
    try testing.expectEqual(unallocated, nextOrdinal(unallocated - 1));
    try testing.expectEqual(unallocated, nextOrdinal(unallocated));
    // The ordinal handed to a new workspace is always representable.
    try testing.expect(nextOrdinal(unallocated - 2) < unallocated);
}

test "ui limits shrink only when the base leaves no room" {
    try testing.expectEqual(@as(u32, 100), uiRangeLimit(1024));
    try testing.expectEqual(@as(u32, 100), uiRangeLimit(max_port - 99));
    try testing.expectEqual(@as(u32, 36), uiRangeLimit(65500));
    try testing.expectEqual(@as(u32, 1), uiRangeLimit(max_port));
    try testing.expectEqual(@as(u32, 0), uiRangeLimit(0));
}
