// Helpers shared by the test files.

const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

pub const Kind = enum { buffer, document, managed };

/// The same write API over each document type, so behaviour tests run
/// against all of them.
pub fn Backend(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        pub const name = @tagName(kind);

        mem: if (kind == .buffer) []align(4) u8 else void,
        doc: switch (kind) {
            .buffer => lite3.Buffer,
            .document => lite3.Document,
            .managed => lite3.ManagedDocument,
        },

        pub fn init(root_type: lite3.Container) !Self {
            return initCapacity(root_type, 1024);
        }

        /// `capacity` is the initial size for growable documents and the
        /// fixed size for a Buffer (at least 1 MiB, so tests don't run out).
        pub fn initCapacity(root_type: lite3.Container, capacity: usize) !Self {
            switch (kind) {
                .buffer => {
                    const mem = try testing.allocator.alignedAlloc(u8, .@"4", @max(capacity, 1 << 20));
                    errdefer testing.allocator.free(mem);
                    return .{ .mem = mem, .doc = try .init(mem, root_type) };
                },
                .document => return .{ .mem = {}, .doc = try .initOptions(testing.allocator, .{ .root = root_type, .initial_capacity = capacity }) },
                .managed => return .{ .mem = {}, .doc = try .initOptions(testing.allocator, .{ .root = root_type, .initial_capacity = capacity }) },
            }
        }

        pub fn deinit(self: *Self) void {
            switch (kind) {
                .buffer => testing.allocator.free(self.mem),
                .document => self.doc.deinit(testing.allocator),
                .managed => self.doc.deinit(),
            }
        }

        pub fn view(self: *const Self) lite3.View {
            return self.doc.view();
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.doc.slice();
        }

        pub fn set(self: *Self, at: lite3.Offset, k: anytype, value: anytype) !void {
            return switch (kind) {
                .document => self.doc.set(testing.allocator, at, k, value),
                else => self.doc.set(at, k, value),
            };
        }

        pub fn setObject(self: *Self, at: lite3.Offset, k: anytype) !lite3.Offset {
            return switch (kind) {
                .document => self.doc.setObject(testing.allocator, at, k),
                else => self.doc.setObject(at, k),
            };
        }

        pub fn setArray(self: *Self, at: lite3.Offset, k: anytype) !lite3.Offset {
            return switch (kind) {
                .document => self.doc.setArray(testing.allocator, at, k),
                else => self.doc.setArray(at, k),
            };
        }

        pub fn append(self: *Self, arr: lite3.Offset, value: anytype) !void {
            return switch (kind) {
                .document => self.doc.append(testing.allocator, arr, value),
                else => self.doc.append(arr, value),
            };
        }

        pub fn appendObject(self: *Self, arr: lite3.Offset) !lite3.Offset {
            return switch (kind) {
                .document => self.doc.appendObject(testing.allocator, arr),
                else => self.doc.appendObject(arr),
            };
        }

        pub fn appendArray(self: *Self, arr: lite3.Offset) !lite3.Offset {
            return switch (kind) {
                .document => self.doc.appendArray(testing.allocator, arr),
                else => self.doc.appendArray(arr),
            };
        }

        pub fn arrSet(self: *Self, arr: lite3.Offset, index: u32, value: anytype) !void {
            return switch (kind) {
                .document => self.doc.arrSet(testing.allocator, arr, index, value),
                else => self.doc.arrSet(arr, index, value),
            };
        }

        pub fn reset(self: *Self, root_type: lite3.Container) !void {
            switch (kind) {
                .buffer => try self.doc.reset(root_type),
                else => self.doc.reset(root_type),
            }
        }

        pub fn arrSetObject(self: *Self, arr: lite3.Offset, index: u32) !lite3.Offset {
            return switch (kind) {
                .document => self.doc.arrSetObject(testing.allocator, arr, index),
                else => self.doc.arrSetObject(arr, index),
            };
        }
    };
}

/// String repetition (the `**` operator is gone in Zig 0.17).
pub fn repeat(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    @setEvalBranchQuota(n * s.len + 1000);
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

pub const backends = .{ Backend(.buffer), Backend(.document), Backend(.managed) };

/// Read every value reachable from `at` through the public API, checking
/// that lookups agree with iteration.
pub fn readAll(v: lite3.View, at: lite3.Offset, depth: usize) !void {
    if (depth > lite3.max_nesting_depth) return error.TooDeep;
    switch (try v.containerType(at)) {
        .object => {
            var it = try v.objectIterator(at);
            var n: u32 = 0;
            while (try it.next()) |e| : (n += 1) {
                const looked_up = try v.getValue(at, e.key);
                try testing.expect(std.meta.eql(std.meta.activeTag(looked_up), std.meta.activeTag(e.value)));
                try readNested(v, e.value, depth);
            }
            try testing.expectEqual(n, try v.count(at));
        },
        .array => {
            var it = try v.arrayIterator(at);
            var n: u32 = 0;
            while (try it.next()) |e| : (n += 1) {
                try testing.expectEqual(n, e.index);
                _ = try v.arrValue(at, e.index);
                try readNested(v, e.value, depth);
            }
            try testing.expectEqual(n, try v.count(at));
        },
    }
}

fn readNested(v: lite3.View, value: lite3.Value, depth: usize) anyerror!void {
    switch (value) {
        .object => |o| try readAll(v, o, depth + 1),
        .array => |a| try readAll(v, a, depth + 1),
        else => {},
    }
}
