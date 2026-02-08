//! Benchmark suite for lite3-zig
//!
//! Run with: zig build bench
//! Results show operations per second for common operations.

const std = @import("std");
const lite3 = @import("lite3");

const Timer = std.time.Timer;

fn formatRate(count: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
}

fn benchSetGetI64() !void {
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const iterations: u64 = 100_000;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        try buf.setI64(lite3.root, "key", 42);
    }
    const set_elapsed = timer.read();

    timer = try Timer.start();
    for (0..iterations) |_| {
        _ = try buf.getI64(lite3.root, "key");
    }
    const get_elapsed = timer.read();

    std.debug.print("  set_i64:    {d:>12.0} ops/sec\n", .{formatRate(iterations, set_elapsed)});
    std.debug.print("  get_i64:    {d:>12.0} ops/sec\n", .{formatRate(iterations, get_elapsed)});
}

fn benchSetGetStr() !void {
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);

    const iterations: u64 = 100_000;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        try buf.setStr(lite3.root, "key", "hello world benchmark string");
    }
    const set_elapsed = timer.read();

    timer = try Timer.start();
    for (0..iterations) |_| {
        _ = try buf.getStr(lite3.root, "key");
    }
    const get_elapsed = timer.read();

    std.debug.print("  set_str:    {d:>12.0} ops/sec\n", .{formatRate(iterations, set_elapsed)});
    std.debug.print("  get_str:    {d:>12.0} ops/sec\n", .{formatRate(iterations, get_elapsed)});
}

fn benchArrayAppend() !void {
    var mem: [4194304]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const iterations: u64 = 50_000;
    var timer = try Timer.start();

    for (0..iterations) |i| {
        try buf.arrAppendI64(lite3.root, @intCast(i));
    }
    const elapsed = timer.read();

    std.debug.print("  arr_append: {d:>12.0} ops/sec\n", .{formatRate(iterations, elapsed)});
}

fn benchIterate() !void {
    var mem: [4194304]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const n: u64 = 10_000;
    for (0..n) |i| {
        try buf.arrAppendI64(lite3.root, @intCast(i));
    }

    const iterations: u64 = 100;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        var iter = try buf.iterate(lite3.root);
        while (try iter.next()) |_| {}
    }
    const elapsed = timer.read();

    std.debug.print("  iterate({d}): {d:>10.0} iters/sec ({d} elements each)\n", .{
        n, formatRate(iterations, elapsed), n,
    });
}

fn benchJsonRoundTrip() !void {
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "name", "benchmark");
    try buf.setI64(lite3.root, "value", 42);
    try buf.setBool(lite3.root, "active", true);
    try buf.setF64(lite3.root, "score", 99.5);

    const iterations: u64 = 50_000;

    // Encode benchmark
    var timer = try Timer.start();
    for (0..iterations) |_| {
        const json = try buf.jsonEncode(lite3.root);
        lite3.freeJson(json);
    }
    const enc_elapsed = timer.read();

    // Get a JSON string for decode benchmark
    const json = try buf.jsonEncode(lite3.root);
    defer lite3.freeJson(json);

    // Decode benchmark
    timer = try Timer.start();
    for (0..iterations) |_| {
        var mem2: [65536]u8 align(4) = undefined;
        _ = try lite3.Buffer.jsonDecode(&mem2, json);
    }
    const dec_elapsed = timer.read();

    std.debug.print("  json_enc:   {d:>12.0} ops/sec\n", .{formatRate(iterations, enc_elapsed)});
    std.debug.print("  json_dec:   {d:>12.0} ops/sec\n", .{formatRate(iterations, dec_elapsed)});
}

fn benchContextVsBuffer() !void {
    const iterations: u64 = 100_000;

    // Buffer
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    var timer = try Timer.start();
    for (0..iterations) |_| {
        try buf.setI64(lite3.root, "k", 1);
    }
    const buf_elapsed = timer.read();

    // Context
    var ctx = try lite3.Context.create();
    defer ctx.destroy();
    try ctx.initObj();
    timer = try Timer.start();
    for (0..iterations) |_| {
        try ctx.setI64(lite3.root, "k", 1);
    }
    const ctx_elapsed = timer.read();

    std.debug.print("  buffer_set: {d:>12.0} ops/sec\n", .{formatRate(iterations, buf_elapsed)});
    std.debug.print("  ctx_set:    {d:>12.0} ops/sec\n", .{formatRate(iterations, ctx_elapsed)});
    std.debug.print("  overhead:   {d:.1}%\n", .{
        (@as(f64, @floatFromInt(ctx_elapsed)) / @as(f64, @floatFromInt(buf_elapsed)) - 1.0) * 100.0,
    });
}

pub fn main() !void {
    std.debug.print("\nlite3-zig benchmarks\n", .{});
    std.debug.print("====================\n\n", .{});

    std.debug.print("Set/Get:\n", .{});
    try benchSetGetI64();
    try benchSetGetStr();

    std.debug.print("\nArray:\n", .{});
    try benchArrayAppend();

    std.debug.print("\nIteration:\n", .{});
    try benchIterate();

    std.debug.print("\nJSON:\n", .{});
    try benchJsonRoundTrip();

    std.debug.print("\nBuffer vs Context:\n", .{});
    try benchContextVsBuffer();

    std.debug.print("\nDone.\n", .{});
}
