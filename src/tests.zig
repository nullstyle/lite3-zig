// Comprehensive tests for the lite3-zig wrapper.
//
// Tests cover both the Buffer API and the Context API, including:
//   - Initialization (object and array)
//   - Setting and getting all value types (null, bool, i64, f64, string, bytes)
//   - Nested objects and arrays
//   - Array append and indexed access
//   - Iteration over objects and arrays
//   - JSON encode/decode round-trips
//   - Error handling (key not found, buffer too small, type mismatches)
//   - Context API equivalents of all the above
//   - Interoperability: Buffer → Context import

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

// =========================================================================
// Buffer API tests
// =========================================================================

test "Buffer: init object" {
    var mem: [4096]u8 align(4) = undefined;
    const buf = try lite3.Buffer.initObj(&mem);
    try testing.expect(buf.len > 0);
    try testing.expect(buf.capacity == 4096);
}

test "Buffer: init array" {
    var mem: [4096]u8 align(4) = undefined;
    const buf = try lite3.Buffer.initArr(&mem);
    try testing.expect(buf.len > 0);
}

test "Buffer: set and get i64" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "answer", 42);
    const val = try buf.getI64(lite3.root, "answer");
    try testing.expectEqual(@as(i64, 42), val);
}

test "Buffer: set and get negative i64" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "negative", -9999);
    const val = try buf.getI64(lite3.root, "negative");
    try testing.expectEqual(@as(i64, -9999), val);
}

test "Buffer: set and get f64" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setF64(lite3.root, "pi", 3.14159265358979);
    const val = try buf.getF64(lite3.root, "pi");
    try testing.expectApproxEqAbs(@as(f64, 3.14159265358979), val, 1e-12);
}

test "Buffer: set and get bool" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setBool(lite3.root, "flag_true", true);
    try buf.setBool(lite3.root, "flag_false", false);

    try testing.expectEqual(true, try buf.getBool(lite3.root, "flag_true"));
    try testing.expectEqual(false, try buf.getBool(lite3.root, "flag_false"));
}

test "Buffer: set and get null" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setNull(lite3.root, "nothing");
    const t = try buf.getType(lite3.root, "nothing");
    try testing.expectEqual(lite3.Type.null, t);
}

test "Buffer: set and get string" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "greeting", "hello world");
    const s = try buf.getStr(lite3.root, "greeting");
    try testing.expectEqualStrings("hello world", s);
}

test "Buffer: set and get empty string" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "empty", "");
    const s = try buf.getStr(lite3.root, "empty");
    try testing.expectEqualStrings("", s);
}

test "Buffer: set and get bytes" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try buf.setBytes(lite3.root, "data", &payload);
    const b = try buf.getBytes(lite3.root, "data");
    try testing.expectEqualSlices(u8, &payload, b);
}

test "Buffer: exists and not found" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "present", 1);
    try testing.expect(buf.exists(lite3.root, "present"));
    try testing.expect(!buf.exists(lite3.root, "absent"));
}

test "Buffer: get type" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "num", 10);
    try buf.setStr(lite3.root, "text", "hi");
    try buf.setBool(lite3.root, "flag", true);
    try buf.setF64(lite3.root, "decimal", 1.5);
    try buf.setNull(lite3.root, "nil");

    try testing.expectEqual(lite3.Type.i64_, try buf.getType(lite3.root, "num"));
    try testing.expectEqual(lite3.Type.string, try buf.getType(lite3.root, "text"));
    try testing.expectEqual(lite3.Type.bool_, try buf.getType(lite3.root, "flag"));
    try testing.expectEqual(lite3.Type.f64_, try buf.getType(lite3.root, "decimal"));
    try testing.expectEqual(lite3.Type.null, try buf.getType(lite3.root, "nil"));
}

test "Buffer: count entries" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "a", 1);
    try buf.setI64(lite3.root, "b", 2);
    try buf.setI64(lite3.root, "c", 3);

    const n = try buf.count(lite3.root);
    try testing.expectEqual(@as(u32, 3), n);
}

test "Buffer: overwrite value" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "val", 100);
    try testing.expectEqual(@as(i64, 100), try buf.getI64(lite3.root, "val"));

    try buf.setI64(lite3.root, "val", 200);
    try testing.expectEqual(@as(i64, 200), try buf.getI64(lite3.root, "val"));
}

test "Buffer: nested object" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const child_ofs = try buf.setObj(lite3.root, "child");
    try buf.setStr(child_ofs, "name", "nested");
    try buf.setI64(child_ofs, "value", 42);

    const retrieved_ofs = try buf.getObj(lite3.root, "child");
    try testing.expectEqualStrings("nested", try buf.getStr(retrieved_ofs, "name"));
    try testing.expectEqual(@as(i64, 42), try buf.getI64(retrieved_ofs, "value"));
}

test "Buffer: deeply nested objects" {
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const l1 = try buf.setObj(lite3.root, "level1");
    const l2 = try buf.setObj(l1, "level2");
    const l3 = try buf.setObj(l2, "level3");
    try buf.setStr(l3, "deep", "value");

    const r1 = try buf.getObj(lite3.root, "level1");
    const r2 = try buf.getObj(r1, "level2");
    const r3 = try buf.getObj(r2, "level3");
    try testing.expectEqualStrings("value", try buf.getStr(r3, "deep"));
}

test "Buffer: array append and get" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    try buf.arrAppendI64(lite3.root, 10);
    try buf.arrAppendI64(lite3.root, 20);
    try buf.arrAppendI64(lite3.root, 30);

    try testing.expectEqual(@as(i64, 10), try buf.arrGetI64(lite3.root, 0));
    try testing.expectEqual(@as(i64, 20), try buf.arrGetI64(lite3.root, 1));
    try testing.expectEqual(@as(i64, 30), try buf.arrGetI64(lite3.root, 2));
}

test "Buffer: array with mixed types" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    try buf.arrAppendNull(lite3.root);
    try buf.arrAppendBool(lite3.root, true);
    try buf.arrAppendI64(lite3.root, 42);
    try buf.arrAppendF64(lite3.root, 3.14);
    try buf.arrAppendStr(lite3.root, "hello");

    try testing.expectEqual(lite3.Type.null, buf.arrGetType(lite3.root, 0));
    try testing.expectEqual(lite3.Type.bool_, buf.arrGetType(lite3.root, 1));
    try testing.expectEqual(lite3.Type.i64_, buf.arrGetType(lite3.root, 2));
    try testing.expectEqual(lite3.Type.f64_, buf.arrGetType(lite3.root, 3));
    try testing.expectEqual(lite3.Type.string, buf.arrGetType(lite3.root, 4));

    try testing.expectEqual(true, try buf.arrGetBool(lite3.root, 1));
    try testing.expectEqual(@as(i64, 42), try buf.arrGetI64(lite3.root, 2));
    try testing.expectApproxEqAbs(@as(f64, 3.14), try buf.arrGetF64(lite3.root, 3), 1e-10);
    try testing.expectEqualStrings("hello", try buf.arrGetStr(lite3.root, 4));
}

test "Buffer: array of strings" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    try buf.arrAppendStr(lite3.root, "alpha");
    try buf.arrAppendStr(lite3.root, "beta");
    try buf.arrAppendStr(lite3.root, "gamma");

    const n = try buf.count(lite3.root);
    try testing.expectEqual(@as(u32, 3), n);

    try testing.expectEqualStrings("alpha", try buf.arrGetStr(lite3.root, 0));
    try testing.expectEqualStrings("gamma", try buf.arrGetStr(lite3.root, 2));
}

test "Buffer: array of bytes" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    try buf.arrAppendBytes(lite3.root, &[_]u8{ 1, 2, 3 });
    try buf.arrAppendBytes(lite3.root, &[_]u8{ 4, 5, 6 });

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, try buf.arrGetBytes(lite3.root, 0));
}

test "Buffer: nested array in object" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const arr_ofs = try buf.setArr(lite3.root, "numbers");
    try buf.arrAppendI64(arr_ofs, 1);
    try buf.arrAppendI64(arr_ofs, 2);
    try buf.arrAppendI64(arr_ofs, 3);

    const retrieved_arr = try buf.getArr(lite3.root, "numbers");
    try testing.expectEqual(@as(u32, 3), try buf.count(retrieved_arr));
    try testing.expectEqual(@as(i64, 2), try buf.arrGetI64(retrieved_arr, 1));
}

test "Buffer: nested object in array" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const obj_ofs = try buf.arrAppendObj(lite3.root);
    try buf.setStr(obj_ofs, "name", "item1");
    try buf.setI64(obj_ofs, "value", 100);

    const retrieved_obj = try buf.arrGetObj(lite3.root, 0);
    try testing.expectEqual(@as(i64, 100), try buf.getI64(retrieved_obj, "value"));
}

test "Buffer: nested array in array" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const inner = try buf.arrAppendArr(lite3.root);
    try buf.arrAppendI64(inner, 10);
    try buf.arrAppendI64(inner, 20);

    const retrieved = try buf.arrGetArr(lite3.root, 0);
    try testing.expectEqual(@as(i64, 10), try buf.arrGetI64(retrieved, 0));
    try testing.expectEqual(@as(i64, 20), try buf.arrGetI64(retrieved, 1));
}

test "Buffer: object iterator" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "x", 1);
    try buf.setI64(lite3.root, "y", 2);
    try buf.setI64(lite3.root, "z", 3);

    var iter = try buf.iterate(lite3.root);
    var entry_count: u32 = 0;

    while (try iter.next()) |entry| {
        entry_count += 1;
        try testing.expect(entry.key != null);
    }

    try testing.expectEqual(@as(u32, 3), entry_count);
}

test "Buffer: array iterator" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    try buf.arrAppendI64(lite3.root, 100);
    try buf.arrAppendI64(lite3.root, 200);
    try buf.arrAppendI64(lite3.root, 300);

    var iter = try buf.iterate(lite3.root);
    var count: u32 = 0;

    while (try iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(u32, 3), count);
}

test "Buffer: JSON encode and decode round-trip" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "name", "test");
    try buf.setI64(lite3.root, "value", 42);
    try buf.setBool(lite3.root, "active", true);

    const json = try buf.jsonEncode(lite3.root);
    defer std.c.free(@ptrCast(@constCast(json.ptr)));

    // Decode the JSON back into a new buffer
    var mem2: [8192]u8 align(4) = undefined;
    var buf2 = try lite3.Buffer.jsonDecode(&mem2, json);

    try testing.expectEqual(@as(i64, 42), try buf2.getI64(lite3.root, "value"));
    try testing.expectEqual(true, try buf2.getBool(lite3.root, "active"));
    try testing.expectEqualStrings("test", try buf2.getStr(lite3.root, "name"));
}

test "Buffer: JSON pretty encode" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "x", 1);

    const json = try buf.jsonEncodePretty(lite3.root);
    defer std.c.free(@ptrCast(@constCast(json.ptr)));

    // Pretty JSON should contain newlines and indentation
    try testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}

test "Buffer: JSON encode to buffer" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "val", 99);

    var json_buf: [1024]u8 = undefined;
    const written = try buf.jsonEncodeBuf(lite3.root, &json_buf);
    try testing.expect(written > 0);

    const json_str = json_buf[0..written];
    try testing.expect(std.mem.indexOf(u8, json_str, "99") != null);
}

test "Buffer: JSON decode from string" {
    const json =
        \\{"name":"alice","age":30,"scores":[100,95,88]}
    ;
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.jsonDecode(&mem, json);

    try testing.expectEqualStrings("alice", try buf.getStr(lite3.root, "name"));
    try testing.expectEqual(@as(i64, 30), try buf.getI64(lite3.root, "age"));

    const scores_ofs = try buf.getArr(lite3.root, "scores");
    try testing.expectEqual(@as(i64, 100), try buf.arrGetI64(scores_ofs, 0));
    try testing.expectEqual(@as(i64, 95), try buf.arrGetI64(scores_ofs, 1));
    try testing.expectEqual(@as(i64, 88), try buf.arrGetI64(scores_ofs, 2));
}

test "Buffer: error on key not found" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const result = buf.getI64(lite3.root, "nonexistent");
    try testing.expectError(lite3.Error.NotFound, result);
}

test "Buffer: error on type mismatch" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "text", "hello");
    const result = buf.getI64(lite3.root, "text");
    try testing.expectError(lite3.Error.InvalidArgument, result);
}

test "Buffer: error on buffer too small" {
    // Use a very small buffer that can barely hold the root node
    var mem: [96]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    // Try to insert a large entry to overflow
    const result = buf.setStr(lite3.root, "a_very_long_key_name_that_takes_space", "a_very_long_value_that_also_takes_space");
    try testing.expectError(lite3.Error.NoBufferSpace, result);
}

test "Buffer: multiple values" {
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "first_name", "John");
    try buf.setStr(lite3.root, "last_name", "Doe");
    try buf.setI64(lite3.root, "age", 30);
    try buf.setF64(lite3.root, "height", 5.11);
    try buf.setBool(lite3.root, "active", true);
    try buf.setNull(lite3.root, "middle_name");

    const n = try buf.count(lite3.root);
    try testing.expectEqual(@as(u32, 6), n);

    try testing.expectEqualStrings("John", try buf.getStr(lite3.root, "first_name"));
    try testing.expectEqual(@as(i64, 30), try buf.getI64(lite3.root, "age"));
    try testing.expectApproxEqAbs(@as(f64, 5.11), try buf.getF64(lite3.root, "height"), 1e-10);
}

test "Buffer: large number of entries" {
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const n: u32 = 100;
    for (0..n) |i| {
        try buf.arrAppendI64(lite3.root, @intCast(i));
    }

    try testing.expectEqual(n, try buf.count(lite3.root));

    for (0..n) |i| {
        const val = try buf.arrGetI64(lite3.root, @intCast(i));
        try testing.expectEqual(@as(i64, @intCast(i)), val);
    }
}

// =========================================================================
// Context API tests
// =========================================================================

test "Context: create and destroy" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
}

test "Context: init object and set/get i64" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "answer", 42);
    const val = try ctx.getI64(lite3.root, "answer");
    try testing.expectEqual(@as(i64, 42), val);
}

test "Context: set and get all types" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setNull(lite3.root, "nil");
    try ctx.setBool(lite3.root, "flag", true);
    try ctx.setI64(lite3.root, "num", 123);
    try ctx.setF64(lite3.root, "decimal", 2.718);
    try ctx.setStr(lite3.root, "text", "hello");
    try ctx.setBytes(lite3.root, "data", &[_]u8{ 0xCA, 0xFE });

    try testing.expectEqual(lite3.Type.null, ctx.getType(lite3.root, "nil"));
    try testing.expectEqual(true, try ctx.getBool(lite3.root, "flag"));
    try testing.expectEqual(@as(i64, 123), try ctx.getI64(lite3.root, "num"));
    try testing.expectApproxEqAbs(@as(f64, 2.718), try ctx.getF64(lite3.root, "decimal"), 1e-10);
    try testing.expectEqualStrings("hello", try ctx.getStr(lite3.root, "text"));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xCA, 0xFE }, try ctx.getBytes(lite3.root, "data"));
}

test "Context: exists" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "present", 1);
    try testing.expect(ctx.exists(lite3.root, "present"));
    try testing.expect(!ctx.exists(lite3.root, "absent"));
}

test "Context: count" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "a", 1);
    try ctx.setI64(lite3.root, "b", 2);
    try testing.expectEqual(@as(u32, 2), try ctx.count(lite3.root));
}

test "Context: nested object" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    const child = try ctx.setObj(lite3.root, "child");
    try ctx.setStr(child, "name", "nested");
    try ctx.setI64(child, "value", 99);

    const retrieved = try ctx.getObj(lite3.root, "child");
    try testing.expectEqualStrings("nested", try ctx.getStr(retrieved, "name"));
    try testing.expectEqual(@as(i64, 99), try ctx.getI64(retrieved, "value"));
}

test "Context: nested array" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    const arr = try ctx.setArr(lite3.root, "items");
    try ctx.arrAppendI64(arr, 10);
    try ctx.arrAppendI64(arr, 20);

    const retrieved = try ctx.getArr(lite3.root, "items");
    try testing.expectEqual(@as(i64, 10), try ctx.arrGetI64(retrieved, 0));
    try testing.expectEqual(@as(i64, 20), try ctx.arrGetI64(retrieved, 1));
}

test "Context: array operations" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    try ctx.arrAppendNull(lite3.root);
    try ctx.arrAppendBool(lite3.root, false);
    try ctx.arrAppendI64(lite3.root, 42);
    try ctx.arrAppendF64(lite3.root, 1.5);
    try ctx.arrAppendStr(lite3.root, "test");
    try ctx.arrAppendBytes(lite3.root, &[_]u8{ 0x01, 0x02 });

    try testing.expectEqual(@as(u32, 6), try ctx.count(lite3.root));
    try testing.expectEqual(false, try ctx.arrGetBool(lite3.root, 1));
    try testing.expectEqual(@as(i64, 42), try ctx.arrGetI64(lite3.root, 2));
    try testing.expectApproxEqAbs(@as(f64, 1.5), try ctx.arrGetF64(lite3.root, 3), 1e-10);
}

test "Context: array with nested objects" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    const obj = try ctx.arrAppendObj(lite3.root);
    try ctx.setStr(obj, "key", "value");

    const retrieved = try ctx.arrGetObj(lite3.root, 0);
    try testing.expectEqualStrings("value", try ctx.getStr(retrieved, "key"));
}

test "Context: array with nested arrays" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    const inner = try ctx.arrAppendArr(lite3.root);
    try ctx.arrAppendI64(inner, 1);
    try ctx.arrAppendI64(inner, 2);

    const retrieved = try ctx.arrGetArr(lite3.root, 0);
    try testing.expectEqual(@as(i64, 1), try ctx.arrGetI64(retrieved, 0));
    try testing.expectEqual(@as(i64, 2), try ctx.arrGetI64(retrieved, 1));
}

test "Context: iterator" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "a", 10);
    try ctx.setI64(lite3.root, "b", 20);

    var iter = try ctx.iterate(lite3.root);
    var count: u32 = 0;
    while (try iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count);
}

test "Context: JSON encode" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setStr(lite3.root, "msg", "hello");
    try ctx.setI64(lite3.root, "code", 200);

    const json = try ctx.jsonEncode(lite3.root);
    defer std.c.free(@ptrCast(@constCast(json.ptr)));

    try testing.expect(json.len > 0);
    try testing.expect(std.mem.indexOf(u8, json, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, json, "200") != null);
}

test "Context: JSON pretty encode" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "x", 1);

    const json = try ctx.jsonEncodePretty(lite3.root);
    defer std.c.free(@ptrCast(@constCast(json.ptr)));

    try testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}

test "Context: create with size" {
    var ctx = try lite3.Context.createWithSize(65536);
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setStr(lite3.root, "big", "buffer");
    try testing.expectEqualStrings("buffer", try ctx.getStr(lite3.root, "big"));
}

test "Context: create from buffer" {
    // First create a buffer
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "val", 42);

    // Create context from that buffer
    var ctx = try lite3.Context.createFromBuf(buf.data());
    defer ctx.destroy();

    try testing.expectEqual(@as(i64, 42), try ctx.getI64(lite3.root, "val"));
}

test "Context: import from buffer" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    // Create a buffer with data
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "imported", "yes");

    // Import into context
    try ctx.importFromBuf(buf.data());
    try testing.expectEqualStrings("yes", try ctx.getStr(lite3.root, "imported"));
}

// =========================================================================
// Complex / integration tests
// =========================================================================

test "Integration: build complex document and JSON round-trip" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setStr(lite3.root, "event", "http_request");
    try ctx.setStr(lite3.root, "method", "POST");
    try ctx.setI64(lite3.root, "duration_ms", 47);

    const headers = try ctx.setObj(lite3.root, "headers");
    try ctx.setStr(headers, "content-type", "application/json");
    try ctx.setStr(headers, "x-request-id", "req_9f8e2a");
    try ctx.setStr(headers, "user-agent", "curl/8.1.2");

    const tags = try ctx.setArr(lite3.root, "tags");
    try ctx.arrAppendStr(tags, "production");
    try ctx.arrAppendStr(tags, "api");

    // Encode to JSON
    const json = try ctx.jsonEncode(lite3.root);
    defer std.c.free(@ptrCast(@constCast(json.ptr)));

    // Decode back
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.jsonDecode(&mem, json);

    try testing.expectEqual(@as(i64, 47), try buf.getI64(lite3.root, "duration_ms"));
    try testing.expectEqualStrings("POST", try buf.getStr(lite3.root, "method"));

    const h = try buf.getObj(lite3.root, "headers");
    try testing.expectEqualStrings("curl/8.1.2", try buf.getStr(h, "user-agent"));

    const t = try buf.getArr(lite3.root, "tags");
    try testing.expectEqual(@as(u32, 2), try buf.count(t));
}

test "Integration: buffer data can be copied and reused" {
    var mem1: [4096]u8 align(4) = undefined;
    var buf1 = try lite3.Buffer.initObj(&mem1);
    try buf1.setI64(lite3.root, "x", 100);

    // Copy the data to a new buffer
    var mem2: [4096]u8 align(4) = undefined;
    const src = buf1.data();
    @memcpy(mem2[0..src.len], src);

    const buf2 = lite3.Buffer{
        .buf = &mem2,
        .len = src.len,
        .capacity = mem2.len,
    };

    try testing.expectEqual(@as(i64, 100), try buf2.getI64(lite3.root, "x"));
}

test "Integration: array of objects pattern" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    const users = try ctx.setArr(lite3.root, "users");

    const user1 = try ctx.arrAppendObj(users);
    try ctx.setStr(user1, "name", "Alice");
    try ctx.setI64(user1, "age", 30);

    const user2 = try ctx.arrAppendObj(users);
    try ctx.setStr(user2, "name", "Bob");
    try ctx.setI64(user2, "age", 25);

    const user3 = try ctx.arrAppendObj(users);
    try ctx.setStr(user3, "name", "Charlie");
    try ctx.setI64(user3, "age", 35);

    const users_arr = try ctx.getArr(lite3.root, "users");
    try testing.expectEqual(@as(u32, 3), try ctx.count(users_arr));

    // Verify each user
    const names = [_][]const u8{ "Alice", "Bob", "Charlie" };
    const ages = [_]i64{ 30, 25, 35 };

    for (0..3) |i| {
        const user = try ctx.arrGetObj(users_arr, @intCast(i));
        try testing.expectEqualStrings(names[i], try ctx.getStr(user, "name"));
        try testing.expectEqual(ages[i], try ctx.getI64(user, "age"));
    }
}

test "Integration: JSON decode complex document" {
    const json =
        \\{
        \\  "users": [
        \\    {"name": "Alice", "scores": [100, 95, 88]},
        \\    {"name": "Bob", "scores": [90, 85, 92]}
        \\  ],
        \\  "metadata": {
        \\    "total": 2,
        \\    "generated": true
        \\  }
        \\}
    ;

    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.jsonDecode(&mem, json);

    const meta = try buf.getObj(lite3.root, "metadata");
    try testing.expectEqual(@as(i64, 2), try buf.getI64(meta, "total"));
    try testing.expectEqual(true, try buf.getBool(meta, "generated"));

    const users = try buf.getArr(lite3.root, "users");
    try testing.expectEqual(@as(u32, 2), try buf.count(users));

    const alice = try buf.arrGetObj(users, 0);
    try testing.expectEqualStrings("Alice", try buf.getStr(alice, "name"));

    const alice_scores = try buf.getArr(alice, "scores");
    try testing.expectEqual(@as(i64, 100), try buf.arrGetI64(alice_scores, 0));
    try testing.expectEqual(@as(i64, 88), try buf.arrGetI64(alice_scores, 2));
}

test "Integration: f64 special values" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setF64(lite3.root, "zero", 0.0);
    try buf.setF64(lite3.root, "neg_zero", -0.0);
    try buf.setF64(lite3.root, "large", 1.7976931348623157e+308);
    try buf.setF64(lite3.root, "small", 5e-324);

    try testing.expectEqual(@as(f64, 0.0), try buf.getF64(lite3.root, "zero"));
    try testing.expectEqual(@as(f64, 1.7976931348623157e+308), try buf.getF64(lite3.root, "large"));
}

test "Integration: i64 boundary values" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setI64(lite3.root, "max", std.math.maxInt(i64));
    try buf.setI64(lite3.root, "min", std.math.minInt(i64));
    try buf.setI64(lite3.root, "zero", 0);

    try testing.expectEqual(std.math.maxInt(i64), try buf.getI64(lite3.root, "max"));
    try testing.expectEqual(std.math.minInt(i64), try buf.getI64(lite3.root, "min"));
    try testing.expectEqual(@as(i64, 0), try buf.getI64(lite3.root, "zero"));
}

// =========================================================================
// Context API error tests
// =========================================================================

test "Context: error on key not found" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    const result = ctx.getI64(lite3.root, "nonexistent");
    try testing.expectError(lite3.Error.NotFound, result);
}

test "Context: error on type mismatch" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setStr(lite3.root, "text", "hello");
    const result = ctx.getI64(lite3.root, "text");
    try testing.expectError(lite3.Error.InvalidArgument, result);
}

// =========================================================================
// Previously untested methods
// =========================================================================

test "Context: bufPtr returns non-null" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    const ptr = ctx.bufPtr();
    try testing.expect(@intFromPtr(ptr) != 0);
}

test "Context: data returns valid slice" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "x", 42);
    const d = ctx.data();
    try testing.expect(d.len > 0);
}

test "Context: arrGetStr" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    try ctx.arrAppendStr(lite3.root, "alpha");
    try ctx.arrAppendStr(lite3.root, "beta");

    try testing.expectEqualStrings("alpha", try ctx.arrGetStr(lite3.root, 0));
    try testing.expectEqualStrings("beta", try ctx.arrGetStr(lite3.root, 1));
}

test "Context: arrGetBytes" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    try ctx.arrAppendBytes(lite3.root, &[_]u8{ 0xAA, 0xBB });
    try ctx.arrAppendBytes(lite3.root, &[_]u8{ 0xCC, 0xDD });

    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, try ctx.arrGetBytes(lite3.root, 0));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xCC, 0xDD }, try ctx.arrGetBytes(lite3.root, 1));
}

test "Context: jsonDecode" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    const json =
        \\{"name":"alice","age":30}
    ;
    try ctx.jsonDecode(json);

    try testing.expectEqualStrings("alice", try ctx.getStr(lite3.root, "name"));
    try testing.expectEqual(@as(i64, 30), try ctx.getI64(lite3.root, "age"));
}

test "Context: jsonDecode and then modify" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.jsonDecode(
        \\{"x":1}
    );
    try ctx.setI64(lite3.root, "y", 2);

    try testing.expectEqual(@as(i64, 1), try ctx.getI64(lite3.root, "x"));
    try testing.expectEqual(@as(i64, 2), try ctx.getI64(lite3.root, "y"));
}

// =========================================================================
// Edge case tests
// =========================================================================

test "Buffer: unicode string round-trip" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "emoji", "\xF0\x9F\x8E\x89");
    try buf.setStr(lite3.root, "cjk", "\xE4\xB8\xAD\xE6\x96\x87");
    try buf.setStr(lite3.root, "accent", "caf\xC3\xA9");

    try testing.expectEqualStrings("\xF0\x9F\x8E\x89", try buf.getStr(lite3.root, "emoji"));
    try testing.expectEqualStrings("\xE4\xB8\xAD\xE6\x96\x87", try buf.getStr(lite3.root, "cjk"));
    try testing.expectEqualStrings("caf\xC3\xA9", try buf.getStr(lite3.root, "accent"));
}

test "Buffer: empty object count" {
    var mem: [4096]u8 align(4) = undefined;
    const buf = try lite3.Buffer.initObj(&mem);

    try testing.expectEqual(@as(u32, 0), try buf.count(lite3.root));
}

test "Buffer: empty array count" {
    var mem: [4096]u8 align(4) = undefined;
    const buf = try lite3.Buffer.initArr(&mem);

    try testing.expectEqual(@as(u32, 0), try buf.count(lite3.root));
}

test "Context: empty object count" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try testing.expectEqual(@as(u32, 0), try ctx.count(lite3.root));
}

test "Context: empty array count" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initArr();
    try testing.expectEqual(@as(u32, 0), try ctx.count(lite3.root));
}

test "Buffer: freeJson helper" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "x", 1);

    const json = try buf.jsonEncode(lite3.root);
    defer lite3.freeJson(json);

    try testing.expect(json.len > 0);
}

test "Context: freeJson helper" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setI64(lite3.root, "x", 1);

    const json = try ctx.jsonEncode(lite3.root);
    defer lite3.freeJson(json);

    try testing.expect(json.len > 0);
}

// =========================================================================
// Negative tests (malformed JSON, OOB, wrong container type)
// =========================================================================

test "Buffer: jsonDecode with invalid JSON returns error" {
    var mem: [8192]u8 align(4) = undefined;
    const result = lite3.Buffer.jsonDecode(&mem, "{invalid json!!");
    try testing.expectError(lite3.Error.InvalidArgument, result);
}

test "Buffer: jsonDecode with empty string returns error" {
    var mem: [8192]u8 align(4) = undefined;
    const result = lite3.Buffer.jsonDecode(&mem, "");
    try testing.expectError(lite3.Error.InvalidArgument, result);
}

test "Buffer: array OOB index returns error" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    try buf.arrAppendI64(lite3.root, 42);
    // Index 99 is out of bounds (only index 0 exists)
    const result = buf.arrGetI64(lite3.root, 99);
    try testing.expect(std.meta.isError(result));
}

test "Buffer: get from wrong container type" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    // Trying to get by key from an array (should fail)
    const result = buf.getI64(lite3.root, "key");
    try testing.expect(std.meta.isError(result));
}

test "Context: jsonDecode with invalid JSON returns error" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
    const result = ctx.jsonDecode("{not valid json}}}");
    try testing.expect(std.meta.isError(result));
}

test "Buffer: set on wrong container type" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    // Trying to set by key on an array (should fail)
    const result = buf.setI64(lite3.root, "key", 42);
    try testing.expect(std.meta.isError(result));
}

// =========================================================================
// Context.arrGetType test
// =========================================================================

test "Context: arrGetType" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
    try ctx.initArr();
    try ctx.arrAppendI64(lite3.root, 42);
    try ctx.arrAppendStr(lite3.root, "hello");
    try ctx.arrAppendBool(lite3.root, true);
    try testing.expectEqual(lite3.Type.i64_, ctx.arrGetType(lite3.root, 0));
    try testing.expectEqual(lite3.Type.string, ctx.arrGetType(lite3.root, 1));
    try testing.expectEqual(lite3.Type.bool_, ctx.arrGetType(lite3.root, 2));
}

// =========================================================================
// Value tagged union test
// =========================================================================

test "Buffer: getValue returns correct tagged values" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "num", 42);
    try buf.setStr(lite3.root, "text", "hello");
    try buf.setBool(lite3.root, "flag", true);
    try buf.setNull(lite3.root, "nil");

    const num_val = try buf.getValue(lite3.root, "num");
    try testing.expectEqual(@as(i64, 42), num_val.i64_);

    const str_val = try buf.getValue(lite3.root, "text");
    try testing.expectEqualStrings("hello", str_val.string);

    const bool_val = try buf.getValue(lite3.root, "flag");
    try testing.expectEqual(true, bool_val.bool_);

    const null_val = try buf.getValue(lite3.root, "nil");
    try testing.expectEqual(lite3.Value.null, null_val);
}

// =========================================================================
// getStrCopy / getBytesCopy tests
// =========================================================================

test "Buffer: getStrCopy copies into destination" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "name", "alice");

    var dest: [64]u8 = undefined;
    const copied = try buf.getStrCopy(lite3.root, "name", &dest);
    try testing.expectEqualStrings("alice", copied);
}

test "Buffer: getStrCopy with too-small buffer returns error" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "name", "a long string value");

    var dest: [5]u8 = undefined;
    const result = buf.getStrCopy(lite3.root, "name", &dest);
    try testing.expectError(lite3.Error.NoBufferSpace, result);
}

test "Context: getBytesCopy copies into destination" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
    try ctx.initObj();
    try ctx.setBytes(lite3.root, "data", &[_]u8{ 0xDE, 0xAD });

    var dest: [64]u8 = undefined;
    const copied = try ctx.getBytesCopy(lite3.root, "data", &dest);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, copied);
}

// =========================================================================
// Context getType unification test (Error!Type)
// =========================================================================

test "Context: getType returns Error!Type (unified)" {
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
    try ctx.initObj();
    try ctx.setI64(lite3.root, "num", 42);

    // getType now returns Error!Type, not plain Type
    const t = try ctx.getType(lite3.root, "num");
    try testing.expectEqual(lite3.Type.i64_, t);

    // Non-existent key returns NotFound error
    const result = ctx.getType(lite3.root, "missing");
    try testing.expectError(lite3.Error.NotFound, result);
}

// =========================================================================
// Integration: JSON round-trip preserves all types
// =========================================================================

test "Integration: JSON round-trip preserves all types" {
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setNull(lite3.root, "n");
    try buf.setBool(lite3.root, "b", true);
    try buf.setI64(lite3.root, "i", -12345);
    try buf.setF64(lite3.root, "f", 3.14);
    try buf.setStr(lite3.root, "s", "hello");

    const json = try buf.jsonEncode(lite3.root);
    defer lite3.freeJson(json);

    var mem2: [16384]u8 align(4) = undefined;
    var buf2 = try lite3.Buffer.jsonDecode(&mem2, json);

    try testing.expectEqual(lite3.Type.null, try buf2.getType(lite3.root, "n"));
    try testing.expectEqual(true, try buf2.getBool(lite3.root, "b"));
    try testing.expectEqual(@as(i64, -12345), try buf2.getI64(lite3.root, "i"));
    try testing.expectEqualStrings("hello", try buf2.getStr(lite3.root, "s"));
}

// =========================================================================
// Buffer data() consistency test
// =========================================================================

test "Buffer: data returns consistent slice after mutations" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const d1 = buf.data();
    try buf.setI64(lite3.root, "x", 1);
    const d2 = buf.data();
    // After mutation, data length should have grown
    try testing.expect(d2.len > d1.len);
}

// =========================================================================
// Property test: JSON encode-decode idempotency
// =========================================================================

test "Property: JSON encode-decode is idempotent for objects" {
    // Create an object, encode to JSON, decode back, re-encode
    // The two JSON strings should be identical
    var mem1: [16384]u8 align(4) = undefined;
    var buf1 = try lite3.Buffer.initObj(&mem1);
    try buf1.setStr(lite3.root, "key", "value");
    try buf1.setI64(lite3.root, "num", 42);
    try buf1.setBool(lite3.root, "flag", false);

    const json1 = try buf1.jsonEncode(lite3.root);
    defer lite3.freeJson(json1);

    var mem2: [16384]u8 align(4) = undefined;
    var buf2 = try lite3.Buffer.jsonDecode(&mem2, json1);

    const json2 = try buf2.jsonEncode(lite3.root);
    defer lite3.freeJson(json2);

    try testing.expectEqualStrings(json1, json2);
}
