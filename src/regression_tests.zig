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

/// Offset of the first byte of the value stored right after `key` in a
/// one-entry object (key bytes, NUL, then the value's type byte).
fn valueOffset(data: []const u8, key: []const u8) !usize {
    var needle: [32]u8 = undefined;
    @memcpy(needle[0..key.len], key);
    needle[key.len] = 0;
    const at = std.mem.indexOf(u8, data, needle[0 .. key.len + 1]) orelse return error.TestKeyNotFound;
    return at + key.len + 1;
}

test "SEC-2: string with stored size 0 is corrupt, not a 4 GiB slice" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "s", "hi");
    const val = try valueOffset(buf.data(), "s");
    // Value layout: type byte, u32 size (including NUL), bytes.
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[val + 1 ..][0..4], .little));
    std.mem.writeInt(u32, mem[val + 1 ..][0..4], 0, .little);

    try testing.expectError(lite3.Error.CorruptData, buf.getStr(lite3.root, "s"));
    var it = try buf.iterate(lite3.root);
    try testing.expectError(lite3.Error.CorruptData, it.next());
}

test "SEC-2: string in an array with stored size 0 is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    try buf.arrAppendStr(lite3.root, "hi");
    const at = std.mem.indexOf(u8, buf.data(), "hi\x00") orelse return error.TestValueNotFound;
    std.mem.writeInt(u32, mem[at - 4 ..][0..4], 0, .little);
    try testing.expectError(lite3.Error.CorruptData, buf.arrGetStr(lite3.root, 0));
}

test "SEC-2: string without a NUL terminator is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "s", "hi");
    const at = std.mem.indexOf(u8, buf.data(), "hi\x00") orelse return error.TestValueNotFound;
    mem[at + 2] = '!';
    try testing.expectError(lite3.Error.CorruptData, buf.getStr(lite3.root, "s"));
}

test "CSH-21: bool byte other than 0 or 1 is corrupt" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setBool(lite3.root, "flag", true);
    const val = try valueOffset(buf.data(), "flag");
    try testing.expectEqual(@as(u8, 1), mem[val + 1]);
    mem[val + 1] = 2;
    try testing.expectError(lite3.Error.CorruptData, buf.getBool(lite3.root, "flag"));
}

test "SEC-8: JSON key containing \\u0000 is rejected" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    try testing.expectError(lite3.Error.InvalidArgument, lite3.Buffer.jsonDecode(&mem, "{\"a\\u0000b\":1}"));
    // Without the patch this decoded to {"a":2}: the second key overwrote the first.
    try testing.expectError(lite3.Error.InvalidArgument, lite3.Buffer.jsonDecode(&mem, "{\"a\":1,\"a\\u0000b\":2}"));
}

test "SEC-11: scalar JSON root is an error, not an empty success" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    for ([_][]const u8{ "42", "\"str\"", "true", "null" }) |json| {
        try testing.expectError(lite3.Error.InvalidArgument, lite3.Buffer.jsonDecode(&mem, json));
    }
}

test "ALC-10: Context.importFromBuf with its own data keeps the document" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetObj();
    try ctx.setStr(lite3.root, "name", "Alice");
    try ctx.setI64(lite3.root, "age", 30);
    try ctx.importFromBuf(ctx.data());
    try testing.expectEqualStrings("Alice", try ctx.getStr(lite3.root, "name"));
    try testing.expectEqual(@as(i64, 30), try ctx.getI64(lite3.root, "age"));
}

test "MEM-3/H2: array iteration never reports a key, even after an object iteration" {
    var mem: [2048]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "some_key", 1);
    const arr = try buf.setArr(lite3.root, "arr");
    for (0..20) |i| try buf.arrAppendI64(arr, @intCast(i));

    var obj_it = try buf.iterate(lite3.root);
    while (try obj_it.next()) |e| try testing.expect(e.key != null);

    var arr_it = try buf.iterate(arr);
    var n: usize = 0;
    while (try arr_it.next()) |e| : (n += 1) try testing.expectEqual(@as(?[]const u8, null), e.key);
    try testing.expectEqual(@as(usize, 20), n);
}

test "API-3/CSH-13: getType and exists report corruption instead of absence" {
    var mem: [1024]u8 align(4) = undefined;
    var d = try docWithKey(&mem, "ab");
    mem[d.nul] = 'x'; // unterminated key entry

    try testing.expectError(lite3.Error.CorruptData, d.buf.getType(lite3.root, "ab"));
    try testing.expectError(lite3.Error.CorruptData, d.buf.exists(lite3.root, "ab"));
}

test "API-3/CSH-13: getType and exists on a missing key, and on an array" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "a", 1);
    const arr = try buf.setArr(lite3.root, "arr");

    try testing.expectEqual(false, try buf.exists(lite3.root, "missing"));
    try testing.expectError(lite3.Error.NotFound, buf.getType(lite3.root, "missing"));
    try testing.expectEqual(lite3.Type.i64_, try buf.getType(lite3.root, "a"));
    // An array is not an object: that is a caller error, not "absent".
    try testing.expectError(lite3.Error.InvalidArgument, buf.exists(arr, "a"));
    try testing.expectError(lite3.Error.InvalidArgument, buf.getType(arr, "a"));
    // Out-of-range index: same error as the typed array getters (lite3 uses EINVAL).
    try testing.expectError(lite3.Error.InvalidArgument, buf.arrGetType(arr, 0));
}

test "CSH-14/PRF-8: jsonEncodeBuf reports a too-small buffer as NoBufferSpace" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "name", "Alice");
    const expected = "{\"name\":\"Alice\"}";

    var exact: [expected.len]u8 = undefined;
    const n = try buf.jsonEncodeBuf(lite3.root, &exact);
    try testing.expectEqualStrings(expected, exact[0..n]);

    var small: [expected.len - 1]u8 = undefined;
    try testing.expectError(lite3.Error.NoBufferSpace, buf.jsonEncodeBuf(lite3.root, &small));
}

test "CRT-5: jsonDecode reports where invalid JSON fails" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    var diag: lite3.JsonDiagnostics = .{};
    try testing.expectError(
        lite3.Error.InvalidArgument,
        lite3.Buffer.jsonDecodeDiagnostics(&mem, "{\"a\": 1, \"b\": }", &diag),
    );
    try testing.expectEqual(@as(usize, 14), diag.position);
    try testing.expect(diag.message.len > 0);

    // Valid JSON that lite3 rejects (scalar root) leaves diag untouched.
    var diag2: lite3.JsonDiagnostics = .{};
    try testing.expectError(lite3.Error.InvalidArgument, lite3.Buffer.jsonDecodeDiagnostics(&mem, "42", &diag2));
    try testing.expectEqual(@as(usize, 0), diag2.message.len);

    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    var diag3: lite3.JsonDiagnostics = .{};
    try testing.expectError(lite3.Error.InvalidArgument, ctx.jsonDecodeDiagnostics("[1, 2", &diag3));
    try testing.expectEqual(@as(usize, 5), diag3.position);
}

test "CSH-7/SEC-6: setObj/setArr over a long string place the node 4-aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    // Key and value lengths chosen so the reused slot starts off a 4-byte boundary.
    for ([_]usize{ 95, 96, 97, 98, 120 }) |len| {
        try buf.setStr(lite3.root, "k", repeatByte('s', len));
        const obj = try buf.setObj(lite3.root, "k");
        try testing.expectEqual(@as(usize, 0), @backingInt(obj) % 4);
        try buf.setI64(obj, "inner", 1);
        try testing.expectEqual(@as(i64, 1), try buf.getI64(obj, "inner"));

        try buf.setStr(lite3.root, "k", repeatByte('s', len));
        const arr = try buf.setArr(lite3.root, "k");
        try testing.expectEqual(@as(usize, 0), @backingInt(arr) % 4);
    }
}

fn repeatByte(comptime byte: u8, len: usize) []const u8 {
    const max = 128;
    const all: [max]u8 = @splat(byte);
    return all[0..len];
}

test "SEC-7: {\"\":null} decodes, reads back and re-encodes" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.jsonDecode(&mem, "{\"\":null}");
    try testing.expectEqual(lite3.Type.null, try buf.getType(lite3.root, ""));
    const json = try buf.jsonEncode(lite3.root);
    defer json.deinit();
    try testing.expectEqualStrings("{\"\":null}", json.slice());
}

/// The `i`-th of 256 distinct 16-byte keys that all share one DJB2 hash:
/// "Aa" and "B@" collide (65*33+97 == 66*33+64), and so does any
/// concatenation of equally long colliding blocks.
fn collidingKey(buf: *[16]u8, i: usize) []const u8 {
    for (0..8) |bit| @memcpy(buf[2 * bit ..][0..2], if ((i >> @intCast(bit)) & 1 == 0) "Aa" else "B@");
    return buf;
}

test "SEC-12/CSH-17: hash-probe exhaustion is KeyCollision, lookups stay NotFound" {
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 16);
    defer testing.allocator.free(mem);
    var buf = try lite3.Buffer.initObj(mem);
    var kb: [16]u8 = undefined;
    // 128 probe slots: attempts 0..127.
    for (0..128) |i| try buf.setI64(lite3.root, collidingKey(&kb, i), @intCast(i));
    try testing.expectError(lite3.Error.KeyCollision, buf.setI64(lite3.root, collidingKey(&kb, 128), 0));
    try testing.expectError(lite3.Error.NotFound, buf.getI64(lite3.root, collidingKey(&kb, 200)));
    try testing.expectEqual(false, try buf.exists(lite3.root, collidingKey(&kb, 200)));
    for (0..128) |i| try testing.expectEqual(@as(i64, @intCast(i)), try buf.getI64(lite3.root, collidingKey(&kb, i)));
    try lite3.validate(buf.data());
}

test "ALC-5: max_capacity bounds growth" {
    const a = testing.allocator;
    try testing.expectError(lite3.Error.InvalidArgument, lite3.ManagedContext.initWithOptions(a, .{ .max_capacity = 64 }));
    try testing.expectError(lite3.Error.InvalidArgument, lite3.ManagedContext.initWithOptions(a, .{ .initial_capacity = 8192, .max_capacity = 4096 }));

    var m = try lite3.ManagedContext.initWithOptions(a, .{ .max_capacity = 4096 });
    defer m.deinit();
    try testing.expectError(lite3.Error.NoBufferSpace, m.setStr(lite3.root, "big", &(@as([5000]u8, @splat('x')))));
    try testing.expect(m.capacity() <= 4096);
    try m.setStr(lite3.root, "small", "fits");
    try testing.expectEqualStrings("fits", try m.getStr(lite3.root, "small"));

    var e = try lite3.ExternalContext.initWithOptions(a, .{ .initial_capacity = 1024, .max_capacity = 2048 });
    defer e.deinit(a);
    try testing.expectError(lite3.Error.NoBufferSpace, e.setBytes(a, lite3.root, "big", &(@as([3000]u8, @splat(1)))));
    try testing.expect(e.capacity() <= 2048);

    if (lite3.json_enabled) {
        // Untrusted JSON cannot make the document grow past the limit.
        var j = try lite3.ManagedContext.initWithOptions(a, .{ .max_capacity = 4096 });
        defer j.deinit();
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(a);
        try json.append(a, '[');
        for (0..2000) |_| try json.appendSlice(a, "1,");
        try json.appendSlice(a, "1]");
        try testing.expectError(lite3.Error.NoBufferSpace, j.jsonDecode(json.items));
        try testing.expect(j.capacity() <= 4096);
    }
}

test "shim: setObj/setArr on an array report InvalidArgument (macro early return)" {
    // lite3_set_obj/arr are macros with an early `return`; it used to bypass
    // the shim's status translation and surface as NotFound.
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    try testing.expectError(lite3.Error.InvalidArgument, buf.setObj(lite3.root, "k"));
    try testing.expectError(lite3.Error.InvalidArgument, buf.setArr(lite3.root, "k"));

    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetArr();
    try testing.expectError(lite3.Error.InvalidArgument, ctx.setObj(lite3.root, "k"));
    try testing.expectError(lite3.Error.InvalidArgument, ctx.setArr(lite3.root, "k"));
}
