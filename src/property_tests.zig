// Property tests: random operation sequences checked against a simple model,
// allocation-failure behaviour of growable documents, and byte-exact golden
// fixtures for the serialized format.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");
const util = @import("test_util.zig");
const root = lite3.root;

// ---------------------------------------------------------------------------
// Model-based test
// ---------------------------------------------------------------------------

const max_str = 300;

const ModelValue = union(enum) {
    null,
    bool: bool,
    int: i64,
    /// Bit pattern, so NaNs compare exactly.
    float: u64,
    string: struct { buf: [max_str]u8, len: usize },
    object,

    fn random(rand: std.Random) ModelValue {
        return switch (rand.uintLessThan(u8, 6)) {
            0 => .null,
            1 => .{ .bool = rand.boolean() },
            2 => .{ .int = rand.int(i64) },
            3 => .{ .float = rand.int(u64) },
            4 => blk: {
                var v: ModelValue = .{ .string = .{ .buf = undefined, .len = rand.uintAtMost(usize, max_str) } };
                // Printable bytes keep failure output readable.
                for (v.string.buf[0..v.string.len]) |*b| b.* = rand.intRangeAtMost(u8, ' ', '~');
                break :blk v;
            },
            else => .object,
        };
    }

    fn expectMatches(m: *const ModelValue, actual: lite3.Value) !void {
        switch (m.*) {
            .null => try testing.expect(actual == .null),
            .bool => |b| try testing.expectEqual(b, actual.bool),
            .int => |i| try testing.expectEqual(i, actual.int),
            .float => |f| try testing.expectEqual(f, @as(u64, @bitCast(actual.float))),
            .string => |*s| try testing.expectEqualStrings(s.buf[0..s.len], actual.string),
            .object => try testing.expect(actual == .object),
        }
    }
};

const key_count = 64;

fn modelKey(buf: *[128]u8, id: usize) []const u8 {
    // Every eighth key is long enough for a 2-byte key tag.
    if (id % 8 == 0) return std.fmt.bufPrint(buf, "long-key-{d:0>100}", .{id}) catch unreachable;
    return std.fmt.bufPrint(buf, "k{d}", .{id}) catch unreachable;
}

fn writeModelValue(b: anytype, at: lite3.Offset, k: []const u8, v: *const ModelValue) !void {
    switch (v.*) {
        .null => try b.set(at, k, null),
        .bool => |x| try b.set(at, k, x),
        .int => |x| try b.set(at, k, x),
        .float => |x| try b.set(at, k, @as(f64, @bitCast(x))),
        .string => |*s| try b.set(at, k, s.buf[0..s.len]),
        .object => _ = try b.setObject(at, k),
    }
}

fn arrWriteModelValue(b: anytype, arr: lite3.Offset, index: ?u32, v: *const ModelValue) !void {
    if (index) |i| switch (v.*) {
        .null => try b.arrSet(arr, i, null),
        .bool => |x| try b.arrSet(arr, i, x),
        .int => |x| try b.arrSet(arr, i, x),
        .float => |x| try b.arrSet(arr, i, @as(f64, @bitCast(x))),
        .string => |*s| try b.arrSet(arr, i, s.buf[0..s.len]),
        .object => _ = try b.arrSetObject(arr, i),
    } else switch (v.*) {
        .null => try b.append(arr, null),
        .bool => |x| try b.append(arr, x),
        .int => |x| try b.append(arr, x),
        .float => |x| try b.append(arr, @as(f64, @bitCast(x))),
        .string => |*s| try b.append(arr, s.buf[0..s.len]),
        .object => _ = try b.appendObject(arr),
    }
}

const Model = struct {
    keys: [key_count]?ModelValue = @splat(null),
    list: std.ArrayList(ModelValue) = .empty,

    fn expectMatches(m: *const Model, v: lite3.View, list: lite3.Offset) !void {
        var kb: [128]u8 = undefined;
        var present: u32 = 1; // "list"
        for (&m.keys, 0..) |*slot, id| {
            const k = modelKey(&kb, id);
            if (slot.*) |*mv| {
                present += 1;
                try mv.expectMatches(try v.getValue(root, k));
            } else {
                try testing.expectError(error.NotFound, v.getValue(root, k));
            }
        }
        try testing.expectEqual(present, try v.count(root));
        try testing.expectEqual(@as(u32, @intCast(m.list.items.len)), try v.count(list));
        for (m.list.items, 0..) |*mv, i| try mv.expectMatches(try v.arrValue(list, @intCast(i)));
        try util.readAll(v, root, 1);
    }
};

fn runModel(comptime B: type, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var b = try B.initCapacity(.object, 256);
    defer b.deinit();
    var model: Model = .{};
    defer model.list.deinit(testing.allocator);
    const list = try b.setArray(root, "list");
    var kb: [128]u8 = undefined;

    for (0..1500) |step| {
        const v = ModelValue.random(rand);
        switch (rand.uintLessThan(u8, 10)) {
            0...5 => {
                const id = rand.uintLessThan(usize, key_count);
                try writeModelValue(&b, root, modelKey(&kb, id), &v);
                model.keys[id] = v;
            },
            6...7 => {
                try arrWriteModelValue(&b, list, null, &v);
                try model.list.append(testing.allocator, v);
            },
            else => {
                const len = model.list.items.len;
                // Index == len appends; anything past that must fail.
                const i = rand.uintAtMost(usize, len + 1);
                if (i > len) {
                    try testing.expectError(error.IndexOutOfBounds, arrWriteModelValue(&b, list, @intCast(i), &v));
                } else {
                    try arrWriteModelValue(&b, list, @intCast(i), &v);
                    if (i == len) try model.list.append(testing.allocator, v) else model.list.items[i] = v;
                }
            },
        }
        if (step % 100 == 99) {
            try model.expectMatches(b.view(), list);
            try lite3.validateStrict(testing.allocator, b.slice());
        }
    }
    try model.expectMatches(b.view(), list);
    try lite3.validateStrict(testing.allocator, b.slice());
}

test "model: random writes agree with a reference model" {
    inline for (util.backends, 0..) |B, i| {
        const seed = @as(u64, testing.random_seed) *% 0x9e3779b97f4a7c15 +% i;
        runModel(B, seed) catch |err| {
            std.debug.print("model test failed for {s}; reproduce with seed 0x{x}\n", .{ B.name, seed });
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Allocation failure
// ---------------------------------------------------------------------------

fn buildGrowing(gpa: std.mem.Allocator) !void {
    var doc = try lite3.Document.initOptions(gpa, .{ .root = .object, .initial_capacity = 128 });
    defer doc.deinit(gpa);
    var kb: [16]u8 = undefined;
    for (0..80) |i| try doc.set(gpa, root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), i);
    const arr = try doc.setArray(gpa, root, "arr");
    for (0..40) |_| try doc.append(gpa, arr, "element");
    // A key longer than the stack copy takes the heap path.
    const long = util.repeat("x", lite3.max_stack_key_len + 10);
    try doc.set(gpa, root, &long, 1);
    try doc.compact(gpa);
    var copy = try doc.clone(gpa);
    defer copy.deinit(gpa);
    try doc.shrinkToFit(gpa);
    try testing.expectEqual(@as(u32, 82), try copy.view().count(root));
}

test "allocation failure: Document operations never leak" {
    try testing.checkAllAllocationFailures(testing.allocator, buildGrowing, .{});
}

fn decodeJson(gpa: std.mem.Allocator) !void {
    var doc = try lite3.Document.fromJson(gpa, "{\"a\":[1,2,{\"b\":\"c\"}],\"d\":1.5,\"e\":null}", .{});
    defer doc.deinit(gpa);
    try doc.decodeJson(gpa, "[true,false,[[[]]]]", null);
    try testing.expectEqual(@as(u32, 3), try doc.view().count(root));
}

test "allocation failure: JSON decoding never leaks" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, decodeJson, .{});
}

test "allocation failure: a failed write leaves the document intact" {
    var fail_at: usize = 0;
    while (fail_at < 64) : (fail_at += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at, .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var doc = lite3.Document.initOptions(gpa, .{ .root = .object, .initial_capacity = 128 }) catch continue;
        defer doc.deinit(gpa);
        var kb: [16]u8 = undefined;
        var written: usize = 0;
        while (written < 200) : (written += 1) {
            doc.set(gpa, root, try std.fmt.bufPrint(&kb, "k{d}", .{written}), written) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            };
        }
        try lite3.validateStrict(testing.allocator, doc.slice());
        try testing.expectEqual(@as(u32, @intCast(written)), try doc.view().count(root));
        for (0..written) |i| try testing.expectEqual(@as(i64, @intCast(i)), try doc.view().get(i64, root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
        if (written == 200) break;
    }
}

// ---------------------------------------------------------------------------
// Golden bytes
// ---------------------------------------------------------------------------

/// Builds `src/testdata/sample.lite3`. If the output changes on purpose,
/// regenerate the fixture from the repository root with
/// `LITE3_UPDATE_GOLDEN=1 zig build test` and review the diff.
fn buildGolden(buf: *lite3.Buffer) !void {
    try @import("api_tests.zig").buildSample(buf);
    const nested = try buf.setObject(root, "nested");
    try buf.set(nested, "flag", true);
    try buf.set(nested, "nothing", null);
    try buf.set(nested, "neg", -42);
    try buf.set(nested, "pi", 3.141592653589793);
}

test "golden: serialized bytes match the checked-in fixture" {
    const expected = @embedFile("testdata/sample.lite3");
    const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 16);
    defer testing.allocator.free(mem);
    @memset(mem, 0);
    var buf = try lite3.Buffer.init(mem, .object);
    try buildGolden(&buf);
    if (try testing.environ.containsUnempty(testing.allocator, "LITE3_UPDATE_GOLDEN")) {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = "src/testdata/sample.lite3", .data = buf.slice() });
        return;
    }
    try testing.expectEqualSlices(u8, expected, buf.slice());

    // The fixture is also readable on its own.
    const aligned = try testing.allocator.alignedAlloc(u8, .@"4", expected.len);
    defer testing.allocator.free(aligned);
    @memcpy(aligned, expected);
    const v = try lite3.View.fromBytes(aligned);
    try lite3.validateStrict(testing.allocator, aligned);
    try testing.expectEqual(@as(i64, -42), try v.get(i64, try v.getObject(root, "nested"), "neg"));
}
