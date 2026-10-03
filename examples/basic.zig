//! Basic usage of lite3-zig.
//!
//! Build with: zig build examples
//!
//! Creates documents in fixed memory (Buffer) and in growable memory
//! (Document), writes fields, and reads them back through a View.

const std = @import("std");
const lite3 = @import("lite3");
const root = lite3.root;

pub fn main(init: std.process.Init) !void {
    var write_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &write_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // --- Buffer: fixed-size, caller-owned memory ---
    try out.print("=== Buffer ===\n", .{});

    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);

    // `set` takes any scalar: integers, floats, bools, strings, null, and
    // lite3.bytes(...) for binary data.
    try buf.set(root, "name", "Alice");
    try buf.set(root, "age", 30);
    try buf.set(root, "active", true);
    try buf.set(root, "score", 99.5);
    try buf.set(root, "avatar", lite3.bytes(&.{ 0x89, 0x50, 0x4e, 0x47 }));

    const address = try buf.setObject(root, "address");
    try buf.set(address, "city", "Wonderland");
    try buf.set(address, "zip", 12345);

    const tags = try buf.setArray(root, "tags");
    try buf.append(tags, "admin");
    try buf.append(tags, "user");

    // Reads go through a View. A View taken before a write returns
    // error.StaleView afterwards, so take a fresh one after writing.
    const v = buf.view();
    try out.print("name:    {s}\n", .{try v.get([]const u8, root, "name")});
    try out.print("age:     {d}\n", .{try v.get(i64, root, "age")});
    try out.print("active:  {}\n", .{try v.get(bool, root, "active")});
    try out.print("city:    {s}\n", .{try v.get([]const u8, try v.getObject(root, "address"), "city")});
    try out.print("entries: {d}\n", .{try v.count(root)});
    try out.print("used:    {d} of {d} bytes\n", .{ buf.slice().len, buf.capacity() });

    // Keys known at compile time can be hashed at compile time.
    const name_key = lite3.key("name");
    try out.print("has name: {}\n", .{try v.has(root, name_key)});

    // Iteration.
    var it = try v.arrayIterator(tags);
    while (try it.next()) |e| try out.print("tag[{d}]: {s}\n", .{ e.index, e.value.string });

    // JSON encoding needs no allocation.
    try out.print("json:    {f}\n", .{v});

    // --- Document: growable memory ---
    try out.print("\n=== Document ===\n", .{});

    const gpa = std.heap.smp_allocator;
    var doc = try lite3.Document.init(gpa, .object);
    defer doc.deinit(gpa);

    try doc.set(gpa, root, "event", "login");
    try doc.set(gpa, root, "timestamp", 1700000000);
    const headers = try doc.setObject(gpa, root, "headers");
    try doc.set(gpa, headers, "content-type", "application/json");

    var obj_it = try doc.view().objectIterator(root);
    while (try obj_it.next()) |e| try out.print("{s}: {s}\n", .{ e.key, @tagName(e.value) });

    // The serialized bytes can be sent or stored as they are, and read back
    // with View.fromBytes (which validates them first).
    const copy = try gpa.dupe(u8, doc.slice());
    defer gpa.free(copy);
    const received = try lite3.View.fromBytes(copy);
    try out.print("event from copy: {s}\n", .{try received.get([]const u8, root, "event")});
}
