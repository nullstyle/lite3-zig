// Helpers shared by the test files.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

/// Read every value reachable from `ofs` through the public API.
pub fn readAll(buf: *const lite3.Buffer, ofs: lite3.Offset, depth: usize) !void {
    if (depth > lite3.max_nesting_depth) return error.TooDeep;
    var it = try buf.iterate(ofs);
    var index: u32 = 0;
    while (try it.next()) |e| : (index += 1) {
        // Keys longer than max_key_len are only reachable through iteration.
        if (e.key) |k| if (k.len > lite3.max_key_len) continue;
        const t = if (e.key) |k| try buf.getType(ofs, k) else try buf.arrGetType(ofs, index);
        if (e.key) |k| switch (t) {
            .string => _ = try buf.getStr(ofs, k),
            .bytes => _ = try buf.getBytes(ofs, k),
            .object => try readAll(buf, try buf.getObj(ofs, k), depth + 1),
            .array => try readAll(buf, try buf.getArr(ofs, k), depth + 1),
            else => _ = try buf.getValue(ofs, k),
        } else switch (t) {
            .string => _ = try buf.arrGetStr(ofs, index),
            .bytes => _ = try buf.arrGetBytes(ofs, index),
            .object => try readAll(buf, try buf.arrGetObj(ofs, index), depth + 1),
            .array => try readAll(buf, try buf.arrGetArr(ofs, index), depth + 1),
            else => {},
        }
    }
    try testing.expectEqual(index, try buf.count(ofs));
}
