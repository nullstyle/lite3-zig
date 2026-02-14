//! Benchmark suite for lite3-zig
//!
//! Run with: zig build bench
//! Results show min/median/max nanoseconds per operation across multiple trials.

const std = @import("std");
const lite3 = @import("lite3");

const Timer = std.time.Timer;

const NUM_TRIALS = 5;

fn formatRate(count: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
}

fn nsPerOp(count: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(count));
}

fn printStats(name: []const u8, count: u64, times: *[NUM_TRIALS]u64) void {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const min = times[0];
    const median = times[NUM_TRIALS / 2];
    const max = times[NUM_TRIALS - 1];
    std.debug.print("  {s:<14} {d:>12.0} ops/sec  (min {d:.1} ns/op, med {d:.1}, max {d:.1})\n", .{
        name,
        formatRate(count, median),
        nsPerOp(count, min),
        nsPerOp(count, median),
        nsPerOp(count, max),
    });
}

fn benchSetGetI64() !void {
    const iterations: u64 = 100_000;

    // --- set_i64 ---
    var set_times: [NUM_TRIALS]u64 = undefined;
    {
        // warmup
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        try buf.setI64(lite3.root, "key", 42);
    }
    for (&set_times) |*t| {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        var timer = try Timer.start();
        for (0..iterations) |_| {
            try buf.setI64(lite3.root, "key", 42);
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&buf);
    }
    printStats("set_i64:", iterations, &set_times);

    // --- get_i64 ---
    var get_times: [NUM_TRIALS]u64 = undefined;
    for (&get_times) |*t| {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        try buf.setI64(lite3.root, "key", 42);
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const val = try buf.getI64(lite3.root, "key");
            std.mem.doNotOptimizeAway(&val);
        }
        t.* = timer.read();
    }
    printStats("get_i64:", iterations, &get_times);
}

fn benchSetGetStr() !void {
    const iterations: u64 = 100_000;

    // --- set_str ---
    var set_times: [NUM_TRIALS]u64 = undefined;
    {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        try buf.setStr(lite3.root, "key", "hello world benchmark string");
        std.mem.doNotOptimizeAway(&buf);
    }
    for (&set_times) |*t| {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        var timer = try Timer.start();
        for (0..iterations) |_| {
            try buf.setStr(lite3.root, "key", "hello world benchmark string");
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&buf);
    }
    printStats("set_str:", iterations, &set_times);

    // --- get_str ---
    var get_times: [NUM_TRIALS]u64 = undefined;
    for (&get_times) |*t| {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        try buf.setStr(lite3.root, "key", "hello world benchmark string");
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const val = try buf.getStr(lite3.root, "key");
            std.mem.doNotOptimizeAway(&val);
        }
        t.* = timer.read();
    }
    printStats("get_str:", iterations, &get_times);
}

fn benchArrayAppend() !void {
    const iterations: u64 = 50_000;

    var times: [NUM_TRIALS]u64 = undefined;
    {
        // warmup
        var mem: [4194304]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initArr(&mem);
        for (0..iterations) |i| {
            try buf.arrAppendI64(lite3.root, @intCast(i));
        }
        std.mem.doNotOptimizeAway(&buf);
    }
    for (&times) |*t| {
        var mem: [4194304]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initArr(&mem);
        var timer = try Timer.start();
        for (0..iterations) |i| {
            try buf.arrAppendI64(lite3.root, @intCast(i));
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&buf);
    }
    printStats("arr_append:", iterations, &times);
}

fn benchIterate() !void {
    var mem: [4194304]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);

    const n: u64 = 10_000;
    for (0..n) |i| {
        try buf.arrAppendI64(lite3.root, @intCast(i));
    }

    const iterations: u64 = 100;
    var times: [NUM_TRIALS]u64 = undefined;
    {
        // warmup
        var iter = try buf.iterate(lite3.root);
        var sink: usize = 0;
        while (try iter.next()) |entry| {
            sink +%= @intFromEnum(entry.val_offset);
        }
        std.mem.doNotOptimizeAway(&sink);
    }
    for (&times) |*t| {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            var iter = try buf.iterate(lite3.root);
            var sink: usize = 0;
            while (try iter.next()) |entry| {
                sink +%= @intFromEnum(entry.val_offset);
            }
            std.mem.doNotOptimizeAway(&sink);
        }
        t.* = timer.read();
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[NUM_TRIALS / 2];
    std.debug.print("  {s:<14} {d:>12.0} iters/sec ({d} elements)  (min {d:.1} ns/op, med {d:.1}, max {d:.1})\n", .{
        "iterate:",
        formatRate(iterations, median),
        n,
        nsPerOp(iterations, times[0]),
        nsPerOp(iterations, median),
        nsPerOp(iterations, times[NUM_TRIALS - 1]),
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

    // --- json_enc ---
    var enc_times: [NUM_TRIALS]u64 = undefined;
    {
        // warmup
        const j = try buf.jsonEncode(lite3.root);
        j.deinit();
    }
    for (&enc_times) |*t| {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const json = try buf.jsonEncode(lite3.root);
            std.mem.doNotOptimizeAway(&json);
            json.deinit();
        }
        t.* = timer.read();
    }
    printStats("json_enc:", iterations, &enc_times);

    // Get a JSON string for decode benchmark
    const json = try buf.jsonEncode(lite3.root);
    defer json.deinit();

    // --- json_dec ---
    var dec_times: [NUM_TRIALS]u64 = undefined;
    {
        // warmup
        var mem2: [65536]u8 align(4) = undefined;
        const b = try lite3.Buffer.jsonDecode(&mem2, json.slice());
        std.mem.doNotOptimizeAway(&b);
    }
    for (&dec_times) |*t| {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            var mem2: [65536]u8 align(4) = undefined;
            const b = try lite3.Buffer.jsonDecode(&mem2, json.slice());
            std.mem.doNotOptimizeAway(&b);
        }
        t.* = timer.read();
    }
    printStats("json_dec:", iterations, &dec_times);
}

fn benchContextVsBuffer() !void {
    const iterations: u64 = 100_000;

    // --- Buffer ---
    var buf_times: [NUM_TRIALS]u64 = undefined;
    {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        try buf.setI64(lite3.root, "k", 1);
        std.mem.doNotOptimizeAway(&buf);
    }
    for (&buf_times) |*t| {
        var mem: [65536]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(&mem);
        var timer = try Timer.start();
        for (0..iterations) |_| {
            try buf.setI64(lite3.root, "k", 1);
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&buf);
    }
    printStats("buffer_set:", iterations, &buf_times);

    // --- Context ---
    var ctx_times: [NUM_TRIALS]u64 = undefined;
    {
        var ctx = try lite3.Context.init();
        try ctx.resetObj();
        try ctx.setI64(lite3.root, "k", 1);
        std.mem.doNotOptimizeAway(&ctx);
        ctx.deinit();
    }
    for (&ctx_times) |*t| {
        var ctx = try lite3.Context.init();
        try ctx.resetObj();
        var timer = try Timer.start();
        for (0..iterations) |_| {
            try ctx.setI64(lite3.root, "k", 1);
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&ctx);
        ctx.deinit();
    }
    printStats("ctx_set:", iterations, &ctx_times);

    std.mem.sort(u64, &buf_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, &ctx_times, {}, std.sort.asc(u64));
    const buf_med = buf_times[NUM_TRIALS / 2];
    const ctx_med = ctx_times[NUM_TRIALS / 2];
    std.debug.print("  overhead:     {d:.1}%\n", .{
        (@as(f64, @floatFromInt(ctx_med)) / @as(f64, @floatFromInt(buf_med)) - 1.0) * 100.0,
    });
}

pub fn main() !void {
    std.debug.print("\nlite3-zig benchmarks ({d} trials each)\n", .{NUM_TRIALS});
    std.debug.print("=========================================\n\n", .{});

    std.debug.print("Set/Get:\n", .{});
    try benchSetGetI64();
    try benchSetGetStr();

    std.debug.print("\nArray:\n", .{});
    try benchArrayAppend();

    std.debug.print("\nIteration:\n", .{});
    try benchIterate();

    std.debug.print("\nJSON:\n", .{});
    if (lite3.json_enabled) {
        try benchJsonRoundTrip();
    } else {
        std.debug.print("  disabled (-Djson=false)\n", .{});
    }

    std.debug.print("\nBuffer vs Context:\n", .{});
    try benchContextVsBuffer();

    std.debug.print("\nDone.\n", .{});
}
