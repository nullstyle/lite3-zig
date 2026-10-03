const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test {
    _ = @import("api_tests.zig");
}

test "smoke: compile every declaration" {
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
