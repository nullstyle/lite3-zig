//! Basic usage of lite3-zig
//!
//! Build with: zig build examples
//!
//! This example demonstrates creating a document, adding fields,
//! and reading values back.

const std = @import("std");
const lite3 = @import("lite3");

pub fn main() !void {
    var write_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&write_buf);
    defer stdout.interface.flush() catch {};

    // --- Buffer API: fixed-size, caller-managed memory ---
    try stdout.interface.print("=== Buffer API ===\n", .{});

    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "name", "Alice");
    try buf.setI64(lite3.root, "age", 30);
    try buf.setBool(lite3.root, "active", true);
    try buf.setF64(lite3.root, "score", 99.5);

    // Nested object
    const address = try buf.setObj(lite3.root, "address");
    try buf.setStr(address, "city", "Wonderland");
    try buf.setI64(address, "zip", 12345);

    // Nested array
    const tags = try buf.setArr(lite3.root, "tags");
    try buf.arrAppendStr(tags, "admin");
    try buf.arrAppendStr(tags, "user");

    // Read values back
    try stdout.interface.print("name:    {s}\n", .{try buf.getStr(lite3.root, "name")});
    try stdout.interface.print("age:     {d}\n", .{try buf.getI64(lite3.root, "age")});
    try stdout.interface.print("active:  {}\n", .{try buf.getBool(lite3.root, "active")});
    try stdout.interface.print("entries: {d}\n", .{try buf.count(lite3.root)});
    try stdout.interface.print("buffer:  {d} / {d} bytes used\n", .{ buf.len, buf.capacity });

    // --- Context API: auto-growing memory ---
    try stdout.interface.print("\n=== Context API ===\n", .{});

    var ctx = try lite3.Context.init();
    defer ctx.deinit();

    try ctx.resetObj();
    try ctx.setStr(lite3.root, "event", "login");
    try ctx.setI64(lite3.root, "timestamp", 1700000000);

    const headers = try ctx.setObj(lite3.root, "headers");
    try ctx.setStr(headers, "content-type", "application/json");

    // Read context values back
    try stdout.interface.print("event:     {s}\n", .{try ctx.getStr(lite3.root, "event")});
    try stdout.interface.print("timestamp: {d}\n", .{try ctx.getI64(lite3.root, "timestamp")});
    try stdout.interface.print("entries:   {d}\n", .{try ctx.count(lite3.root)});

    // Safe copy: survives even after context mutations
    var name_buf: [64]u8 = undefined;
    const name_copy = try ctx.getStrCopy(lite3.root, "event", &name_buf);
    try stdout.interface.print("safe copy: {s}\n", .{name_copy});

    try stdout.interface.print("\nDone.\n", .{});
}
