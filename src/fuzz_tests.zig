// Fuzz targets for the untrusted-input guarantee (see SECURITY.md).
//
// `zig build test` runs each target over its seed corpus; `zig build test
// --fuzz` keeps generating inputs. The property throughout: whatever the
// input, `validate` either rejects it or the document can be read, encoded
// and modified through the public API, and stays valid.

const std = @import("std");
const testing = std.testing;
const Smith = testing.Smith;
const lite3 = @import("lite3");
const readAll = @import("test_util.zig").readAll;

/// Exercise a document that passed `validate`: everything must be readable
/// and encodable. Writes must not crash; if the document also passes
/// `validateStrict`, it must still pass after every write.
fn exercise(mem: []align(4) u8, len: usize) !void {
    var buf = try lite3.Buffer.fromBytes(mem, len);
    try readAll(&buf, lite3.root, 1);
    if (lite3.json_enabled) {
        if (buf.jsonEncode(lite3.root)) |json| json.deinit() else |_| {}
    }
    const strict = if (lite3.validateStrict(testing.allocator, buf.slice())) true else |err| switch (err) {
        error.CorruptData => false,
        else => return err,
    };
    const writes = [_]*const fn (*lite3.Buffer) lite3.Error!void{ writeKey, appendStr, writeObj };
    for (writes) |write| {
        write(&buf) catch |err| switch (err) {
            // Wrong root kind, full buffer, colliding key; or, for a
            // non-strict document, structure a previous write disturbed.
            error.InvalidArgument, error.NoBufferSpace, error.KeyCollision => {},
            error.CorruptData => if (strict) return err,
            else => return err,
        };
        if (strict) try lite3.validateStrict(testing.allocator, buf.slice());
    }
}

fn writeKey(buf: *lite3.Buffer) lite3.Error!void {
    try buf.set(lite3.root, "fuzz", 1);
}

fn appendStr(buf: *lite3.Buffer) lite3.Error!void {
    try buf.append(lite3.root, "x");
}

fn writeObj(buf: *lite3.Buffer) lite3.Error!void {
    const o = try buf.setObject(lite3.root, "fuzz");
    try buf.set(o, "inner", "v");
}

/// Seed documents of different shapes for the mutation target.
fn seedDoc(mem: []align(4) u8, which: u8) !usize {
    var kb: [16]u8 = undefined;
    switch (which % 4) {
        0 => {
            var buf = try lite3.Buffer.init(mem, .object);
            try buf.set(lite3.root, "name", "Alice");
            try buf.set(lite3.root, "age", 30);
            try buf.set(lite3.root, "ok", true);
            try buf.setBytesX(lite3.root, "raw", &.{ 1, 2, 3 });
            return buf.len;
        },
        1 => {
            var buf = try lite3.Buffer.init(mem, .array);
            for (0..30) |i| try buf.append(lite3.root, @intCast(i));
            return buf.len;
        },
        2 => {
            var buf = try lite3.Buffer.init(mem, .object);
            for (0..20) |i| try buf.set(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), 0.5);
            const arr = try buf.setArray(lite3.root, "list");
            try buf.append(arr, "a");
            const inner = try buf.appendObject(arr);
            try buf.set(inner, "n");
            return buf.len;
        },
        else => {
            var buf = try lite3.Buffer.init(mem, .object);
            var ofs = lite3.root;
            for (0..6) |_| ofs = try buf.setObject(ofs, "d");
            try buf.set(ofs, "leaf", "deep");
            return buf.len;
        },
    }
}

fn fuzzMutatedDocument(_: void, s: *Smith) !void {
    var mem: [16384]u8 align(4) = undefined;
    const len = try seedDoc(&mem, s.value(u8));
    var edits: usize = 0;
    while (edits < 16 and !s.eos()) : (edits += 1) {
        mem[s.index(len)] = s.value(u8);
    }
    lite3.validate(mem[0..len]) catch return;
    try exercise(&mem, len);
}

test "fuzz: mutated documents are rejected or safe to use" {
    try testing.fuzz({}, fuzzMutatedDocument, .{ .corpus = &.{
        "\x00",                                 "\x01\x05\x00\x41",
        "\x02\x10\x00\x00\x07\x30\x00\x00\x02", "\x03\x40\x00\x00\xff",
    } });
}

fn fuzzRawBytes(_: void, s: *Smith) !void {
    var mem: [4096]u8 align(4) = undefined;
    const len = s.slice(&mem);
    lite3.validate(mem[0..len]) catch return;
    try exercise(&mem, len);
}

test "fuzz: arbitrary bytes are rejected or safe to use" {
    const empty_array_node = "\x07" ++ @as([95]u8, @splat(0));
    try testing.fuzz({}, fuzzRawBytes, .{ .corpus = &.{ "", "\x06", empty_array_node } });
}

fn fuzzJsonDecode(_: void, s: *Smith) !void {
    if (!lite3.json_enabled) return;
    var json: [2048]u8 = undefined;
    const json_len = s.slice(&json);
    var mem: [32768]u8 align(4) = undefined;
    const buf = lite3.Buffer.fromJson(testing.allocator, &mem, json[0..json_len]) catch return;
    // Anything the decoder produces must be a valid document.
    try lite3.validate(buf.slice());
    try exercise(&mem, buf.len);
}

test "fuzz: JSON decoding produces valid documents" {
    try testing.fuzz({}, fuzzJsonDecode, .{ .corpus = &.{
        "{}",                                                    "[]",
        "{\"a\":1,\"b\":[true,false,null],\"c\":{\"d\":\"e\"}}", "[1.5,-0.0,1e308,9223372036854775807,18446744073709551615]",
        "{\"\":null,\"\\u00e9\":\"\\ud83d\\ude00\"}",            "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]",
        "{\"a\\u0000b\":1}",                                     "42",
    } });
}

fn fuzzOperations(_: void, s: *Smith) !void {
    var mem: [65536]u8 align(4) = undefined;
    var buf = if (s.value(bool)) try lite3.Buffer.init(&mem, .object) else try lite3.Buffer.init(&mem, .array);
    var containers: [16]lite3.Offset = undefined;
    var n_containers: usize = 1;
    containers[0] = lite3.root;
    var key_buf: [8]u8 = undefined;
    var str_buf: [64]u8 = undefined;

    var ops: usize = 0;
    while (ops < 64 and !s.eos()) : (ops += 1) {
        const at = containers[s.index(n_containers)];
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{s.valueRangeAtMost(u8, 0, 40)}) catch unreachable;
        const str = str_buf[0..s.valueRangeAtMost(u8, 0, 63)];
        @memset(str, 'v');
        const op = s.valueRangeAtMost(u8, 0, 9);
        const result: anyerror!void = switch (op) {
            0 => buf.set(at, key, s.value(i64)),
            1 => buf.set(at, key, str),
            2 => buf.set(at, key, s.value(bool)),
            3 => buf.set(at, key),
            4 => buf.append(at, @floatFromInt(s.value(i32))),
            5 => buf.append(at, str),
            6 => buf.appendBytesX(at, str),
            7, 8 => blk: {
                const new = (if (op == 7) buf.setObject(at, key) else buf.appendArray(at)) catch |err| break :blk err;
                if (n_containers < containers.len) {
                    containers[n_containers] = new;
                    n_containers += 1;
                }
            },
            else => buf.set(at, key, 1.25),
        };
        result catch |err| switch (err) {
            // Wrong container kind for the operation, or full.
            error.InvalidArgument, error.NoBufferSpace => {},
            else => return err,
        };
        // Offsets of containers that were later overwritten stay in the
        // list on purpose: writing through a stale Offset must not break
        // the document either.
        try lite3.validateStrict(testing.allocator, buf.slice());
    }
    try readAll(&buf, lite3.root, 1);
}

test "fuzz: any sequence of writes leaves a valid document" {
    try testing.fuzz({}, fuzzOperations, .{ .corpus = &.{
        "\x01\x00\x05\x01\x02\x03\x04\x05\x06\x07\x08\x09",
        "\x00\x04\x05\x06\x08\x08\x08\x05\x04",
        "\x01\x07\x07\x07\x01\x01\x01\x01",
    } });
}

test "mutation sweep: random multi-byte corruptions (deterministic)" {
    // Runs on every `zig build test` regardless of fuzzing support. Seed is
    // fixed so failures reproduce; raise `iterations` locally to search more.
    const iterations = 3000;
    var prng = std.Random.DefaultPrng.init(0x11735eed);
    const rand = prng.random();
    var mem: [16384]u8 align(4) = undefined;
    var accepted: usize = 0;
    for (0..iterations) |i| {
        const len = try seedDoc(&mem, @intCast(i % 4));
        for (0..rand.intRangeAtMost(usize, 1, 8)) |_| mem[rand.uintLessThan(usize, len)] = rand.int(u8);
        lite3.validate(mem[0..len]) catch continue;
        accepted += 1;
        exercise(&mem, len) catch |err| {
            std.debug.print("mutation sweep: iteration {d} failed: {s}\n", .{ i, @errorName(err) });
            return err;
        };
    }
    try testing.expect(accepted > 0);
}
