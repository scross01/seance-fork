//! UTF-8-safe prefixes for fixed-capacity display and persistence fields.
//!
//! Fixed buffers are byte-oriented, so a raw `@min(len, cap)` copy can end in
//! the middle of a multibyte codepoint and hand GTK or a session document
//! invalid UTF-8. These helpers return the longest prefix that both fits the
//! byte limit and ends on a codepoint boundary, and never manufacture bytes.
const std = @import("std");

pub const Prefix = struct {
    /// Longest complete, valid UTF-8 prefix of the input that fits the limit.
    text: []const u8,
    /// True only when the entire input was consumed: a shorter `text` means
    /// the limit cut the input or the input held invalid/truncated bytes.
    valid: bool,
};

/// Longest valid UTF-8 prefix of `input` fitting `limit` bytes. Stops before
/// the first invalid, overlong or truncated sequence rather than emitting it.
pub fn prefix(input: []const u8, limit: usize) Prefix {
    var end: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const n = std.unicode.utf8ByteSequenceLength(input[i]) catch break;
        if (i + n > input.len) break;
        _ = std.unicode.utf8Decode(input[i..][0..n]) catch break;
        if (i + n > limit) break;
        i += n;
        end = i;
    }
    return .{ .text = input[0..end], .valid = end == input.len };
}

/// Copy the longest valid prefix of `input` into `dest`, returning its length.
/// Callers that need a C string write the terminator themselves.
pub fn copy(dest: []u8, input: []const u8) usize {
    const bounded = prefix(input, dest.len);
    @memcpy(dest[0..bounded.text.len], bounded.text);
    return bounded.text.len;
}

test "prefix: empty input and zero limit" {
    try std.testing.expectEqualStrings("", prefix("", 0).text);
    try std.testing.expect(prefix("", 0).valid);
    try std.testing.expectEqualStrings("", prefix("hello", 0).text);
    try std.testing.expect(!prefix("hello", 0).valid);
}

test "prefix: ASCII cuts and exact fit" {
    try std.testing.expectEqualStrings("hel", prefix("hello", 3).text);
    try std.testing.expect(!prefix("hello", 3).valid);
    try std.testing.expectEqualStrings("hello", prefix("hello", 5).text);
    try std.testing.expect(prefix("hello", 5).valid);
    try std.testing.expectEqualStrings("hello", prefix("hello", 99).text);
    try std.testing.expect(prefix("hello", 99).valid);
}

test "prefix: every cut of 2-byte, 3-byte and 4-byte codepoints" {
    // Each complete character is retained exactly when its bytes fit.
    try std.testing.expectEqualStrings("", prefix("\xc3\xa9", 1).text);
    try std.testing.expectEqualStrings("\xc3\xa9", prefix("\xc3\xa9", 2).text);
    try std.testing.expect(prefix("\xc3\xa9", 2).valid);

    try std.testing.expectEqualStrings("", prefix("\xe2\x82\xac", 2).text);
    try std.testing.expectEqualStrings("\xe2\x82\xac", prefix("\xe2\x82\xac", 3).text);
    try std.testing.expect(prefix("\xe2\x82\xac", 3).valid);

    try std.testing.expectEqualStrings("", prefix("\xf0\x9f\x98\x80", 3).text);
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", prefix("\xf0\x9f\x98\x80", 4).text);
    try std.testing.expect(prefix("\xf0\x9f\x98\x80", 4).valid);
}

test "prefix: mixed-width text at every byte limit" {
    const input = "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80"; // a, e-acute, euro, emoji
    const expected = [_][]const u8{
        "",                      "a",                     "a",                     "a\xc3\xa9",
        "a\xc3\xa9",             "a\xc3\xa9",             "a\xc3\xa9\xe2\x82\xac", "a\xc3\xa9\xe2\x82\xac",
        "a\xc3\xa9\xe2\x82\xac", "a\xc3\xa9\xe2\x82\xac", input,
    };
    for (expected, 0..) |want, limit| {
        const got = prefix(input, limit);
        try std.testing.expectEqualStrings(want, got.text);
        try std.testing.expectEqual(want.len == input.len, got.valid);
    }
    try std.testing.expect(prefix(input, input.len).valid);
    try std.testing.expect(prefix(input, input.len + 16).valid);
}

test "prefix: invalid and truncated input stops before the bad sequence" {
    try std.testing.expectEqualStrings("", prefix("\xff", 8).text);
    try std.testing.expect(!prefix("\xff", 8).valid);
    try std.testing.expectEqualStrings("", prefix("\xc3", 8).text); // truncated tail
    try std.testing.expectEqualStrings("", prefix("\xc0\x80", 8).text); // overlong
    try std.testing.expectEqualStrings("", prefix("\xed\xa0\x80", 8).text); // surrogate
    try std.testing.expectEqualStrings("a", prefix("a\xff\xc3\xa9", 16).text);
    try std.testing.expect(!prefix("a\xff\xc3\xa9", 16).valid);
    try std.testing.expectEqualStrings("a", prefix("a\xc3\xa9", 1).text);
}

test "copy: bounded copies keep complete characters and report length" {
    var dest: [5]u8 = [_]u8{0} ** 5;
    try std.testing.expectEqual(@as(usize, 3), copy(&dest, "a\xc3\xa9\xe2\x82\xac"));
    try std.testing.expectEqualStrings("a\xc3\xa9", dest[0..3]);
    var tiny: [3]u8 = [_]u8{0} ** 3;
    try std.testing.expectEqual(@as(usize, 0), copy(&tiny, "\xf0\x9f\x98\x80"));
    try std.testing.expectEqual(@as(usize, 4), copy(&dest, "\xf0\x9f\x98\x80"));
    var small: [1]u8 = [_]u8{0};
    try std.testing.expectEqual(@as(usize, 1), copy(&small, "a\xc3\xa9"));
    try std.testing.expectEqualStrings("a", small[0..1]);
}

test "prefix: capacities used by tab and title fields keep boundaries" {
    const filler = "\xe2\x82\xac"; // 3-byte euro
    var input: [600]u8 = undefined;
    var n: usize = 0;
    while (n + filler.len <= input.len) : (n += filler.len) @memcpy(input[n..][0..filler.len], filler);

    for ([_]usize{ 64, 128, 256, 512 }) |cap| {
        const cut = prefix(input[0..n], cap);
        try std.testing.expectEqual((cap / 3) * 3, cut.text.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(cut.text));
        try std.testing.expect(!cut.valid);

        const exact = prefix(input[0 .. (cap / 3) * 3], cap);
        try std.testing.expect(exact.valid);
        try std.testing.expectEqual((cap / 3) * 3, exact.text.len);
    }
}
