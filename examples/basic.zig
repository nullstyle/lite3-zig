//! Basic usage of lite3-zig
//!
//! Build and run:
//!   zig build-exe examples/basic.zig -Mroot=.zig-cache/...
//!   (or use the lite3 module from build.zig)
//!
//! This example demonstrates creating a document, adding fields,
//! and reading values back.

const std = @import("std");
const lite3 = @import("lite3");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // --- Buffer API: fixed-size, caller-managed memory ---
    try stdout.print("=== Buffer API ===\n", .{});

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
    try stdout.print("name:    {s}\n", .{try buf.getStr(lite3.root, "name")});
    try stdout.print("age:     {d}\n", .{try buf.getI64(lite3.root, "age")});
    try stdout.print("active:  {}\n", .{try buf.getBool(lite3.root, "active")});
    try stdout.print("entries: {d}\n", .{try buf.count(lite3.root)});
    try stdout.print("buffer:  {d} / {d} bytes used\n", .{ buf.len, buf.capacity });

    // --- Context API: auto-growing memory ---
    try stdout.print("\n=== Context API ===\n", .{});

    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    try ctx.initObj();
    try ctx.setStr(lite3.root, "event", "login");
    try ctx.setI64(lite3.root, "timestamp", 1700000000);

    const headers = try ctx.setObj(lite3.root, "headers");
    try ctx.setStr(headers, "content-type", "application/json");

    // Iterate over top-level keys
    try stdout.print("\nTop-level keys:\n", .{});
    var iter = try ctx.iterate(lite3.root);
    while (try iter.next()) |entry| {
        if (entry.key) |k| {
            try stdout.print("  - {s}\n", .{k});
        }
    }

    try stdout.print("\nDone.\n", .{});
}
