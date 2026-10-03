// Regression tests for bugs found in the 2026-10 production-readiness review
// (see docs/PRODUCTION_READINESS_PLAN.md) that api_tests.zig does not already
// cover. Each test names the review finding. Corrupt documents are read
// through View.fromBytesUnchecked, which skips validation.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");
const util = @import("test_util.zig");

/// Offset of the first byte of the value stored right after `key` (key
/// bytes, NUL, then the value's type byte).
fn valueOffset(data: []const u8, key: []const u8) !usize {
    var needle: [32]u8 = undefined;
    @memcpy(needle[0..key.len], key);
    needle[key.len] = 0;
    const at = std.mem.indexOf(u8, data, needle[0 .. key.len + 1]) orelse return error.TestKeyNotFound;
    return at + key.len + 1;
}

fn expectIterationCorrupt(v: lite3.View) !void {
    var it = try v.objectIterator(lite3.root);
    try testing.expectError(error.CorruptData, it.next());
}

test "CSH-1: key at the end of an exact-size allocation stays in bounds" {
    var mem: [1024]u8 align(4) = undefined;
    var src = try lite3.Buffer.init(&mem, .object);
    const key = util.repeat("k", 60);
    try src.set(lite3.root, &key, null);

    // Copy into an allocation of exactly the used length, so any over-long
    // key slice would leave the allocation.
    const exact = try testing.allocator.alignedAlloc(u8, .@"4", src.len);
    defer testing.allocator.free(exact);
    @memcpy(exact, src.slice());
    const v = try lite3.View.fromBytes(exact);
    var it = try v.objectIterator(lite3.root);
    const entry = (try it.next()).?;
    try testing.expectEqualStrings(&key, entry.key);
    try testing.expect(@intFromPtr(entry.key.ptr) + entry.key.len <= @intFromPtr(exact.ptr) + exact.len);
}

test "SEC-3: unterminated key entry is rejected as corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(lite3.root, "ab", 7);
    const nul = try valueOffset(buf.slice(), "ab") - 1;
    mem[nul] = 'x';

    try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
    const v = lite3.View.fromBytesUnchecked(buf.slice());
    try testing.expectError(error.CorruptData, v.get(i64, lite3.root, "ab"));
    try expectIterationCorrupt(v);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.CorruptData, v.writeJson(lite3.root, &sink.writer, .{}));
}

test "SEC-2: string with stored size 0 is corrupt, not a 4 GiB slice" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(lite3.root, "s", "hi");
    const val = try valueOffset(buf.slice(), "s");
    // Value layout: type byte, u32 size (including NUL), bytes.
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[val + 1 ..][0..4], .little));
    std.mem.writeInt(u32, mem[val + 1 ..][0..4], 0, .little);

    try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
    const v = lite3.View.fromBytesUnchecked(buf.slice());
    try testing.expectError(error.CorruptData, v.get([]const u8, lite3.root, "s"));
    try expectIterationCorrupt(v);
}

test "SEC-2: string in an array with stored size 0 is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .array);
    try buf.append(lite3.root, "hi");
    const at = std.mem.indexOf(u8, buf.slice(), "hi\x00") orelse return error.TestValueNotFound;
    std.mem.writeInt(u32, mem[at - 4 ..][0..4], 0, .little);
    try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
    const v = lite3.View.fromBytesUnchecked(buf.slice());
    try testing.expectError(error.CorruptData, v.arrGet([]const u8, lite3.root, 0));
}

test "SEC-2: string without a NUL terminator is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(lite3.root, "s", "hi");
    const at = std.mem.indexOf(u8, buf.slice(), "hi\x00") orelse return error.TestValueNotFound;
    mem[at + 2] = '!';
    try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
    const v = lite3.View.fromBytesUnchecked(buf.slice());
    try testing.expectError(error.CorruptData, v.get([]const u8, lite3.root, "s"));
}

test "CSH-21: bool byte other than 0 or 1 is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(lite3.root, "flag", true);
    const val = try valueOffset(buf.slice(), "flag");
    try testing.expectEqual(@as(u8, 1), mem[val + 1]);
    mem[val + 1] = 2;
    try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
    const v = lite3.View.fromBytesUnchecked(buf.slice());
    try testing.expectError(error.CorruptData, v.get(bool, lite3.root, "flag"));
}

test "CSH-7/SEC-6: containers written over a long string are 4-aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    const s = util.repeat("s", 120);
    // Value lengths chosen so the reused slot starts off a 4-byte boundary.
    for ([_]usize{ 95, 96, 97, 98, 120 }) |len| {
        try buf.set(lite3.root, "k", s[0..len]);
        const obj = try buf.setObject(lite3.root, "k");
        try testing.expectEqual(@as(u32, 0), @backingInt(obj) % 4);
        try buf.set(obj, "inner", 1);
        try testing.expectEqual(@as(i64, 1), try buf.view().get(i64, obj, "inner"));

        try buf.set(lite3.root, "k", s[0..len]);
        const arr = try buf.setArray(lite3.root, "k");
        try testing.expectEqual(@as(u32, 0), @backingInt(arr) % 4);
        try lite3.validateStrict(testing.allocator, buf.slice());
    }
}

test "SEC-7: {\"\":null} decodes, reads back and re-encodes" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    const buf = try lite3.Buffer.fromJson(testing.allocator, &mem, "{\"\":null}", null);
    try testing.expectEqual(lite3.Type.null, try buf.view().typeOf(lite3.root, ""));
    const json = try buf.view().jsonAlloc(testing.allocator, lite3.root, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"\":null}", json);
}

test "SEC-8: JSON key containing \\u0000 is rejected" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    // Without the check this decoded to {"a":2}: the second key overwrote the first.
    try testing.expectError(error.InvalidKey, lite3.Buffer.fromJson(testing.allocator, &mem, "{\"a\\u0000b\":1,\"a\":2}", null));
}

test "SEC-11: scalar JSON root is an error, not an empty success" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    for ([_][]const u8{ "42", "\"s\"", "null", "true" }) |json|
        try testing.expectError(error.InvalidRoot, lite3.Buffer.fromJson(testing.allocator, &mem, json, null));
}
