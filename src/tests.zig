const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test {
    _ = @import("api_tests.zig");
    _ = @import("validate_tests.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("regression_tests.zig");
    _ = @import("property_tests.zig");
}

test "smoke: compile every declaration" {
    // The JSON decoders are compile errors in a -Djson=false build.
    if (!lite3.json_enabled) return error.SkipZigTest;
    testing.refAllDecls(lite3);
    testing.refAllDecls(lite3.View);
    testing.refAllDecls(lite3.Buffer);
    testing.refAllDecls(lite3.Document);
    testing.refAllDecls(lite3.ManagedDocument);
}

test "smoke: buffer round trip" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(lite3.root, "name", "Alice");
    try buf.set(lite3.root, "age", 30);
    try buf.set(lite3.root, lite3.key("ok"), true);
    const v = buf.view();
    try testing.expectEqualStrings("Alice", try v.get([]const u8, lite3.root, "name"));
    try testing.expectEqual(@as(i64, 30), try v.get(i64, lite3.root, "age"));
    try testing.expect(try v.get(bool, lite3.root, "ok"));
    try lite3.validate(buf.slice());
}

test "README quick start compiles and runs" {
    const root = lite3.root;
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(root, "name", "Alice");
    try buf.set(root, "age", 30);
    const tags = try buf.setArray(root, "tags");
    try buf.append(tags, "admin");

    const v = buf.view();
    const name = try v.get([]const u8, root, "name");
    const age = try v.get(u8, root, lite3.key("age"));
    try testing.expectEqualStrings("Alice", name);
    try testing.expectEqual(@as(u8, 30), age);

    const gpa = testing.allocator;
    var doc = try lite3.Document.init(gpa, .object);
    defer doc.deinit(gpa);
    try doc.set(gpa, root, "event", "login");
    const received = try lite3.View.fromBytes(doc.slice());
    try testing.expectEqualStrings("login", try received.get([]const u8, root, "event"));

    if (!lite3.json_enabled) return;
    var parsed = try lite3.Document.fromJson(gpa, "{\"a\":[1,2,3]}", .{});
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), try parsed.view().count(try parsed.view().getArray(root, "a")));
}
