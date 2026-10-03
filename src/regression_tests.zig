// Regression tests for bugs found in the 2026-10 production-readiness review
// (see docs/PRODUCTION_READINESS_PLAN.md). Each test names the review finding
// it covers; most exercise local patches in vendor/patches/.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

fn fillKey(buf: []u8, len: usize, tag: u8) []const u8 {
    for (buf[0..len], 0..) |*b, i| b.* = 'a' + @as(u8, @intCast((i + tag) % 26));
    return buf[0..len];
}

/// Key lengths around the 1/2-byte key tag boundary (stored size incl. NUL
/// is shifted left by 2, so 63 bytes of key is the first 2-byte tag).
const key_lens = [_]usize{ 0, 1, 5, 61, 62, 63, 64, 200, 255 };

fn expectIteratedKeys(doc: anytype) !void {
    var expected: [key_lens.len][255]u8 = undefined;
    var seen: [key_lens.len]bool = @splat(false);
    var it = try doc.iterate(lite3.root);
    var n: usize = 0;
    while (try it.next()) |entry| : (n += 1) {
        const key = entry.key orelse return error.TestExpectedKey;
        const idx = for (key_lens, 0..) |len, i| {
            if (len == key.len) break i;
        } else return error.TestUnexpectedKeyLength;
        try testing.expectEqualStrings(fillKey(&expected[idx], key_lens[idx], @intCast(idx)), key);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    try testing.expectEqual(key_lens.len, n);
}

test "CSH-1: iterator returns exact key bytes (Buffer)" {
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    var kb: [255]u8 = undefined;
    for (key_lens, 0..) |len, i| try buf.setI64(lite3.root, fillKey(&kb, len, @intCast(i)), @intCast(i));
    try expectIteratedKeys(&buf);
}

test "CSH-1: iterator returns exact key bytes (Context)" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetObj();
    var kb: [255]u8 = undefined;
    for (key_lens, 0..) |len, i| try ctx.setI64(lite3.root, fillKey(&kb, len, @intCast(i)), @intCast(i));
    try expectIteratedKeys(&ctx);
}

test "CSH-1: key at the end of an exact-size heap buffer stays in bounds" {
    var mem: [1024]u8 align(4) = undefined;
    var src = try lite3.Buffer.initObj(&mem);
    var kb: [60]u8 = undefined;
    try src.setNull(lite3.root, fillKey(&kb, 60, 0));

    // Copy into an allocation of exactly the used length, so any over-long
    // key slice would leave the allocation.
    const exact = try testing.allocator.alignedAlloc(u8, .@"4", src.len);
    defer testing.allocator.free(exact);
    @memcpy(exact, src.data());
    var buf = try lite3.Buffer.fromSerialized(exact, exact.len);

    var it = try buf.iterate(lite3.root);
    const entry = (try it.next()).?;
    try testing.expectEqualStrings(fillKey(&kb, 60, 0), entry.key.?);
    const key_ptr = @intFromPtr(entry.key.?.ptr);
    try testing.expect(key_ptr + entry.key.?.len <= @intFromPtr(exact.ptr) + exact.len);
}

test "CSH-1/SEC-3: jsonEncode emits exact keys" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "x", 1);
    const json = try buf.jsonEncode(lite3.root);
    defer json.deinit();
    try testing.expectEqualStrings("{\"x\":1}", json.slice());
}

/// Serialize a one-key document and return the offset of the key's NUL byte.
fn docWithKey(mem: []align(4) u8, key: []const u8) !struct { buf: lite3.Buffer, nul: usize } {
    var buf = try lite3.Buffer.initObj(mem);
    try buf.setI64(lite3.root, key, 7);
    var needle: [32]u8 = undefined;
    @memcpy(needle[0..key.len], key);
    needle[key.len] = 0;
    const at = std.mem.indexOf(u8, buf.data(), needle[0 .. key.len + 1]) orelse return error.TestKeyNotFound;
    return .{ .buf = buf, .nul = at + key.len };
}

test "SEC-3: unterminated key entry is rejected as corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var d = try docWithKey(&mem, "ab");
    mem[d.nul] = 'x';

    try testing.expectError(lite3.Error.CorruptData, d.buf.getI64(lite3.root, "ab"));
    var it = try d.buf.iterate(lite3.root);
    try testing.expectError(lite3.Error.CorruptData, it.next());
    if (lite3.json_enabled) try testing.expectError(lite3.Error.CorruptData, d.buf.jsonEncode(lite3.root));
}
