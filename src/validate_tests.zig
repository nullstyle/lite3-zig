// Tests for lite3.validate: every document the library produces must pass,
// and each class of structural corruption must be rejected.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

const node_size = 96;
const ofs_size_kc = 32;
const ofs_child = 64;

fn readU32(bytes: []const u8, ofs: usize) u32 {
    return std.mem.readInt(u32, bytes[ofs..][0..4], .little);
}

fn writeU32(bytes: []u8, ofs: usize, v: u32) void {
    std.mem.writeInt(u32, bytes[ofs..][0..4], v, .little);
}

/// Build a document that exercises node splits, nesting, every value type,
/// long keys (1-, 2- and 4-byte key tags) and in-place overwrites.
fn buildRich(buf: *lite3.Buffer) !void {
    var kb: [20000]u8 = undefined;
    for (0..200) |i| {
        const key = try std.fmt.bufPrint(&kb, "key-{d}", .{i});
        switch (i % 6) {
            0 => try buf.setI64(lite3.root, key, @intCast(i)),
            1 => try buf.setStr(lite3.root, key, "value"),
            2 => try buf.setBool(lite3.root, key, i % 4 == 1),
            3 => try buf.setF64(lite3.root, key, @floatFromInt(i)),
            4 => try buf.setBytes(lite3.root, key, &.{ 0, 1, 2, 3 }),
            else => try buf.setNull(lite3.root, key),
        }
    }
    const arr = try buf.setArr(lite3.root, "array");
    for (0..300) |i| try buf.arrAppendI64(arr, @intCast(i));
    const nested = try buf.arrAppendObj(arr);
    try buf.setStr(nested, "deep", "yes");
    var inner = nested;
    for (0..20) |_| inner = try buf.setObj(inner, "child");

    @memset(kb[0..70], 'm');
    try buf.setNull(lite3.root, kb[0..70]); // 2-byte key tag
    // A 4-byte key tag needs a key of at least 16383 bytes; the wrapper's key
    // limit is lower, so that path is covered by the JSON test below.

    // Overwrites: in place (shorter), appended (longer), and a container over a long string.
    try buf.setStr(lite3.root, "key-1", "v");
    try buf.setStr(lite3.root, "key-7", "a much longer value than before");
    try buf.setStr(lite3.root, "swap", "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789");
    _ = try buf.setObj(lite3.root, "swap");
}

test "validate: documents built through the API are valid" {
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 20);
    defer testing.allocator.free(mem);
    var buf = try lite3.Buffer.initObj(mem);
    try lite3.validate(buf.data());
    try buildRich(&buf);
    try lite3.validate(buf.data());

    var arr_buf = try lite3.Buffer.initArr(mem);
    for (0..5000) |i| try arr_buf.arrAppendI64(lite3.root, @intCast(i));
    try lite3.validate(arr_buf.data());
}

test "validate: JSON-decoded documents are valid" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 20);
    defer testing.allocator.free(mem);

    // A key of 16383 bytes plus NUL needs a 4-byte key tag.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"");
    try json.appendNTimes(testing.allocator, 'k', 16383);
    try json.appendSlice(testing.allocator, "\":[1,2.5,\"s\",true,null,{\"a\":[]}]}");
    const buf = try lite3.Buffer.jsonDecode(mem, json.items);
    try lite3.validate(buf.data());
}

test "validate: rejects truncation and bad root" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "name", "value");
    const data = buf.data();

    try testing.expectError(lite3.Error.CorruptData, lite3.validate(data[0 .. node_size - 1]));
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(data[0 .. data.len - 1]));
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(&.{}));

    mem[0] = 5; // root type byte: string
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(data));
}

test "validate: rejects a wrong element count" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "a", 1);
    const size_kc = readU32(&mem, ofs_size_kc);
    writeU32(&mem, ofs_size_kc, size_kc + (1 << 6));
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

test "validate: rejects a key whose hash does not match" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "a", 1);
    writeU32(&mem, 4, readU32(&mem, 4) +% 2); // hashes[0]; +2 is not a probe square
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

/// A document whose root has been split into an internal node with children.
fn splitDoc(mem: []align(4) u8) !lite3.Buffer {
    var buf = try lite3.Buffer.initArr(mem);
    for (0..40) |i| try buf.arrAppendI64(lite3.root, @intCast(i));
    try testing.expect(readU32(mem, ofs_child) != 0); // root is internal
    try lite3.validate(buf.data());
    return buf;
}

test "SEC-4: validate rejects shared children (DAG amplification)" {
    var mem: [8192]u8 align(4) = undefined;
    const buf = try splitDoc(&mem);
    writeU32(&mem, ofs_child + 4, readU32(&mem, ofs_child)); // child[1] = child[0]
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

test "SEC-4: validate rejects a cycle back to the root" {
    var mem: [8192]u8 align(4) = undefined;
    const buf = try splitDoc(&mem);
    const child0 = readU32(&mem, ofs_child);
    // Point the first child's first grandchild slot at the root.
    writeU32(&mem, child0 + ofs_child, 0);
    writeU32(&mem, ofs_child, 0);
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

test "validate: rejects misaligned and out-of-range child offsets" {
    var mem: [8192]u8 align(4) = undefined;
    const buf = try splitDoc(&mem);
    const child0 = readU32(&mem, ofs_child);
    writeU32(&mem, ofs_child, child0 + 2);
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
    writeU32(&mem, ofs_child, @intCast(buf.len));
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

test "validate: rejects nesting deeper than max_nesting_depth" {
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 16);
    defer testing.allocator.free(mem);
    var buf = try lite3.Buffer.initObj(mem);
    var ofs = lite3.root;
    for (0..lite3.max_nesting_depth - 1) |_| ofs = try buf.setObj(ofs, "n");
    try lite3.validate(buf.data());
    _ = try buf.setObj(ofs, "n");
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
}

/// Read every value reachable from `ofs` through the public API.
fn readAll(buf: *const lite3.Buffer, ofs: lite3.Offset, depth: usize) !void {
    if (depth > lite3.max_nesting_depth) return error.TooDeep;
    var it = try buf.iterate(ofs);
    var index: u32 = 0;
    while (try it.next()) |e| : (index += 1) {
        const t = if (e.key) |k| try buf.getType(ofs, k) else try buf.arrGetType(ofs, index);
        if (e.key) |k| switch (t) {
            .string => _ = try buf.getStr(ofs, k),
            .bytes => _ = try buf.getBytes(ofs, k),
            .object => try readAll(buf, try buf.getObj(ofs, k), depth + 1),
            .array => try readAll(buf, try buf.getArr(ofs, k), depth + 1),
            else => _ = try buf.getValue(ofs, k),
        } else switch (t) {
            .string => _ = try buf.arrGetStr(ofs, index),
            .bytes => _ = try buf.arrGetBytes(ofs, index),
            .object => try readAll(buf, try buf.arrGetObj(ofs, index), depth + 1),
            .array => try readAll(buf, try buf.arrGetArr(ofs, index), depth + 1),
            else => {},
        }
    }
    try testing.expectEqual(index, try buf.count(ofs));
}

test "validate: any single-byte corruption is rejected or fully readable" {
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    var kb: [16]u8 = undefined;
    for (0..12) |i| try buf.setI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @intCast(i));
    try buf.setStr(lite3.root, "s", "hello");
    try buf.setBytes(lite3.root, "b", &.{ 1, 2, 3 });
    try buf.setBool(lite3.root, "t", true);
    const arr = try buf.setArr(lite3.root, "a");
    for (0..10) |i| try buf.arrAppendStr(arr, if (i % 2 == 0) "x" else "yy");
    _ = try buf.arrAppendObj(arr);
    const len = buf.len;
    var original: [16384]u8 = undefined;
    @memcpy(original[0..len], mem[0..len]);

    var accepted: usize = 0;
    for (0..len) |pos| {
        for ([_]u8{ 0x00, 0x01, 0x07, 0x80, 0xff }) |delta| {
            @memcpy(mem[0..len], original[0..len]);
            mem[pos] ^= delta;
            if (mem[pos] == original[pos]) continue;
            lite3.validate(mem[0..len]) catch continue;
            // Accepted: the document must be fully readable and encodable.
            accepted += 1;
            var view = try lite3.Buffer.fromSerializedUnchecked(&mem, len);
            readAll(&view, lite3.root, 1) catch |err| {
                std.debug.print("pos={d} delta=0x{x:0>2} orig=0x{x:0>2} err={s}\n", .{ pos, delta, original[pos], @errorName(err) });
                return err;
            };
            if (lite3.json_enabled) {
                if (view.jsonEncode(lite3.root)) |json| json.deinit() else |_| {}
            }
        }
    }
    // Value bytes (integers, string contents) can change freely.
    try testing.expect(accepted > 0);
}

test "validate: accepts genuine hash collisions resolved by probing" {
    // DJB2 collisions: 65*33+97 == 66*33+64 == 67*33+31.
    const keys = [_][]const u8{ "Aa", "B@", "C\x1f" };
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    for (keys, 0..) |k, i| try buf.setI64(lite3.root, k, @intCast(i));
    try lite3.validate(buf.data());
    for (keys, 0..) |k, i| try testing.expectEqual(@as(i64, @intCast(i)), try buf.getI64(lite3.root, k));

    // Turning "B@" (stored at probe attempt 1) into a duplicate of "Aa"
    // makes it unreachable by lookup, which validate must reject.
    const second = std.mem.indexOf(u8, buf.data(), "B@\x00").?;
    @memcpy(mem[second..][0..2], "Aa");
    try testing.expectError(lite3.Error.CorruptData, lite3.validate(buf.data()));
    @memcpy(mem[second..][0..2], "B@");
    try lite3.validate(buf.data());
}
