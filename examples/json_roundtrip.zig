//! JSON round trip.
//!
//! Build with: zig build examples
//!
//! Encodes a document as JSON, decodes it back, and checks that the result
//! encodes identically. Encoding is always available; decoding needs the
//! default -Djson=true.

const std = @import("std");
const lite3 = @import("lite3");
const root = lite3.root;

pub fn main(init: std.process.Init) !void {
    var write_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &write_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const gpa = init.gpa;

    var mem: [16384]u8 align(4) = undefined;
    var buf = try lite3.Buffer.init(&mem, .object);
    try buf.set(root, "event", "http_request");
    try buf.set(root, "method", "POST");
    try buf.set(root, "status", 200);
    try buf.set(root, "duration_ms", 47.25);
    const headers = try buf.setObject(root, "headers");
    try buf.set(headers, "content-type", "application/json");
    try buf.set(headers, "x-request-id", "req_abc123");
    const tags = try buf.setArray(root, "tags");
    for ([_][]const u8{ "production", "api", "fast" }) |t| try buf.append(tags, t);

    const json = try buf.view().jsonAlloc(gpa, root, .{});
    defer gpa.free(json);
    try out.print("Compact JSON:\n{s}\n\n", .{json});

    try out.print("Pretty JSON:\n", .{});
    try buf.view().writeJson(root, out, .{ .whitespace = .indent_2 });
    try out.print("\n\n", .{});

    if (!lite3.json_enabled) {
        try out.print("JSON decoding is disabled in this build (-Djson=false).\n", .{});
        return;
    }

    // Decode into a growable Document.
    var doc = try lite3.Document.fromJson(gpa, json, .{});
    defer doc.deinit(gpa);
    const v = doc.view();
    const status = try v.get(i64, root, "status");
    try out.print("status:       {d}\n", .{status});
    try check(status == 200);
    try out.print("content-type: {s}\n", .{try v.get([]const u8, try v.getObject(root, "headers"), "content-type")});

    const json2 = try v.jsonAlloc(gpa, root, .{});
    defer gpa.free(json2);
    try out.print("round trip:   {s}\n", .{if (std.mem.eql(u8, json, json2)) "identical" else "DIFFERENT"});
    try check(std.mem.eql(u8, json, json2));

    // Invalid input reports where parsing stopped.
    var diag: lite3.JsonDiagnostics = .{};
    if (lite3.Document.fromJson(gpa, "{\"a\": [1, 2,]}", .{ .diagnostics = &diag })) |bad| {
        var d = bad;
        d.deinit(gpa);
        return error.UnexpectedResult;
    } else |err| {
        try out.print("\ninvalid JSON: {s} at byte {d}: {s}\n", .{ @errorName(err), diag.position, diag.message });
        try check(err == error.SyntaxError and diag.position == 11);
    }
}

/// Examples double as smoke tests: `zig build run-examples` fails if one
/// prints something unexpected.
fn check(ok: bool) !void {
    if (!ok) return error.UnexpectedResult;
}
