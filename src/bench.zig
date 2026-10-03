//! Benchmarks for lite3-zig.
//!
//! Run with: zig build bench
//!
//! Each benchmark runs the same loop through the Zig API and directly
//! against lite3's C API (src/bench_raw.c) and reports the median time per
//! operation of several trials, and the wrapper's overhead.

const std = @import("std");
const lite3 = @import("lite3");
const root = lite3.root;

extern fn raw_set_i64(buf: [*]u8, bufsz: usize, n: u64) i64;
extern fn raw_get_i64(buf: [*]const u8, len: usize, n: u64) i64;
extern fn raw_set_str(buf: [*]u8, bufsz: usize, n: u64) i64;
extern fn raw_get_str(buf: [*]const u8, len: usize, n: u64) i64;
extern fn raw_append_i64(buf: [*]u8, bufsz: usize, n: u64) i64;
extern fn raw_iterate(buf: [*]const u8, len: usize) i64;

/// Process I/O handle, set once in `main`. Needed for clock access.
var io: std.Io = undefined;
/// The process's general-purpose allocator, set once in `main`.
var gpa: std.mem.Allocator = undefined;

const trials = 7;
const str_value = "hello world benchmark string";

var big_mem: [4 << 20]u8 align(4) = undefined;
var small_mem: [65536]u8 align(4) = undefined;

fn now() std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

/// Median nanoseconds per operation of `trials` runs of `body(n)`.
fn measure(n: usize, comptime body: fn (usize) anyerror!void) !f64 {
    try body(n); // warm up
    var times: [trials]u64 = undefined;
    for (&times) |*t| {
        const start = now();
        try body(n);
        t.* = @intCast(@max(start.durationTo(now()).nanoseconds, 0));
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    return @as(f64, @floatFromInt(times[trials / 2])) / @as(f64, @floatFromInt(n));
}

fn report(name: []const u8, zig_ns: f64, raw_ns: ?f64) void {
    if (raw_ns) |raw| {
        std.debug.print("  {s:<26} {d:>8.1} ns/op   C {d:>8.1} ns/op   overhead {d:>6.1}%\n", .{ name, zig_ns, raw, (zig_ns / raw - 1.0) * 100.0 });
    } else {
        std.debug.print("  {s:<26} {d:>8.1} ns/op\n", .{ name, zig_ns });
    }
}

fn check(ret: i64) !void {
    if (ret < 0) return error.RawBenchmarkFailed;
}

// --- Bodies ---

fn zigSetI64Plain(n: usize) !void {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    for (0..n) |_| try buf.set(root, "key", 42);
    std.mem.doNotOptimizeAway(&buf);
}

fn zigSetI64Key(n: usize) !void {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    for (0..n) |_| try buf.set(root, lite3.key("key"), 42);
    std.mem.doNotOptimizeAway(&buf);
}

fn rawSetI64(n: usize) !void {
    try check(raw_set_i64(&small_mem, small_mem.len, n));
}

fn prepI64() !lite3.Buffer {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    try buf.set(root, "key", 42);
    return buf;
}

fn zigGetI64Plain(n: usize) !void {
    const buf = try prepI64();
    const v = buf.view();
    var sum: i64 = 0;
    for (0..n) |_| sum +%= try v.get(i64, root, "key");
    std.mem.doNotOptimizeAway(sum);
}

fn zigGetI64Key(n: usize) !void {
    const buf = try prepI64();
    const v = buf.view();
    var sum: i64 = 0;
    for (0..n) |_| sum +%= try v.get(i64, root, lite3.key("key"));
    std.mem.doNotOptimizeAway(sum);
}

fn rawGetI64(n: usize) !void {
    const buf = try prepI64();
    try check(raw_get_i64(buf.slice().ptr, buf.slice().len, n));
}

fn zigSetStr(n: usize) !void {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    for (0..n) |_| try buf.set(root, lite3.key("key"), str_value);
    std.mem.doNotOptimizeAway(&buf);
}

fn rawSetStr(n: usize) !void {
    try check(raw_set_str(&small_mem, small_mem.len, n));
}

fn prepStr() !lite3.Buffer {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    try buf.set(root, "key", str_value);
    return buf;
}

fn zigGetStr(n: usize) !void {
    const buf = try prepStr();
    const v = buf.view();
    var sum: usize = 0;
    for (0..n) |_| sum +%= (try v.get([]const u8, root, lite3.key("key"))).len;
    std.mem.doNotOptimizeAway(sum);
}

fn rawGetStr(n: usize) !void {
    const buf = try prepStr();
    try check(raw_get_str(buf.slice().ptr, buf.slice().len, n));
}

fn zigAppend(n: usize) !void {
    var buf = try lite3.Buffer.init(&big_mem, .array);
    for (0..n) |i| try buf.append(root, i);
    std.mem.doNotOptimizeAway(&buf);
}

fn rawAppend(n: usize) !void {
    try check(raw_append_i64(&big_mem, big_mem.len, n));
}

const iterate_len = 10_000;

fn prepIterate() !lite3.Buffer {
    var buf = try lite3.Buffer.init(&big_mem, .array);
    for (0..iterate_len) |i| try buf.append(root, i);
    return buf;
}

/// `n` counts elements visited, so results are per element.
fn zigIterate(n: usize) !void {
    const buf = try prepIterate();
    const v = buf.view();
    for (0..n / iterate_len) |_| {
        var it = try v.arrayIterator(root);
        var sum: i64 = 0;
        while (try it.next()) |e| sum +%= e.value.int;
        std.mem.doNotOptimizeAway(sum);
    }
}

fn rawIterate(n: usize) !void {
    const buf = try prepIterate();
    for (0..n / iterate_len) |_| try check(raw_iterate(buf.slice().ptr, buf.slice().len));
}

fn zigDocumentSet(n: usize) !void {
    var doc = try lite3.Document.init(gpa, .object);
    defer doc.deinit(gpa);
    for (0..n) |_| try doc.set(gpa, root, lite3.key("key"), 42);
}

fn prepJson() !lite3.Buffer {
    var buf = try lite3.Buffer.init(&small_mem, .object);
    try buf.set(root, "name", "benchmark");
    try buf.set(root, "value", 42);
    try buf.set(root, "active", true);
    try buf.set(root, "score", 99.5);
    const arr = try buf.setArray(root, "items");
    for (0..10) |i| try buf.append(arr, i);
    return buf;
}

fn zigJsonEncode(n: usize) !void {
    const buf = try prepJson();
    var out: [4096]u8 = undefined;
    for (0..n) |_| {
        var w: std.Io.Writer = .fixed(&out);
        try buf.view().writeJson(root, &w, .{});
        std.mem.doNotOptimizeAway(w.end);
    }
}

var json_input: []const u8 = "";

fn zigJsonDecode(n: usize) !void {
    var mem: [65536]u8 align(4) = undefined;
    for (0..n) |_| {
        const buf = try lite3.Buffer.fromJson(gpa, &mem, json_input, null);
        std.mem.doNotOptimizeAway(buf.len);
    }
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    std.debug.print("\nlite3-zig benchmarks (median of {d} trials)\n\n", .{trials});

    const n = 200_000;
    std.debug.print("Objects:\n", .{});
    const raw_set = try measure(n, rawSetI64);
    report("set i64 (string key)", try measure(n, zigSetI64Plain), raw_set);
    report("set i64 (lite3.key)", try measure(n, zigSetI64Key), raw_set);
    const raw_get = try measure(n, rawGetI64);
    report("get i64 (string key)", try measure(n, zigGetI64Plain), raw_get);
    report("get i64 (lite3.key)", try measure(n, zigGetI64Key), raw_get);
    report("set string", try measure(n, zigSetStr), try measure(n, rawSetStr));
    report("get string", try measure(n, zigGetStr), try measure(n, rawGetStr));
    report("Document set i64", try measure(n, zigDocumentSet), raw_set);

    std.debug.print("\nArrays:\n", .{});
    report("append i64", try measure(50_000, zigAppend), try measure(50_000, rawAppend));
    report("iterate (per element)", try measure(iterate_len * 100, zigIterate), try measure(iterate_len * 100, rawIterate));

    std.debug.print("\nJSON:\n", .{});
    report("encode (16 values)", try measure(50_000, zigJsonEncode), null);
    if (lite3.json_enabled) {
        const buf = try prepJson();
        var out: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try buf.view().writeJson(root, &w, .{});
        json_input = w.buffered();
        report("decode (16 values)", try measure(50_000, zigJsonDecode), null);
    } else {
        std.debug.print("  decode disabled (-Djson=false)\n", .{});
    }
    std.debug.print("\n", .{});
}
