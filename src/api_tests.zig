// Behaviour tests for the public API. Most run against every document type
// (Buffer, Document, ManagedDocument) through test_util.Backend.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");
const util = @import("test_util.zig");
const root = lite3.root;

fn bitsEqual(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

test "set/get every scalar type, exact values" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "null", null);
        try d.set(root, "t", true);
        try d.set(root, "f", false);
        try d.set(root, "min", std.math.minInt(i64));
        try d.set(root, "max", std.math.maxInt(i64));
        try d.set(root, "u8", @as(u8, 200));
        try d.set(root, "neg0", -0.0);
        try d.set(root, "denorm", std.math.floatTrueMin(f64));
        try d.set(root, "fmax", std.math.floatMax(f64));
        try d.set(root, "str", "héllo\x00world"); // values may contain NUL
        try d.set(root, "empty", "");
        try d.set(root, "bytes", lite3.bytes(&.{ 0, 1, 255 }));
        try d.set(root, "nobytes", lite3.bytes(&.{}));
        try lite3.validate(d.slice());

        const v = d.view();
        try testing.expectEqual(lite3.Value.null, try v.getValue(root, "null"));
        try testing.expectEqual(true, try v.get(bool, root, "t"));
        try testing.expectEqual(false, try v.get(bool, root, "f"));
        try testing.expectEqual(std.math.minInt(i64), try v.get(i64, root, "min"));
        try testing.expectEqual(std.math.maxInt(i64), try v.get(i64, root, "max"));
        try testing.expectEqual(@as(u8, 200), try v.get(u8, root, "u8"));
        try testing.expect(bitsEqual(-0.0, try v.get(f64, root, "neg0")));
        try testing.expect(bitsEqual(std.math.floatTrueMin(f64), try v.get(f64, root, "denorm")));
        try testing.expect(bitsEqual(std.math.floatMax(f64), try v.get(f64, root, "fmax")));
        try testing.expectEqualSlices(u8, "héllo\x00world", try v.get([]const u8, root, "str"));
        try testing.expectEqualSlices(u8, "", try v.get([]const u8, root, "empty"));
        try testing.expectEqualSlices(u8, &.{ 0, 1, 255 }, (try v.get(lite3.Bytes, root, "bytes")).data);
        try testing.expectEqual(@as(usize, 0), (try v.get(lite3.Bytes, root, "nobytes")).data.len);
        try testing.expectEqual(@as(?i64, null), try v.get(?i64, root, "null"));
        try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), try v.get(?i64, root, "max"));
        try testing.expectEqual(@as(u32, 13), try v.count(root));
    }
}

test "read errors are specific" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "n", 300);
        try d.set(root, "s", "x");
        const arr = try d.setArray(root, "a");
        try d.append(arr, 1);
        const v = d.view();
        try testing.expectError(error.NotFound, v.get(i64, root, "missing"));
        try testing.expectError(error.TypeMismatch, v.get(bool, root, "n"));
        try testing.expectError(error.TypeMismatch, v.get([]const u8, root, "n"));
        try testing.expectError(error.TypeMismatch, v.get(lite3.Bytes, root, "s"));
        try testing.expectError(error.IntegerOverflow, v.get(u8, root, "n"));
        try testing.expectError(error.TypeMismatch, v.get(i64, arr, "n")); // array is not an object
        try testing.expectError(error.TypeMismatch, v.arrGet(i64, root, 0)); // object is not an array
        try testing.expectError(error.IndexOutOfBounds, v.arrGet(i64, arr, 1));
        try testing.expectError(error.TypeMismatch, v.getObject(root, "n"));
        try testing.expectError(error.InvalidOffset, v.get(i64, @fromBackingInt(2), "n"));
        try testing.expectError(error.InvalidOffset, v.count(@fromBackingInt(@intCast(d.slice().len))));
        try testing.expectEqual(false, try v.has(root, "missing"));
        try testing.expectEqual(true, try v.has(root, "n"));
        try testing.expectError(error.TypeMismatch, v.has(arr, "n"));
        try testing.expectEqual(lite3.Type.int, try v.typeOf(root, "n"));
        try testing.expectEqual(lite3.Type.array, try v.typeOf(root, "a"));
    }
}

test "write errors are specific" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        const arr = try d.setArray(root, "a");
        try testing.expectError(error.InvalidKey, d.set(root, "a\x00b", 1));
        try testing.expectError(error.TypeMismatch, d.set(arr, "k", 1));
        try testing.expectError(error.TypeMismatch, d.append(root, 1));
        try testing.expectError(error.TypeMismatch, d.setObject(arr, "k"));
        try testing.expectError(error.IndexOutOfBounds, d.arrSet(arr, 1, 1));
        try testing.expectError(error.IntegerOverflow, d.set(root, "big", @as(u64, std.math.maxInt(u64))));
        try testing.expectError(error.InvalidOffset, d.set(@fromBackingInt(1), "k", 1));
        try lite3.validate(d.slice());
    }
}

test "nesting, arrays, arrSet and overwrites" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        const user = try d.setObject(root, "user");
        try d.set(user, "name", "Ada");
        const tags = try d.setArray(user, "tags");
        for (0..10) |i| try d.append(tags, @as(i64, @intCast(i)));
        const inner = try d.appendObject(tags);
        try d.set(inner, "deep", true);
        const inner_arr = try d.appendArray(tags);
        try d.append(inner_arr, "x");

        try d.arrSet(tags, 3, "three"); // overwrite with another type
        try d.arrSet(tags, 12, 12.5); // index == count appends
        try d.set(user, "name", "Ada Lovelace, Countess"); // longer: appended
        try d.set(user, "name", "Ada"); // shorter: in place
        const replaced = try d.arrSetObject(tags, 0);
        try d.set(replaced, "was", "zero");
        try lite3.validate(d.slice());

        const v = d.view();
        const u = try v.getObject(root, "user");
        try testing.expectEqualStrings("Ada", try v.get([]const u8, u, "name"));
        const t = try v.getArray(u, "tags");
        try testing.expectEqual(@as(u32, 13), try v.count(t));
        try testing.expectEqualStrings("three", try v.arrGet([]const u8, t, 3));
        try testing.expectEqual(@as(i64, 9), try v.arrGet(i64, t, 9));
        try testing.expect(try v.get(bool, try v.arrGetObject(t, 10), "deep"));
        try testing.expectEqualStrings("x", try v.arrGet([]const u8, try v.arrGetArray(t, 11), 0));
        try testing.expect(bitsEqual(12.5, try v.arrGet(f64, t, 12)));
        try testing.expectEqualStrings("zero", try v.get([]const u8, try v.arrGetObject(t, 0), "was"));
        try testing.expectEqual(lite3.Container.object, try v.rootType());
    }
}

test "C1: growth across node splits keeps every entry (review MEM-1)" {
    inline for (.{ util.Backend(.document), util.Backend(.managed) }) |B| {
        var d = try B.initCapacity(.object, 256);
        defer d.deinit();
        const arr = try d.setArray(root, "items");
        for (0..5000) |i| try d.append(arr, @as(i64, @intCast(i)));
        var kb: [16]u8 = undefined;
        for (0..300) |i| try d.set(root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @as(i64, @intCast(i)));
        try d.set(root, "big", &@as([2000]u8, @splat('v')));
        try lite3.validate(d.slice());

        const v = d.view();
        const a = try v.getArray(root, "items");
        for (0..5000) |i| try testing.expectEqual(@as(i64, @intCast(i)), try v.arrGet(i64, a, @intCast(i)));
        for (0..300) |i| try testing.expectEqual(@as(i64, @intCast(i)), try v.get(i64, root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
    }
}

test "C1: a full Buffer leaves a valid document behind" {
    // Fill a Buffer until it refuses writes; every refused write must leave
    // the document valid with all earlier entries readable.
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    var kb: [16]u8 = undefined;
    var written: usize = 0;
    while (true) : (written += 1) {
        buf.set(root, try std.fmt.bufPrint(&kb, "key{d}", .{written}), @as(i64, @intCast(written))) catch |err| {
            try testing.expectEqual(error.NoSpaceLeft, err);
            break;
        };
    }
    try testing.expect(written > 10);
    try lite3.validate(buf.slice());
    const v = buf.view();
    for (0..written) |i| try testing.expectEqual(@as(i64, @intCast(i)), try v.get(i64, root, try std.fmt.bufPrint(&kb, "key{d}", .{i})));
    try testing.expectEqual(@as(u32, @intCast(written)), try v.count(root));
}

test "C4: values and keys that alias the document (review MEM-4)" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "a", "a value long enough to matter");
        // Copy a field into another, and into itself (shorter, in place).
        try d.set(root, "b", try d.view().get([]const u8, root, "a"));
        try d.set(root, "a", (try d.view().get([]const u8, root, "a"))[2..7]);
        // Force growth while the source lives in the old storage.
        var kb: [16]u8 = undefined;
        for (0..200) |i| {
            try d.set(root, try std.fmt.bufPrint(&kb, "copy{d}", .{i}), try d.view().get([]const u8, root, "b"));
        }
        // A key taken from the document itself.
        try d.set(root, "keysrc", "target");
        try d.set(root, try d.view().get([]const u8, root, "keysrc"), "rekeyed");
        try lite3.validate(d.slice());

        const v = d.view();
        try testing.expectEqualStrings("value", try v.get([]const u8, root, "a"));
        try testing.expectEqualStrings("a value long enough to matter", try v.get([]const u8, root, "b"));
        try testing.expectEqualStrings("a value long enough to matter", try v.get([]const u8, root, "copy199"));
        try testing.expectEqualStrings("rekeyed", try v.get([]const u8, root, "target"));
    }
}

test "H3: views and iterators go stale after a write instead of reading freed memory" {
    inline for (util.backends) |B| {
        var d = try B.initCapacity(.object, 256);
        defer d.deinit();
        try d.set(root, "a", 1);
        try d.set(root, "b", 2);
        const v = d.view();
        var it = try v.objectIterator(root);
        _ = (try it.next()).?;
        var kb: [16]u8 = undefined;
        for (0..100) |i| try d.set(root, try std.fmt.bufPrint(&kb, "grow{d}", .{i}), @as(i64, @intCast(i)));
        try testing.expectError(error.StaleView, it.next());
        try testing.expectError(error.StaleView, v.get(i64, root, "a"));
        try testing.expectEqual(@as(i64, 1), try d.view().get(i64, root, "a"));
    }
}

test "iteration yields exact keys, values and indices" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        const lens = [_]usize{ 0, 1, 62, 63, 64, 300, 1000 };
        var kb: [2000]u8 = undefined;
        for (lens, 0..) |len, i| {
            for (kb[0..len], 0..) |*b, j| b.* = 'a' + @as(u8, @intCast((i + j) % 26));
            try d.set(root, kb[0..len], @as(i64, @intCast(len)));
        }
        const arr = try d.setArray(root, "arr");
        for (0..40) |i| try d.append(arr, @as(i64, @intCast(i * 3)));

        const v = d.view();
        var it = try v.objectIterator(root);
        var seen: usize = 0;
        while (try it.next()) |e| {
            if (std.mem.eql(u8, e.key, "arr")) continue;
            const expected_len: usize = @intCast(e.value.int);
            try testing.expectEqual(expected_len, e.key.len);
            const i = std.mem.indexOfScalar(usize, &lens, expected_len).?;
            for (e.key, 0..) |b, j| try testing.expectEqual('a' + @as(u8, @intCast((i + j) % 26)), b);
            seen += 1;
        }
        try testing.expectEqual(lens.len, seen);

        var ai = try v.arrayIterator(arr);
        var n: u32 = 0;
        while (try ai.next()) |e| : (n += 1) {
            try testing.expectEqual(n, e.index);
            try testing.expectEqual(@as(i64, n * 3), e.value.int);
        }
        try testing.expectEqual(@as(u32, 40), n);
        try testing.expectError(error.TypeMismatch, v.arrayIterator(root));
        try testing.expectError(error.TypeMismatch, v.objectIterator(arr));
    }
}

test "keys: comptime Key, runtime Key, long and plain-slice keys" {
    try testing.expectEqual(lite3.Key.init("hello").hash, lite3.key("hello").hash);
    try testing.expectEqual(lite3.Key.init("").hash, lite3.key("").hash);
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        const k = lite3.key("count");
        try d.set(root, k, 1);
        try testing.expectEqual(@as(i64, 1), try d.view().get(i64, root, "count"));
        try testing.expectEqual(@as(i64, 1), try d.view().get(i64, root, k));

        // Longer than the old 255-byte limit, as a sentinel slice and as a
        // plain slice (copied internally).
        var long: [3000:0]u8 = @splat('L');
        try d.set(root, @as([:0]const u8, &long), "sentinel");
        const plain: []const u8 = long[0..1000];
        try d.set(root, plain, "plain");
        try testing.expectEqualStrings("sentinel", try d.view().get([]const u8, root, @as([]const u8, &long)));
        try testing.expectEqualStrings("plain", try d.view().get([]const u8, root, plain));
        try lite3.validate(d.slice());
    }
    // A Buffer cannot copy a long plain-slice key.
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    const too_long: []const u8 = &@as([lite3.max_stack_key_len + 1]u8, @splat('k'));
    try testing.expectError(error.KeyTooLong, buf.set(root, too_long, 1));
}

test "JSON encoding: exact output, escapes, floats, bytes, pretty" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "s", "a\"b\\c\n\x01é");
        try d.set(root, "i", -42);
        try d.set(root, "f", 1.0);
        try d.set(root, "g", 0.1);
        try d.set(root, "z", -0.0);
        try d.set(root, "e", 1e300);
        try d.set(root, "b", lite3.bytes("abc"));
        try d.set(root, "n", null);
        const arr = try d.setArray(root, "a");
        try d.append(arr, true);
        _ = try d.appendObject(arr);
        _ = try d.appendArray(arr);
        const json = try d.view().jsonAlloc(testing.allocator, root, .{});
        defer testing.allocator.free(json);
        // Key order is lite3's (hash) order; check each member.
        for ([_][]const u8{
            "\"s\":\"a\\\"b\\\\c\\n\\u0001é\"",
            "\"i\":-42",
            "\"f\":1.0",
            "\"g\":0.1",
            "\"z\":-0.0",
            "\"e\":1e300",
            "\"b\":\"YWJj\"",
            "\"n\":null",
            "\"a\":[true,{},[]]",
        }) |member| {
            if (std.mem.indexOf(u8, json, member) == null) {
                std.debug.print("missing {s} in {s}\n", .{ member, json });
                return error.TestUnexpectedResult;
            }
        }
        try testing.expect(json[0] == '{' and json[json.len - 1] == '}');

        const pretty = try d.view().jsonAlloc(testing.allocator, arr, .{ .whitespace = .indent_2 });
        defer testing.allocator.free(pretty);
        try testing.expectEqualStrings("[\n  true,\n  {},\n  []\n]\n", pretty);

        // `{f}` formats the whole document as compact JSON.
        const formatted = try std.fmt.allocPrint(testing.allocator, "{f}", .{d.view()});
        defer testing.allocator.free(formatted);
        try testing.expectEqualStrings(json, formatted);
    }
}

test "JSON encoding errors" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "nan", std.math.nan(f64));
        var w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer w.deinit();
        try testing.expectError(error.NonFiniteNumber, d.view().writeJson(root, &w.writer, .{}));
        try d.set(root, "nan", "\xff\xfe");
        try testing.expectError(error.InvalidUtf8, d.view().writeJson(root, &w.writer, .{}));
    }
}

test "JSON decoding: values, diagnostics and specific errors" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    const a = testing.allocator;
    var doc = try lite3.Document.fromJson(a, "{\"a\":[1,2.5,\"s\",true,null,{\"k\":-7}],\"big\":18446744073709551615}", .{});
    defer doc.deinit(a);
    const v = doc.view();
    const arr = try v.getArray(root, "a");
    try testing.expectEqual(@as(i64, 1), try v.arrGet(i64, arr, 0));
    try testing.expect(bitsEqual(2.5, try v.arrGet(f64, arr, 1)));
    try testing.expectEqualStrings("s", try v.arrGet([]const u8, arr, 2));
    try testing.expectEqual(@as(i64, -7), try v.get(i64, try v.arrGetObject(arr, 5), "k"));
    try testing.expectEqual(lite3.Type.float, try v.typeOf(root, "big")); // u64 > maxInt(i64)
    try lite3.validate(doc.slice());

    var diag: lite3.JsonDiagnostics = .{};
    try testing.expectError(error.SyntaxError, lite3.Document.fromJson(a, "{\"a\": 1, \"b\": }", .{ .diagnostics = &diag }));
    try testing.expectEqual(@as(usize, 14), diag.position);
    try testing.expect(diag.message.len > 0);
    try testing.expectError(error.InvalidRoot, lite3.Document.fromJson(a, "42", .{}));
    try testing.expectError(error.InvalidKey, lite3.Document.fromJson(a, "{\"a\\u0000b\":1}", .{}));
    try testing.expectError(error.NestingTooDeep, lite3.Document.fromJson(a, &(util.repeat("[", 33) ++ util.repeat("]", 33)), .{}));
    var deep = try lite3.Document.fromJson(a, &(util.repeat("[", 32) ++ util.repeat("]", 32)), .{});
    deep.deinit(a);
}

test "JSON decoding: strong guarantee and limits" {
    if (!lite3.json_enabled) return error.SkipZigTest;
    const a = testing.allocator;
    var doc = try lite3.Document.init(a, .object);
    defer doc.deinit(a);
    try doc.set(a, root, "keep", "me");
    try testing.expectError(error.SyntaxError, doc.decodeJson(a, "{oops", null));
    try testing.expectEqualStrings("me", try doc.view().get([]const u8, root, "keep"));
    try doc.decodeJson(a, "{\"new\":1}", null);
    try testing.expectEqual(@as(i64, 1), try doc.view().get(i64, root, "new"));
    try testing.expectEqual(false, try doc.view().has(root, "keep"));

    var small = try lite3.Document.initOptions(a, .{ .max_capacity = 4096 });
    defer small.deinit(a);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try json.append(a, '[');
    for (0..2000) |_| try json.appendSlice(a, "1,");
    try json.appendSlice(a, "1]");
    try testing.expectError(error.NoSpaceLeft, small.decodeJson(a, json.items, null));
    try testing.expect(small.capacity() <= 4096);

    var mem: [512]u8 align(4) = undefined;
    try testing.expectError(error.NoSpaceLeft, lite3.Buffer.fromJson(a, &mem, json.items, null));
    const ok = try lite3.Buffer.fromJson(a, &mem, "{\"x\":1}", null);
    try testing.expectEqual(@as(i64, 1), try ok.view().get(i64, root, "x"));
}

test "Document: capacity management, max_capacity, clone, compact" {
    const a = testing.allocator;
    var doc = try lite3.Document.initOptions(a, .{ .max_capacity = 4096 });
    defer doc.deinit(a);
    try testing.expectError(error.NoSpaceLeft, doc.set(a, root, "big", &@as([5000]u8, @splat('x'))));
    try lite3.validate(doc.slice());
    try doc.reserve(a, 2000);
    try testing.expect(doc.capacity() >= doc.slice().len + 2000);
    try testing.expectError(error.NoSpaceLeft, doc.reserve(a, 1 << 20));

    // Overwrite one key many times, then compact.
    var big = try lite3.Document.init(a, .object);
    defer big.deinit(a);
    // Each value is longer than the last, so it is appended and the old one
    // becomes dead space.
    var status: [200]u8 = undefined;
    for (0..200) |i| {
        @memset(status[0 .. i + 1], @intCast('a' + i % 26));
        try big.set(a, root, "status", status[0 .. i + 1]);
    }
    const nested = try big.setObject(a, root, "n");
    try big.set(a, nested, "x", lite3.bytes("raw"));
    const before = big.slice().len;
    var copy = try big.clone(a);
    defer copy.deinit(a);
    try big.compact(a);
    try testing.expect(big.slice().len < before / 10);
    try lite3.validate(big.slice());
    try lite3.validate(copy.slice());
    for ([_]lite3.View{ big.view(), copy.view() }) |v| {
        try testing.expectEqual(@as(u8, 'a' + 199 % 26), (try v.get([]const u8, root, "status"))[0]);
        try testing.expectEqualStrings("raw", (try v.get(lite3.Bytes, try v.getObject(root, "n"), "x")).data);
    }
    try big.shrinkToFit(a);
    try testing.expectEqual(std.mem.alignForward(usize, big.slice().len, 4), big.capacity());
}

test "importBytes and fromBytes validate; own bytes are fine" {
    const a = testing.allocator;
    var src = try lite3.Document.init(a, .object);
    defer src.deinit(a);
    try src.set(a, root, "name", "Alice");

    var doc = try lite3.Document.fromBytes(a, src.slice());
    defer doc.deinit(a);
    try testing.expectEqualStrings("Alice", try doc.view().get([]const u8, root, "name"));
    try doc.importBytes(a, doc.slice()); // own bytes
    try testing.expectEqualStrings("Alice", try doc.view().get([]const u8, root, "name"));

    const bad = try a.dupe(u8, src.slice());
    defer a.free(bad);
    bad[32] +%= 1 << 6; // element count
    try testing.expectError(error.CorruptData, doc.importBytes(a, bad));
    try testing.expectEqualStrings("Alice", try doc.view().get([]const u8, root, "name"));
    try testing.expectError(error.CorruptData, lite3.Document.fromBytes(a, bad));
    try testing.expectError(error.CorruptData, lite3.View.fromBytes(bad));

    var mem: [1024]u8 align(4) = undefined;
    @memcpy(mem[0..bad.len], bad);
    try testing.expectError(error.CorruptData, lite3.Buffer.fromBytes(&mem, bad.len));
    @memcpy(mem[0..src.slice().len], src.slice());
    const buf = try lite3.Buffer.fromBytes(&mem, src.slice().len);
    try testing.expectEqualStrings("Alice", try buf.view().get([]const u8, root, "name"));
}

test "reset and array roots" {
    inline for (util.backends) |B| {
        var d = try B.init(.array);
        defer d.deinit();
        try d.append(root, 1);
        try d.append(root, "two");
        try testing.expectEqual(lite3.Container.array, try d.view().rootType());
        try testing.expectEqual(@as(u32, 2), try d.view().count(root));
        try d.reset(.object);
        try testing.expectEqual(lite3.Container.object, try d.view().rootType());
        try testing.expectEqual(@as(u32, 0), try d.view().count(root));
    }
}

test "SEC-12: hash-probe exhaustion is KeyCollision, absent keys stay NotFound" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        var kb: [16]u8 = undefined;
        for (0..128) |i| try d.set(root, collidingKey(&kb, i), @as(i64, @intCast(i)));
        try testing.expectError(error.KeyCollision, d.set(root, collidingKey(&kb, 128), 0));
        try testing.expectError(error.NotFound, d.view().get(i64, root, collidingKey(&kb, 200)));
        for (0..128) |i| try testing.expectEqual(@as(i64, @intCast(i)), try d.view().get(i64, root, collidingKey(&kb, i)));
        try lite3.validate(d.slice());
    }
}

/// The `i`-th of 256 distinct 16-byte keys sharing one DJB2 hash ("Aa" and
/// "B@" collide, and so does any concatenation of such blocks).
fn collidingKey(buf: *[16]u8, i: usize) []const u8 {
    for (0..8) |bit| @memcpy(buf[2 * bit ..][0..2], if ((i >> @intCast(bit)) & 1 == 0) "Aa" else "B@");
    return buf;
}

test "no uninitialized memory leaks into documents" {
    // Build the same document in memory pre-filled with different garbage:
    // the serialized bytes must be identical (patch 0010 + LITE3_ZERO_MEM_*).
    var results: [2][]u8 = undefined;
    for ([_]u8{ 0x00, 0xff }, 0..) |fill, n| {
        var mem: [65536]u8 align(4) = undefined;
        @memset(&mem, fill);
        var buf = try lite3.Buffer.init(&mem, .object);
        try buildSample(&buf);
        results[n] = try testing.allocator.dupe(u8, buf.slice());
    }
    defer for (results) |r| testing.allocator.free(r);
    try testing.expectEqualSlices(u8, results[0], results[1]);
}

/// A deterministic document exercising splits, overwrites and nesting.
pub fn buildSample(buf: *lite3.Buffer) !void {
    var kb: [16]u8 = undefined;
    for (0..60) |i| try buf.set(root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @as(i64, @intCast(i)));
    try buf.set(root, "k3", "overwritten with a string");
    try buf.set(root, "k5", "short");
    try buf.set(root, "k5", "x");
    const arr = try buf.setArray(root, "arr");
    for (0..30) |i| try buf.append(arr, @as(f64, @floatFromInt(i)) / 2.0);
    const obj = try buf.appendObject(arr);
    try buf.set(obj, "b", lite3.bytes(&.{ 1, 2, 3 }));
    try buf.set(root, "swap", "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789");
    _ = try buf.setObject(root, "swap");
}

test "JSON encoding escapes every control character" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .array);
    try buf.append(root, "\x01\x0f\x10\x1f\x7f");
    const json = try buf.view().jsonAlloc(testing.allocator, root, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[\"\\u0001\\u000f\\u0010\\u001f\x7f\"]", json);
}

test "JSON encoding: nesting limit is exact" {
    inline for (.{ lite3.Container.object, lite3.Container.array }) |kind| {
        const mem = try testing.allocator.alignedAlloc(u8, .@"4", 1 << 16);
        defer testing.allocator.free(mem);
        var buf = try lite3.Buffer.init(mem, kind);
        var at = root;
        var sink: std.Io.Writer.Discarding = .init(&.{});
        // The root is level 1; max_nesting_depth levels encode, one more does not.
        for (1..lite3.max_nesting_depth + 1) |level| {
            if (level == lite3.max_nesting_depth) {
                try buf.view().writeJson(root, &sink.writer, .{});
            }
            at = switch (kind) {
                .object => try buf.setObject(at, "n"),
                .array => try buf.appendArray(at),
            };
        }
        // Built through a Buffer, which does not limit depth; validate does.
        try testing.expectError(error.CorruptData, lite3.validate(buf.slice()));
        try testing.expectError(error.NestingTooDeep, buf.view().writeJson(root, &sink.writer, .{}));
    }
}

test "a value that partly overlaps the document is copied before writing" {
    // The value starts before the Buffer's memory and ends inside its root
    // node, which every write modifies.
    var backing: [4096]u8 align(4) = undefined;
    @memset(backing[0..8], 'x');
    var buf = try lite3.Buffer.init(backing[8..], .object);
    try buf.set(root, "a", 1);
    const value = backing[0..40];
    var expected: [40]u8 = undefined;
    @memcpy(&expected, value);
    try buf.set(root, "k", lite3.bytes(value));
    try testing.expectEqualSlices(u8, &expected, (try buf.view().get(lite3.Bytes, root, "k")).data);
}

test "a NUL-terminated key that lies inside the document is copied before writing" {
    inline for (util.backends) |B| {
        var d = try B.init(.object);
        defer d.deinit();
        try d.set(root, "target", 1);
        // Keys are stored NUL-terminated, so a key slice read back from the
        // document can be used as a [:0]const u8 that points into it.
        var it = try d.view().objectIterator(root);
        const k = (try it.next()).?.key;
        const z: [:0]const u8 = k.ptr[0..k.len :0];
        // A longer value does not fit in place, so the entry is rewritten.
        try d.set(root, z, "a value much longer than the eight bytes of an integer");
        try lite3.validate(d.slice());
        try testing.expectEqualStrings("a value much longer than the eight bytes of an integer", try d.view().get([]const u8, root, "target"));
        try testing.expectEqual(@as(u32, 1), try d.view().count(root));
    }
}

test "a container type byte at a misaligned offset is corrupt" {
    // Unvalidated bytes: a string value whose type byte is changed to
    // "object" must not be read as a container unless it is 4-aligned.
    for (1..5) |key_len| {
        var mem: [1024]u8 align(4) = @splat(0);
        var buf = try lite3.Buffer.init(&mem, .object);
        const k = util.repeat("k", 4)[0..key_len];
        try buf.set(root, k, &util.repeat("s", 120));
        const at = std.mem.indexOf(u8, buf.slice(), "ssss").? - 5; // type byte
        if (at % 4 == 0) continue;
        mem[at] = 6;
        const v = lite3.View.fromBytesUnchecked(buf.slice());
        try testing.expectError(error.CorruptData, v.getValue(root, k));
        return;
    }
    return error.TestNoMisalignedValue;
}
