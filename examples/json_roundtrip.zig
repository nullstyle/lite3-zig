//! JSON encode/decode round-trip example
//!
//! Demonstrates creating a document, encoding to JSON, decoding back,
//! and verifying the data is preserved.

const std = @import("std");
const lite3 = @import("lite3");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Build a document
    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    try buf.setStr(lite3.root, "event", "http_request");
    try buf.setStr(lite3.root, "method", "POST");
    try buf.setI64(lite3.root, "status", 200);
    try buf.setI64(lite3.root, "duration_ms", 47);

    const headers = try buf.setObj(lite3.root, "headers");
    try buf.setStr(headers, "content-type", "application/json");
    try buf.setStr(headers, "x-request-id", "req_abc123");

    const tags = try buf.setArr(lite3.root, "tags");
    try buf.arrAppendStr(tags, "production");
    try buf.arrAppendStr(tags, "api");
    try buf.arrAppendStr(tags, "fast");

    // Encode to JSON
    const json = try buf.jsonEncode(lite3.root);
    defer lite3.freeJson(json);

    try stdout.print("Compact JSON:\n{s}\n\n", .{json});

    // Pretty-print
    const pretty = try buf.jsonEncodePretty(lite3.root);
    defer lite3.freeJson(pretty);

    try stdout.print("Pretty JSON:\n{s}\n\n", .{pretty});

    // Decode back into a new buffer
    var mem2: [16384]u8 align(4) = undefined;
    var buf2 = try lite3.Buffer.jsonDecode(&mem2, json);

    // Verify round-trip
    try stdout.print("Round-trip verification:\n", .{});
    try stdout.print("  event:       {s}\n", .{try buf2.getStr(lite3.root, "event")});
    try stdout.print("  method:      {s}\n", .{try buf2.getStr(lite3.root, "method")});
    try stdout.print("  status:      {d}\n", .{try buf2.getI64(lite3.root, "status")});
    try stdout.print("  duration_ms: {d}\n", .{try buf2.getI64(lite3.root, "duration_ms")});

    const h = try buf2.getObj(lite3.root, "headers");
    try stdout.print("  content-type: {s}\n", .{try buf2.getStr(h, "content-type")});

    // Encode the decoded buffer to verify identical JSON
    const json2 = try buf2.jsonEncode(lite3.root);
    defer lite3.freeJson(json2);

    if (std.mem.eql(u8, json, json2)) {
        try stdout.print("\nJSON round-trip: PASSED (identical output)\n", .{});
    } else {
        try stdout.print("\nJSON round-trip: DIFFERENT\n  original: {s}\n  decoded:  {s}\n", .{ json, json2 });
    }

    // Context API JSON decode
    try stdout.print("\n=== Context API JSON decode ===\n", .{});
    var ctx = try lite3.Context.create();
    defer ctx.destroy();

    const input_json =
        \\{"users":[{"name":"Alice","age":30},{"name":"Bob","age":25}],"count":2}
    ;
    try ctx.jsonDecode(input_json);

    try stdout.print("count: {d}\n", .{try ctx.getI64(lite3.root, "count")});

    const users = try ctx.getArr(lite3.root, "users");
    const user_count = try ctx.count(users);
    try stdout.print("users: {d}\n", .{user_count});

    for (0..user_count) |i| {
        const user = try ctx.arrGetObj(users, @intCast(i));
        try stdout.print("  [{d}] {s}, age {d}\n", .{
            i,
            try ctx.getStr(user, "name"),
            try ctx.getI64(user, "age"),
        });
    }
}
