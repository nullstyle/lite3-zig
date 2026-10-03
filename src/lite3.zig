//! Zig bindings for Lite³, a JSON-compatible zero-copy serialization format
//! that stores a document as a B-tree inside one contiguous buffer.
//!
//! Types:
//! - `View`: read-only access to serialized bytes. All reads, iteration and
//!   JSON output live here, implemented in Zig.
//! - `Buffer`: a document in caller-provided, fixed-size memory.
//! - `Document`: a growable document; pass the allocator to each call that
//!   may allocate (like `std.ArrayList`).
//! - `ManagedDocument`: a `Document` that stores its allocator.
//!
//! Writes go through the lite3 C library (B-tree insertion), so every
//! writable document lives in 4-byte-aligned memory.
//!
//! Lifetimes: slices returned by reads (strings, bytes, keys) point into the
//! document and are valid until its next write. `View`s and iterators know
//! when their document was written to and return `error.StaleView` instead of
//! reading stale memory.
//!
//! Untrusted input: see SECURITY.md. Every constructor that takes serialized
//! bytes runs `validate` unless its name ends in `Unchecked`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("lite3_build_options");
const c = @import("lite3_c");
const validation = @import("validate.zig");

const Allocator = std.mem.Allocator;

/// True when JSON decoding (yyjson) is compiled in. JSON encoding is always
/// available.
pub const json_enabled: bool = build_options.json_enabled;

comptime {
    if (builtin.target.cpu.arch.endian() == .big)
        @compileError("lite3 requires a little-endian target");
    if (builtin.target.os.tag == .windows)
        @compileError("lite3-zig is not yet tested on Windows");
}

// ---------------------------------------------------------------------------
// Format constants (vendor/lite3/include/lite3.h)
// ---------------------------------------------------------------------------

const node_size = 96;
const node_alignment = 4;
const tree_height_max = 9;
const hash_probe_max = 128;
const djb2_seed: u32 = 5381;
const ofs_hashes = 4;
const ofs_size_kc = 32;
const ofs_kv = 36;
const ofs_child = 64;

/// Largest document lite3 can address (its offsets are 32-bit).
pub const capacity_limit: usize = std.math.maxInt(u32);

/// Deepest container nesting accepted by `validate` and by JSON encoding
/// (the root is depth 1).
pub const max_nesting_depth = validation.max_nesting_depth;

/// Longest key a write accepts as a plain (not NUL-terminated) slice when no
/// allocator is at hand. Longer keys work when passed as a `Key` or a
/// `[:0]const u8`, or through `Document` (which copies with its allocator).
pub const max_stack_key_len = 1023;

// ---------------------------------------------------------------------------
// Basic types
// ---------------------------------------------------------------------------

/// The type of a value, as stored (lite3's type tags).
pub const Type = enum(u8) {
    null = 0,
    bool = 1,
    int = 2,
    float = 3,
    bytes = 4,
    string = 5,
    object = 6,
    array = 7,
};

/// The two container types.
pub const Container = enum(u8) {
    object = 6,
    array = 7,
};

/// Position of an object or array inside a document. Obtained from the
/// document (`root`, `setObject`, `getObject`, ...); only meaningful for the
/// document it came from.
pub const Offset = enum(u32) {
    root = 0,
    _,
};

/// The document's root container.
pub const root = Offset.root;

/// A decoded value. `string` and `bytes` point into the document.
pub const Value = union(Type) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    bytes: []const u8,
    string: []const u8,
    object: Offset,
    array: Offset,
};

/// Wraps a byte slice so `set`/`append` store it as lite3 bytes rather than a
/// string, and so `get(Bytes, ...)` reads one.
pub const Bytes = struct {
    data: []const u8,
};

/// Mark `data` to be stored as bytes.
pub fn bytes(data: []const u8) Bytes {
    return .{ .data = data };
}

/// A key with its hash precomputed. `key("name")` hashes at compile time,
/// which makes lookups and writes with a fixed key skip hashing entirely.
pub const Key = struct {
    str: [:0]const u8,
    hash: u32,

    /// Hash a runtime key once to reuse it for many calls.
    pub fn init(str: [:0]const u8) Key {
        return .{ .str = str, .hash = djb2(str) };
    }
};

/// A compile-time key.
pub fn key(comptime str: []const u8) Key {
    if (comptime std.mem.indexOfScalar(u8, str, 0) != null) @compileError("lite3 keys cannot contain NUL");
    const z: [:0]const u8 = comptime std.fmt.comptimePrint("{s}", .{str});
    const hash = comptime blk: {
        @setEvalBranchQuota(str.len * 4 + 1000);
        break :blk djb2(str);
    };
    return .{ .str = z, .hash = hash };
}

fn djb2(str: []const u8) u32 {
    var h = djb2_seed;
    for (str) |b| h = (h << 5) +% h +% b;
    return h;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors from reading a document.
pub const ReadError = error{
    /// No entry with that key.
    NotFound,
    /// The value or container is of a different type than requested.
    TypeMismatch,
    /// Array index past the end.
    IndexOutOfBounds,
    /// An integer does not fit the requested type.
    IntegerOverflow,
    /// The document is malformed (only possible for unvalidated bytes).
    CorruptData,
    /// The Offset does not point at a container of this document.
    InvalidOffset,
    /// The document was written to after this View or iterator was taken.
    StaleView,
};

/// Errors from writing to a fixed-size document (`Buffer`).
pub const WriteError = error{
    /// The document is full.
    NoSpaceLeft,
    TypeMismatch,
    IndexOutOfBounds,
    /// An integer value does not fit in i64.
    IntegerOverflow,
    /// The key contains a NUL byte.
    InvalidKey,
    /// The key is too long (see `max_stack_key_len`), or longer than lite3's
    /// limit of 2^30 bytes.
    KeyTooLong,
    /// Every slot in the key's hash probe sequence holds another key. lite3's
    /// hash is unseeded, so crafted keys can cause this; see SECURITY.md.
    KeyCollision,
    /// A string or bytes value longer than lite3's 4 GiB limit.
    ValueTooLarge,
    /// The value lies inside this Buffer and is larger than the scratch space
    /// used to copy it aside; copy it first.
    ValueAliasesDocument,
    InvalidOffset,
    CorruptData,
};

/// Errors from writing to a growable document.
pub const GrowError = error{OutOfMemory} || WriteError;

/// Errors from decoding JSON.
pub const DecodeError = error{
    /// Not valid JSON; `JsonDiagnostics` has the position.
    SyntaxError,
    /// Nested deeper than 32 levels (lite3's JSON limit).
    NestingTooDeep,
    /// An object key contains `\u0000`.
    InvalidKey,
    /// The root is not an object or array.
    InvalidRoot,
    KeyCollision,
    /// The result does not fit (Buffer) or would exceed `max_capacity`.
    NoSpaceLeft,
    OutOfMemory,
    Unexpected,
};

/// Errors from encoding JSON.
pub const EncodeError = error{
    /// NaN or infinity cannot be represented in JSON.
    NonFiniteNumber,
    /// A string value is not valid UTF-8.
    InvalidUtf8,
    /// Containers nested deeper than `max_nesting_depth`.
    NestingTooDeep,
} || ReadError || std.Io.Writer.Error;

/// Union of every error this module returns.
pub const Error = ReadError || GrowError || DecodeError || EncodeError;

/// Where JSON parsing failed.
pub const JsonDiagnostics = struct {
    /// yyjson error code.
    code: u32 = 0,
    /// Byte offset into the input.
    position: usize = 0,
    /// Static description.
    message: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Check that `bytes` (a document's used bytes, root at offset 0) is a
/// well-formed lite3 document. A document that passes can be read and written
/// through this API without out-of-bounds access or unbounded work, whatever
/// its origin. Linear time, no allocation.
///
/// It does not detect structure sharing that fits inside dead space (bytes
/// left behind by overwrites): such a document is still safe, but a later
/// write may make parts of it read as `CorruptData`. `validateStrict` rules
/// that out too.
pub fn validate(document: []const u8) error{CorruptData}!void {
    return validation.validate(document);
}

/// Like `validate`, and additionally proves that no byte belongs to two nodes
/// or entries, so the document stays valid under any sequence of writes. Use
/// it before modifying documents from untrusted sources. Needs `len / 8`
/// bytes of scratch memory.
pub fn validateStrict(gpa: Allocator, document: []const u8) error{ CorruptData, OutOfMemory }!void {
    return validation.validateStrict(gpa, document);
}

// ---------------------------------------------------------------------------
// Keys as arguments
// ---------------------------------------------------------------------------

/// A key argument resolved to bytes plus hash. `z` is set when the bytes are
/// known to be followed by a NUL (which lite3's write path needs).
const KeyArg = struct {
    bytes: []const u8,
    hash: u32,
    z: ?[*:0]const u8,
};

/// Accepts a `Key`, anything that coerces to `[:0]const u8` (string
/// literals), or a `[]const u8`.
fn keyArg(k: anytype) KeyArg {
    const T = @TypeOf(k);
    if (T == Key) return .{ .bytes = k.str, .hash = k.hash, .z = k.str.ptr };
    if (comptime isSentinelString(T)) {
        const s: [:0]const u8 = k;
        return .{ .bytes = s, .hash = djb2(s), .z = s.ptr };
    }
    const s: []const u8 = k;
    return .{ .bytes = s, .hash = djb2(s), .z = null };
}

fn isSentinelString(comptime T: type) bool {
    const s = std.meta.sentinel(T) orelse return false;
    return s == 0 and std.meta.Elem(T) == u8;
}

// ---------------------------------------------------------------------------
// View: reads
// ---------------------------------------------------------------------------

/// Read-only access to a serialized document. Cheap to copy. Obtained from
/// `Buffer.view`/`Document.view`, or from bytes with `View.fromBytes`.
pub const View = struct {
    bytes: []const u8,
    /// Write counter of the owning document, if any.
    epoch: ?*const u32 = null,
    epoch_seen: u32 = 0,

    /// View `document` (its used bytes) after `validate`.
    pub fn fromBytes(document: []const u8) ReadError!View {
        validate(document) catch return error.CorruptData;
        return .{ .bytes = document };
    }

    /// View bytes this program produced itself, without validation. Reads
    /// stay in bounds either way; validation also guarantees consistency.
    pub fn fromBytesUnchecked(document: []const u8) View {
        return .{ .bytes = document };
    }

    fn live(v: View) ReadError!void {
        if (v.epoch) |e| if (e.* != v.epoch_seen) return error.StaleView;
    }

    fn u32At(v: View, ofs: usize) u32 {
        return std.mem.readInt(u32, v.bytes[ofs..][0..4], .little);
    }

    fn inBounds(v: View, ofs: usize, len: usize) bool {
        return ofs <= v.bytes.len and len <= v.bytes.len - ofs;
    }

    /// Type of the container at `at`.
    pub fn containerType(v: View, at: Offset) ReadError!Container {
        try v.live();
        const ofs: usize = @backingInt(at);
        if (ofs % node_alignment != 0 or !v.inBounds(ofs, node_size)) return error.InvalidOffset;
        return switch (v.bytes[ofs]) {
            6 => .object,
            7 => .array,
            else => error.InvalidOffset,
        };
    }

    fn expect(v: View, at: Offset, want: Container) ReadError!void {
        if (try v.containerType(at) != want) return error.TypeMismatch;
    }

    /// Type of the root container.
    pub fn rootType(v: View) ReadError!Container {
        return v.containerType(root);
    }

    /// Number of entries in the object or array at `at`.
    pub fn count(v: View, at: Offset) ReadError!u32 {
        _ = try v.containerType(at);
        return v.u32At(@as(usize, @backingInt(at)) + ofs_size_kc) >> 6;
    }

    /// Find `hash` in the container rooted at `ofs` the way lite3's lookup
    /// does; returns the kv offset. Every read is bounds-checked.
    fn findHash(v: View, ofs: usize, hash: u32) ReadError!?usize {
        var node = ofs;
        var walks: usize = 0;
        while (true) {
            if (node % node_alignment != 0 or !v.inBounds(node, node_size)) return error.CorruptData;
            const kc = v.u32At(node + ofs_size_kc) & 0x7;
            var i: usize = 0;
            while (i < kc and v.u32At(node + ofs_hashes + 4 * i) < hash) i += 1;
            if (i < kc and v.u32At(node + ofs_hashes + 4 * i) == hash) return v.u32At(node + ofs_kv + 4 * i);
            if (v.u32At(node + ofs_child) == 0) return null;
            walks += 1;
            if (walks > tree_height_max) return error.CorruptData;
            node = v.u32At(node + ofs_child + 4 * i);
        }
    }

    /// Decode the key entry at `kv`: key bytes (without NUL) and the offset
    /// of the value that follows.
    fn keyAt(v: View, kv: usize) ReadError!struct { key: []const u8, value_ofs: usize } {
        if (!v.inBounds(kv, 1)) return error.CorruptData;
        const tag_len: usize = (v.bytes[kv] & 0x3) + 1;
        if (!v.inBounds(kv, tag_len)) return error.CorruptData;
        var tag: u32 = 0;
        for (0..tag_len) |i| tag |= @as(u32, v.bytes[kv + i]) << @intCast(8 * i);
        const size: usize = tag >> 2;
        const start = kv + tag_len;
        if (size == 0 or !v.inBounds(start, size) or v.bytes[start + size - 1] != 0) return error.CorruptData;
        return .{ .key = v.bytes[start .. start + size - 1], .value_ofs = start + size };
    }

    /// Value offset for `k` in the object at `at` (lite3's probing).
    fn lookup(v: View, at: Offset, k: KeyArg) ReadError!usize {
        try v.expect(at, .object);
        const ofs: usize = @backingInt(at);
        for (0..hash_probe_max) |attempt| {
            const probe = k.hash +% @as(u32, @intCast(attempt * attempt));
            const kv = try v.findHash(ofs, probe) orelse return error.NotFound;
            const entry = try v.keyAt(kv);
            if (std.mem.eql(u8, entry.key, k.bytes)) return entry.value_ofs;
        }
        return error.NotFound;
    }

    /// Value offset for `index` in the array at `arr`.
    fn lookupIndex(v: View, arr: Offset, index: u32) ReadError!usize {
        try v.expect(arr, .array);
        if (index >= try v.count(arr)) return error.IndexOutOfBounds;
        return try v.findHash(@backingInt(arr), index) orelse error.CorruptData;
    }

    fn valueAt(v: View, ofs: usize) ReadError!Value {
        if (!v.inBounds(ofs, 1)) return error.CorruptData;
        const t = v.bytes[ofs];
        switch (t) {
            0 => return .null,
            1 => {
                if (!v.inBounds(ofs, 2) or v.bytes[ofs + 1] > 1) return error.CorruptData;
                return .{ .bool = v.bytes[ofs + 1] == 1 };
            },
            2, 3 => {
                if (!v.inBounds(ofs, 9)) return error.CorruptData;
                const raw = std.mem.readInt(u64, v.bytes[ofs + 1 ..][0..8], .little);
                return if (t == 2) .{ .int = @bitCast(raw) } else .{ .float = @bitCast(raw) };
            },
            4, 5 => {
                if (!v.inBounds(ofs, 5)) return error.CorruptData;
                const n: usize = v.u32At(ofs + 1);
                if (!v.inBounds(ofs + 5, n)) return error.CorruptData;
                const data = v.bytes[ofs + 5 .. ofs + 5 + n];
                if (t == 4) return .{ .bytes = data };
                if (n == 0 or data[n - 1] != 0) return error.CorruptData;
                return .{ .string = data[0 .. n - 1] };
            },
            6, 7 => {
                if (ofs % node_alignment != 0 or !v.inBounds(ofs, node_size)) return error.CorruptData;
                const o: Offset = @fromBackingInt(@intCast(ofs));
                return if (t == 6) .{ .object = o } else .{ .array = o };
            },
            else => return error.CorruptData,
        }
    }

    /// The value for `k` in the object at `at`.
    pub fn getValue(v: View, at: Offset, k: anytype) ReadError!Value {
        return v.valueAt(try v.lookup(at, keyArg(k)));
    }

    /// The value at `index` in the array at `arr`.
    pub fn arrValue(v: View, arr: Offset, index: u32) ReadError!Value {
        return v.valueAt(try v.lookupIndex(arr, index));
    }

    /// The value for `k`, as `T`: `bool`, an integer type (range-checked), a
    /// float type, `[]const u8` (string), `Bytes`, `Value`, or `?T` of any of
    /// these (a stored null reads as `null`).
    pub fn get(v: View, comptime T: type, at: Offset, k: anytype) ReadError!T {
        return convert(T, try v.getValue(at, k));
    }

    /// The array element at `index`, as `T` (see `get`).
    pub fn arrGet(v: View, comptime T: type, arr: Offset, index: u32) ReadError!T {
        return convert(T, try v.arrValue(arr, index));
    }

    /// The object stored under `k`.
    pub fn getObject(v: View, at: Offset, k: anytype) ReadError!Offset {
        return switch (try v.getValue(at, k)) {
            .object => |o| o,
            else => error.TypeMismatch,
        };
    }

    /// The array stored under `k`.
    pub fn getArray(v: View, at: Offset, k: anytype) ReadError!Offset {
        return switch (try v.getValue(at, k)) {
            .array => |o| o,
            else => error.TypeMismatch,
        };
    }

    /// The object at `index` in the array at `arr`.
    pub fn arrGetObject(v: View, arr: Offset, index: u32) ReadError!Offset {
        return switch (try v.arrValue(arr, index)) {
            .object => |o| o,
            else => error.TypeMismatch,
        };
    }

    /// The array at `index` in the array at `arr`.
    pub fn arrGetArray(v: View, arr: Offset, index: u32) ReadError!Offset {
        return switch (try v.arrValue(arr, index)) {
            .array => |o| o,
            else => error.TypeMismatch,
        };
    }

    /// Type of the value stored under `k`.
    pub fn typeOf(v: View, at: Offset, k: anytype) ReadError!Type {
        return std.meta.activeTag(try v.getValue(at, k));
    }

    /// Whether the object at `at` has key `k`.
    pub fn has(v: View, at: Offset, k: anytype) ReadError!bool {
        _ = v.lookup(at, keyArg(k)) catch |err| switch (err) {
            error.NotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Iterate the entries of the object at `at`.
    pub fn objectIterator(v: View, at: Offset) ReadError!ObjectIterator {
        try v.expect(at, .object);
        return .{ .walk = try Walk.init(v, at) };
    }

    /// Iterate the elements of the array at `arr`.
    pub fn arrayIterator(v: View, arr: Offset) ReadError!ArrayIterator {
        try v.expect(arr, .array);
        return .{ .walk = try Walk.init(v, arr) };
    }

    /// Write the container at `at` as JSON.
    pub fn writeJson(v: View, at: Offset, w: *std.Io.Writer, options: JsonOptions) EncodeError!void {
        const t = try v.containerType(at);
        try writeJsonValue(v, if (t == .object) .{ .object = at } else .{ .array = at }, w, options, 1);
        if (options.whitespace == .indent_2) try w.writeByte('\n');
    }

    /// The container at `at` as a JSON string allocated with `gpa`.
    pub fn jsonAlloc(v: View, gpa: Allocator, at: Offset, options: JsonOptions) (EncodeError || error{OutOfMemory})![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        v.writeJson(at, &out.writer, options) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        return out.toOwnedSlice();
    }

    /// `{f}` formatting: the document as compact JSON.
    pub fn format(v: View, w: *std.Io.Writer) std.Io.Writer.Error!void {
        v.writeJson(root, w, .{}) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => |e| try w.print("<lite3: {s}>", .{@errorName(e)}),
        };
    }
};

fn convert(comptime T: type, value: Value) ReadError!T {
    if (T == Value) return value;
    switch (@typeInfo(T)) {
        .optional => |o| return if (value == .null) null else try convert(o.child, value),
        .bool => return switch (value) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },
        .int => return switch (value) {
            .int => |i| std.math.cast(T, i) orelse error.IntegerOverflow,
            else => error.TypeMismatch,
        },
        .float => return switch (value) {
            .float => |f| @floatCast(f),
            else => error.TypeMismatch,
        },
        else => {},
    }
    if (T == []const u8) return switch (value) {
        .string => |s| s,
        else => error.TypeMismatch,
    };
    if (T == Bytes) return switch (value) {
        .bytes => |b| .{ .data = b },
        else => error.TypeMismatch,
    };
    @compileError("lite3: cannot read a value as " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// Iteration
// ---------------------------------------------------------------------------

/// In-order walk over one container's B-tree, yielding kv offsets. Bounded by
/// the container's element count (and the document size) even for malformed
/// documents.
const Walk = struct {
    view: View,
    path: [tree_height_max + 1]Cursor = undefined,
    depth: u8 = 0,
    remaining: usize,

    const Cursor = struct { ofs: u32, key_count: u8, internal: bool, pos: u8 = 0 };

    fn init(v: View, at: Offset) ReadError!Walk {
        const n = try v.count(at);
        var w: Walk = .{ .view = v, .remaining = @min(n, v.bytes.len) };
        w.path[0] = try w.cursor(@backingInt(at));
        return w;
    }

    fn cursor(w: *const Walk, ofs: usize) ReadError!Cursor {
        const v = w.view;
        if (ofs % node_alignment != 0 or !v.inBounds(ofs, node_size)) return error.CorruptData;
        return .{
            .ofs = @intCast(ofs),
            .key_count = @intCast(v.u32At(ofs + ofs_size_kc) & 0x7),
            .internal = v.u32At(ofs + ofs_child) != 0,
        };
    }

    fn next(w: *Walk) ReadError!?usize {
        try w.view.live();
        while (true) {
            const cur = &w.path[w.depth];
            if (cur.pos > 2 * @as(usize, cur.key_count)) {
                if (w.depth == 0) return null;
                w.depth -= 1;
                continue;
            }
            const pos = cur.pos;
            cur.pos += 1;
            if (pos % 2 == 0) {
                if (!cur.internal) continue;
                if (w.depth == tree_height_max) return error.CorruptData;
                const child = w.view.u32At(@as(usize, cur.ofs) + ofs_child + 2 * @as(usize, pos));
                const next_cursor = try w.cursor(child);
                w.depth += 1;
                w.path[w.depth] = next_cursor;
                continue;
            }
            if (w.remaining == 0) return error.CorruptData;
            w.remaining -= 1;
            return w.view.u32At(@as(usize, cur.ofs) + ofs_kv + 4 * @as(usize, pos / 2));
        }
    }
};

/// Iterates an object's entries in storage (hash) order.
pub const ObjectIterator = struct {
    walk: Walk,

    pub const Entry = struct {
        /// Points into the document; valid until its next write.
        key: []const u8,
        value: Value,
    };

    pub fn next(it: *ObjectIterator) ReadError!?Entry {
        const kv = try it.walk.next() orelse return null;
        const entry = try it.walk.view.keyAt(kv);
        return .{ .key = entry.key, .value = try it.walk.view.valueAt(entry.value_ofs) };
    }
};

/// Iterates an array's elements in index order.
pub const ArrayIterator = struct {
    walk: Walk,
    index: u32 = 0,

    pub const Element = struct {
        index: u32,
        value: Value,
    };

    pub fn next(it: *ArrayIterator) ReadError!?Element {
        const kv = try it.walk.next() orelse return null;
        defer it.index += 1;
        return .{ .index = it.index, .value = try it.walk.view.valueAt(kv) };
    }
};

// ---------------------------------------------------------------------------
// JSON encoding (pure Zig)
// ---------------------------------------------------------------------------

pub const JsonOptions = struct {
    whitespace: enum { minified, indent_2 } = .minified,
};

fn writeJsonValue(v: View, value: Value, w: *std.Io.Writer, options: JsonOptions, depth: usize) EncodeError!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeJsonFloat(f, w),
        .string => |s| {
            if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
            try writeJsonString(s, w);
        },
        .bytes => |b| {
            // lite3's JSON form for bytes: a base64 string.
            try w.writeByte('"');
            var chunk: [3 * 256]u8 = undefined;
            var encoded: [4 * 256]u8 = undefined;
            var rest = b;
            while (rest.len > 0) {
                const n = @min(rest.len, chunk.len);
                @memcpy(chunk[0..n], rest[0..n]);
                try w.writeAll(std.base64.standard.Encoder.encode(&encoded, chunk[0..n]));
                rest = rest[n..];
            }
            try w.writeByte('"');
        },
        .object => |o| {
            if (depth > max_nesting_depth) return error.NestingTooDeep;
            var it = try v.objectIterator(o);
            try w.writeByte('{');
            var first = true;
            while (try it.next()) |e| : (first = false) {
                if (!first) try w.writeByte(',');
                try newline(w, options, depth);
                if (!std.unicode.utf8ValidateSlice(e.key)) return error.InvalidUtf8;
                try writeJsonString(e.key, w);
                try w.writeAll(if (options.whitespace == .minified) ":" else ": ");
                try writeJsonValue(v, e.value, w, options, depth + 1);
            }
            if (!first) try newline(w, options, depth - 1);
            try w.writeByte('}');
        },
        .array => |a| {
            if (depth > max_nesting_depth) return error.NestingTooDeep;
            var it = try v.arrayIterator(a);
            try w.writeByte('[');
            var first = true;
            while (try it.next()) |e| : (first = false) {
                if (!first) try w.writeByte(',');
                try newline(w, options, depth);
                try writeJsonValue(v, e.value, w, options, depth + 1);
            }
            if (!first) try newline(w, options, depth - 1);
            try w.writeByte(']');
        },
    }
}

fn newline(w: *std.Io.Writer, options: JsonOptions, depth: usize) std.Io.Writer.Error!void {
    if (options.whitespace == .minified) return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', 2 * depth);
}

fn writeJsonFloat(f: f64, w: *std.Io.Writer) EncodeError!void {
    if (!std.math.isFinite(f)) return error.NonFiniteNumber;
    const a = @abs(f);
    var buf: [64]u8 = undefined;
    // Shortest round-trip digits; scientific notation outside a readable range.
    const text = (if (a != 0 and (a < 1e-5 or a >= 1e16))
        std.fmt.bufPrint(&buf, "{e}", .{f})
    else
        std.fmt.bufPrint(&buf, "{d}", .{f})) catch unreachable;
    try w.writeAll(text);
    // Keep floats distinguishable from integers when read back.
    if (std.mem.indexOfAny(u8, text, ".e") == null) try w.writeAll(".0");
}

fn writeJsonString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const escape: ?[]const u8 = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (escape == null and ch >= 0x20) continue;
        try w.writeAll(s[start..i]);
        if (escape) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{ch});
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Writing (shared by Buffer and Document)
// ---------------------------------------------------------------------------

/// A value as it will be stored.
const Scalar = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,

    fn of(value: anytype) WriteError!Scalar {
        const T = @TypeOf(value);
        if (T == Scalar) return value;
        if (T == @TypeOf(null)) return .null;
        if (T == Bytes) return .{ .bytes = value.data };
        switch (@typeInfo(T)) {
            .bool => return .{ .bool = value },
            .int, .comptime_int => return .{ .int = std.math.cast(i64, value) orelse return error.IntegerOverflow },
            .float, .comptime_float => return .{ .float = value },
            .optional => return if (value) |inner| of(inner) else .null,
            else => {},
        }
        if (comptime isStringLike(T)) return .{ .string = value };
        @compileError("lite3: cannot store a value of type " ++ @typeName(T) ++
            " (use bool, an integer, a float, a string, lite3.bytes(...), or null)");
    }

    fn typeTag(s: Scalar) u8 {
        return switch (s) {
            .null => 0,
            .bool => 1,
            .int => 2,
            .float => 3,
            .bytes => 4,
            .string => 5,
        };
    }

    /// Payload size after the type byte.
    fn payloadLen(s: Scalar) WriteError!usize {
        return switch (s) {
            .null => 0,
            .bool => 1,
            .int, .float => 8,
            .bytes => |b| if (b.len > std.math.maxInt(u32)) error.ValueTooLarge else 4 + b.len,
            .string => |str| if (str.len >= std.math.maxInt(u32)) error.ValueTooLarge else 4 + str.len + 1,
        };
    }

    fn data(s: Scalar) []const u8 {
        return switch (s) {
            .string => |d| d,
            .bytes => |d| d,
            else => &.{},
        };
    }

    fn withData(s: Scalar, d: []const u8) Scalar {
        return switch (s) {
            .string => .{ .string = d },
            .bytes => .{ .bytes = d },
            else => s,
        };
    }

    fn writePayload(s: Scalar, out: []u8) void {
        switch (s) {
            .null => {},
            .bool => |b| out[0] = @intFromBool(b),
            .int => |i| std.mem.writeInt(i64, out[0..8], i, .little),
            .float => |f| std.mem.writeInt(u64, out[0..8], @bitCast(f), .little),
            .bytes => |b| {
                std.mem.writeInt(u32, out[0..4], @intCast(b.len), .little);
                @memmove(out[4..][0..b.len], b);
            },
            .string => |str| {
                std.mem.writeInt(u32, out[0..4], @intCast(str.len + 1), .little);
                @memmove(out[4..][0..str.len], str);
                out[4 + str.len] = 0;
            },
        }
    }
};

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// Where an entry goes: a key in an object, or an index in an array.
const Slot = union(enum) {
    key: KeyArg,
    index: u32,
};

fn mapStatus(ret: c_int) WriteError {
    return switch (-ret) {
        c.LITE3ZIG_E_NO_SPACE => error.NoSpaceLeft,
        c.LITE3ZIG_E_KEY_COLLISION => error.KeyCollision,
        else => error.CorruptData,
    };
}

/// Writes against `mem[0..len.*]`. Callers check the target container and
/// slot first, and supply a NUL-terminated key.
const Raw = struct {
    mem: []align(4) u8,
    len: *usize,

    fn view(r: Raw) View {
        return .{ .bytes = r.mem[0..r.len.*] };
    }

    fn keyParts(slot: Slot, z: ?[*:0]const u8) struct { ptr: ?[*:0]const u8, hash: u32, size: u32 } {
        return switch (slot) {
            .key => |k| .{ .ptr = z, .hash = k.hash, .size = @intCast(k.bytes.len + 1) },
            .index => |i| .{ .ptr = null, .hash = i, .size = 0 },
        };
    }

    inline fn insertScalar(r: Raw, at: Offset, slot: Slot, z: ?[*:0]const u8, value: Scalar) WriteError!void {
        const payload_len = try value.payloadLen();
        const k = keyParts(slot, z);
        var payload_ofs: u32 = 0;
        const ret = c.shim_insert(r.mem.ptr, r.len, @backingInt(at), r.mem.len, k.ptr, k.hash, k.size, value.typeTag(), payload_len, &payload_ofs);
        if (ret < 0) return mapStatus(ret);
        value.writePayload(r.mem[payload_ofs..][0..payload_len]);
    }

    fn insertContainer(r: Raw, at: Offset, slot: Slot, z: ?[*:0]const u8, kind: Container) WriteError!Offset {
        const k = keyParts(slot, z);
        var out: u32 = 0;
        const ret = c.shim_insert_container(r.mem.ptr, r.len, @backingInt(at), r.mem.len, k.ptr, k.hash, k.size, @backingInt(kind), &out);
        if (ret < 0) return mapStatus(ret);
        return @fromBackingInt(out);
    }
};

/// Check the target of a write and resolve the slot.
inline fn writeSlot(v: View, at: Offset, target: anytype) WriteError!Slot {
    const T = @TypeOf(target);
    if (T == Append) {
        try expectWritable(v, at, .array);
        return .{ .index = v.count(at) catch unreachable };
    }
    if (T == ArrayIndex) {
        try expectWritable(v, at, .array);
        if (target.index > v.count(at) catch unreachable) return error.IndexOutOfBounds;
        return .{ .index = target.index };
    }
    try expectWritable(v, at, .object);
    const k = keyArg(target);
    if (std.mem.indexOfScalar(u8, k.bytes, 0) != null) return error.InvalidKey;
    if (k.bytes.len + 1 >= 1 << 30) return error.KeyTooLong;
    return .{ .key = k };
}

const Append = struct {};
const ArrayIndex = struct { index: u32 };

fn expectWritable(v: View, at: Offset, want: Container) WriteError!void {
    const got = v.containerType(at) catch |err| return switch (err) {
        error.InvalidOffset => error.InvalidOffset,
        else => error.CorruptData,
    };
    if (got != want) return error.TypeMismatch;
}

/// Upper bound of the bytes a write can add: entry, alignment, two nodes.
fn writeReserve(slot: Slot, payload_len: usize) usize {
    const key_len = switch (slot) {
        .key => |k| 4 + k.bytes.len + 1,
        .index => 0,
    };
    return key_len + 1 + payload_len + node_alignment + 2 * node_size;
}

fn overlaps(mem: []const u8, data: []const u8) bool {
    if (data.len == 0) return false;
    const m = @intFromPtr(mem.ptr);
    const d = @intFromPtr(data.ptr);
    return d < m + mem.len and m < d + data.len;
}

// ---------------------------------------------------------------------------
// Buffer
// ---------------------------------------------------------------------------

/// A document in caller-owned memory of fixed size. Writes fail with
/// `error.NoSpaceLeft` when it is full.
pub const Buffer = struct {
    mem: []align(4) u8,
    len: usize,
    epoch: u32 = 0,

    /// Size of scratch space used to copy aside a value that lies inside
    /// this Buffer (`setStr(k, view.get(...))` and the like).
    pub const alias_scratch_len = 4096;

    /// An empty document of the given root type in `mem`.
    pub fn init(mem: []align(4) u8, root_type: Container) WriteError!Buffer {
        var self: Buffer = .{ .mem = mem, .len = 0 };
        try self.reset(root_type);
        return self;
    }

    /// Use the `len` serialized bytes at the start of `mem` after
    /// `validate`. The rest of `mem` is room to grow.
    pub fn fromBytes(mem: []align(4) u8, len: usize) ReadError!Buffer {
        if (len > mem.len) return error.CorruptData;
        validate(mem[0..len]) catch return error.CorruptData;
        return .{ .mem = mem, .len = len };
    }

    /// Like `fromBytes` without validation; only for bytes this program
    /// produced itself.
    pub fn fromBytesUnchecked(mem: []align(4) u8, len: usize) Buffer {
        std.debug.assert(len <= mem.len);
        return .{ .mem = mem, .len = len };
    }

    /// Decode JSON into `mem`. `gpa` holds the parse tree while decoding.
    /// On failure the contents of `mem` are unspecified.
    pub fn fromJson(gpa: Allocator, mem: []align(4) u8, json: []const u8, diag: ?*JsonDiagnostics) DecodeError!Buffer {
        comptime requireJson();
        const gpa_copy = gpa;
        const doc = try jsonParse(&gpa_copy, json, diag);
        defer c.shim_json_free(doc.handle);
        var len: usize = 0;
        try jsonConvert(doc, mem, &len);
        return .{ .mem = mem, .len = len };
    }

    /// Read access. The View fails with `error.StaleView` after this Buffer
    /// is written to.
    pub fn view(self: *const Buffer) View {
        return .{ .bytes = self.mem[0..self.len], .epoch = &self.epoch, .epoch_seen = self.epoch };
    }

    /// The serialized document.
    pub fn slice(self: *const Buffer) []const u8 {
        return self.mem[0..self.len];
    }

    pub fn capacity(self: *const Buffer) usize {
        return self.mem.len;
    }

    /// Make the document an empty object or array.
    pub fn reset(self: *Buffer, root_type: Container) WriteError!void {
        self.epoch +%= 1;
        var len: usize = 0;
        const ret = c.shim_init(self.mem.ptr, &len, self.mem.len, @backingInt(root_type));
        if (ret < 0) return error.NoSpaceLeft;
        self.len = len;
    }

    fn raw(self: *Buffer) Raw {
        return .{ .mem = self.mem, .len = &self.len };
    }

    fn write(self: *Buffer, at: Offset, target: anytype, value: anytype) WriteError!void {
        const scalar = try Scalar.of(value);
        const slot = try writeSlot(self.raw().view(), at, target);
        self.epoch +%= 1;
        // A value inside this Buffer could be clobbered (lite3 zeroes the old
        // value on overwrite) before it is copied in, and so could a key.
        if (directKey(slot, self.mem)) |z| {
            if (!overlaps(self.mem, scalar.data())) return self.raw().insertScalar(at, slot, z, scalar);
        }
        return self.writeCopied(at, slot, scalar);
    }

    /// `write` with the key and value copied out of the document first.
    /// Kept out of line so the common path has a small stack frame.
    noinline fn writeCopied(self: *Buffer, at: Offset, slot: Slot, scalar: Scalar) WriteError!void {
        var key_buf: [max_stack_key_len + 1]u8 = undefined;
        const z = try stackKey(slot, &key_buf, self.mem);
        var scratch: [alias_scratch_len]u8 = undefined;
        const data = scalar.data();
        var stored = scalar;
        if (overlaps(self.mem, data)) {
            if (data.len > scratch.len) return error.ValueAliasesDocument;
            @memcpy(scratch[0..data.len], data);
            stored = scalar.withData(scratch[0..data.len]);
        }
        return self.raw().insertScalar(at, slot, z, stored);
    }

    fn writeContainer(self: *Buffer, at: Offset, target: anytype, kind: Container) WriteError!Offset {
        const slot = try writeSlot(self.raw().view(), at, target);
        self.epoch +%= 1;
        if (directKey(slot, self.mem)) |z| return self.raw().insertContainer(at, slot, z, kind);
        var key_buf: [max_stack_key_len + 1]u8 = undefined;
        const z = try stackKey(slot, &key_buf, self.mem);
        return self.raw().insertContainer(at, slot, z, kind);
    }

    /// Store `value` under key `k` in the object at `at`, replacing any
    /// existing value. `value`: null, bool, an integer, a float, a string
    /// (`[]const u8`), or `lite3.bytes(...)`.
    pub fn set(self: *Buffer, at: Offset, k: anytype, value: anytype) WriteError!void {
        return self.write(at, k, value);
    }

    /// Store an empty object under `k`; returns its Offset.
    pub fn setObject(self: *Buffer, at: Offset, k: anytype) WriteError!Offset {
        return self.writeContainer(at, k, .object);
    }

    /// Store an empty array under `k`; returns its Offset.
    pub fn setArray(self: *Buffer, at: Offset, k: anytype) WriteError!Offset {
        return self.writeContainer(at, k, .array);
    }

    /// Append `value` to the array at `arr`.
    pub fn append(self: *Buffer, arr: Offset, value: anytype) WriteError!void {
        return self.write(arr, Append{}, value);
    }

    pub fn appendObject(self: *Buffer, arr: Offset) WriteError!Offset {
        return self.writeContainer(arr, Append{}, .object);
    }

    pub fn appendArray(self: *Buffer, arr: Offset) WriteError!Offset {
        return self.writeContainer(arr, Append{}, .array);
    }

    /// Replace element `index` of the array at `arr` (`index == count`
    /// appends).
    pub fn arrSet(self: *Buffer, arr: Offset, index: u32, value: anytype) WriteError!void {
        return self.write(arr, ArrayIndex{ .index = index }, value);
    }

    pub fn arrSetObject(self: *Buffer, arr: Offset, index: u32) WriteError!Offset {
        return self.writeContainer(arr, ArrayIndex{ .index = index }, .object);
    }

    pub fn arrSetArray(self: *Buffer, arr: Offset, index: u32) WriteError!Offset {
        return self.writeContainer(arr, ArrayIndex{ .index = index }, .array);
    }
};

/// The key's own NUL-terminated pointer (null for array slots), or null if
/// it has to be copied first (see `stackKey`).
inline fn directKey(slot: Slot, doc: []const u8) ??[*:0]const u8 {
    const k = switch (slot) {
        .key => |k| k,
        .index => return @as(?[*:0]const u8, null),
    };
    const z = k.z orelse return null;
    if (overlaps(doc, k.bytes)) return null;
    return z;
}

/// NUL-terminated pointer for a key, copying into `buf` when the key has no
/// terminator or lies inside the document (lite3 may zero the old entry
/// before copying the key in).
fn stackKey(slot: Slot, buf: []u8, doc: []const u8) WriteError!?[*:0]const u8 {
    const k = switch (slot) {
        .key => |k| k,
        .index => return null,
    };
    if (k.z) |z| if (!overlaps(doc, k.bytes)) return z;
    if (k.bytes.len >= buf.len) return error.KeyTooLong;
    @memcpy(buf[0..k.bytes.len], k.bytes);
    buf[k.bytes.len] = 0;
    return buf[0..k.bytes.len :0].ptr;
}

// ---------------------------------------------------------------------------
// JSON decoding (yyjson, via the shim)
// ---------------------------------------------------------------------------

fn requireJson() void {
    if (!json_enabled) @compileError("JSON decoding is disabled in this build (-Djson=false)");
}

const ParsedJson = struct { handle: ?*anyopaque, size_hint: usize };

/// yyjson allocations go through the Zig allocator. yyjson's `free` gets no
/// size, so each block carries its size in a 16-byte header.
const YyAlloc = struct {
    const header = 16;

    fn alloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const gpa: *const Allocator = @ptrCast(@alignCast(ctx));
        const block = gpa.alignedAlloc(u8, .@"16", size + header) catch return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], size, .little);
        return block.ptr + header;
    }

    fn realloc(ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, size: usize) callconv(.c) ?*anyopaque {
        const new = alloc(ctx, size) orelse return null;
        if (ptr) |p| {
            const old: [*]const u8 = @ptrCast(p);
            @memcpy(@as([*]u8, @ptrCast(new))[0..@min(old_size, size)], old[0..@min(old_size, size)]);
            free(ctx, p);
        }
        return new;
    }

    fn free(ctx: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const p = ptr orelse return;
        const gpa: *const Allocator = @ptrCast(@alignCast(ctx));
        const block: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(p)) - header);
        const size = std.mem.readInt(usize, block[0..@sizeOf(usize)], .little);
        gpa.free(block[0 .. size + header]);
    }
};

/// Parse `json` with yyjson. `gpa` must stay valid (at the same address)
/// until `c.shim_json_free(handle)`: yyjson keeps the pointer.
fn jsonParse(gpa: *const Allocator, json: []const u8, diag: ?*JsonDiagnostics) DecodeError!ParsedJson {
    const alc: c.shim_alc = .{ .malloc = YyAlloc.alloc, .realloc = YyAlloc.realloc, .free = YyAlloc.free, .ctx = @constCast(gpa) };
    var d: c.shim_json_diag = undefined;
    var handle: ?*anyopaque = null;
    const ret = c.shim_json_parse(json.ptr, json.len, &alc, &d, &handle);
    if (ret < 0) {
        if (ret == -c.LITE3ZIG_E_JSON_SYNTAX) if (diag) |out| {
            out.* = .{ .code = d.code, .position = d.position, .message = if (d.message) |m| std.mem.span(m) else "" };
        };
        return mapDecodeStatus(ret);
    }
    return .{ .handle = handle, .size_hint = json.len };
}

fn mapDecodeStatus(ret: c_int) DecodeError {
    return switch (-ret) {
        c.LITE3ZIG_E_JSON_SYNTAX => error.SyntaxError,
        c.LITE3ZIG_E_JSON_NESTING => error.NestingTooDeep,
        c.LITE3ZIG_E_JSON_KEY => error.InvalidKey,
        c.LITE3ZIG_E_JSON_ROOT => error.InvalidRoot,
        c.LITE3ZIG_E_KEY_COLLISION => error.KeyCollision,
        c.LITE3ZIG_E_NO_SPACE => error.NoSpaceLeft,
        c.LITE3ZIG_E_NO_MEMORY => error.OutOfMemory,
        else => error.Unexpected,
    };
}

fn jsonConvert(doc: ParsedJson, mem: []align(4) u8, len: *usize) DecodeError!void {
    const ret = c.shim_json_convert(doc.handle, mem.ptr, len, mem.len);
    if (ret < 0) return mapDecodeStatus(ret);
}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

/// Checks in safe builds that a Document is always used with the same
/// allocator.
const GpaCheck = if (std.debug.runtime_safety) struct {
    ptr: *anyopaque,
    vtable: *const Allocator.VTable,

    fn of(gpa: Allocator) @This() {
        return .{ .ptr = gpa.ptr, .vtable = gpa.vtable };
    }

    fn check(self: @This(), gpa: Allocator) void {
        if (self.ptr != gpa.ptr or self.vtable != gpa.vtable)
            @panic("lite3.Document used with a different allocator than it was created with");
    }
} else struct {
    fn of(_: Allocator) @This() {
        return .{};
    }

    fn check(_: @This(), _: Allocator) void {}
};

/// A growable document. Pass the same allocator to every call that takes
/// one, and to `deinit` (checked in safe builds). Do not copy a Document by
/// value; use `clone`.
pub const Document = struct {
    storage: []align(4) u8,
    len: usize,
    epoch: u32 = 0,
    /// Growth beyond this many bytes fails with `error.NoSpaceLeft`.
    max_capacity: usize = capacity_limit,
    gpa_check: GpaCheck,

    pub const default_capacity = 1024;

    pub const Options = struct {
        root: Container = .object,
        initial_capacity: usize = default_capacity,
        /// Upper bound for growth (at most `capacity_limit`). Set it when
        /// the content comes from untrusted input.
        max_capacity: usize = capacity_limit,
    };

    /// An empty object or array.
    pub fn init(gpa: Allocator, root_type: Container) GrowError!Document {
        return initOptions(gpa, .{ .root = root_type });
    }

    pub fn initOptions(gpa: Allocator, options: Options) GrowError!Document {
        const max = @min(options.max_capacity, capacity_limit);
        if (max < node_size) return error.NoSpaceLeft;
        const cap = std.mem.alignForward(usize, @max(@min(options.initial_capacity, max), node_size), node_alignment);
        const storage = try gpa.alignedAlloc(u8, .@"4", @min(cap, max));
        var self: Document = .{ .storage = storage, .len = 0, .max_capacity = max, .gpa_check = .of(gpa) };
        self.reset(options.root);
        return self;
    }

    /// Copy `document` (serialized bytes) after `validate`.
    pub fn fromBytes(gpa: Allocator, document: []const u8) (ReadError || error{OutOfMemory})!Document {
        validate(document) catch return error.CorruptData;
        return fromBytesUnchecked(gpa, document);
    }

    /// Like `fromBytes` without validation; only for bytes this program
    /// produced itself.
    pub fn fromBytesUnchecked(gpa: Allocator, document: []const u8) error{OutOfMemory}!Document {
        const storage = try gpa.alignedAlloc(u8, .@"4", @max(document.len, node_size));
        @memcpy(storage[0..document.len], document);
        return .{ .storage = storage, .len = document.len, .gpa_check = .of(gpa) };
    }

    pub const JsonOptions = struct {
        max_capacity: usize = capacity_limit,
        diagnostics: ?*JsonDiagnostics = null,
    };

    /// Decode JSON into a new Document.
    pub fn fromJson(gpa: Allocator, json: []const u8, options: Document.JsonOptions) DecodeError!Document {
        comptime requireJson();
        const max = @min(options.max_capacity, capacity_limit);
        const gpa_copy = gpa;
        const parsed = try jsonParse(&gpa_copy, json, options.diagnostics);
        defer c.shim_json_free(parsed.handle);
        // lite3 documents run larger than their JSON; grow until it fits.
        var cap = std.mem.alignForward(usize, @min(@max(default_capacity, json.len *| 2), max), node_alignment);
        while (true) {
            const storage = try gpa.alignedAlloc(u8, .@"4", @min(cap, max));
            var len: usize = 0;
            jsonConvert(parsed, storage, &len) catch |err| {
                gpa.free(storage);
                if (err != error.NoSpaceLeft or cap >= max) return err;
                cap = @min(cap *| 2, max);
                continue;
            };
            return .{ .storage = storage, .len = len, .max_capacity = max, .gpa_check = .of(gpa) };
        }
    }

    pub fn deinit(self: *Document, gpa: Allocator) void {
        self.gpa_check.check(gpa);
        gpa.free(self.storage);
        self.* = undefined;
    }

    /// Read access. The View fails with `error.StaleView` after this
    /// Document is written to.
    pub fn view(self: *const Document) View {
        return .{ .bytes = self.storage[0..self.len], .epoch = &self.epoch, .epoch_seen = self.epoch };
    }

    /// The serialized document.
    pub fn slice(self: *const Document) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn capacity(self: *const Document) usize {
        return self.storage.len;
    }

    /// Make the document an empty object or array. Keeps the allocation.
    pub fn reset(self: *Document, root_type: Container) void {
        self.epoch +%= 1;
        var len: usize = 0;
        const ret = c.shim_init(self.storage.ptr, &len, self.storage.len, @backingInt(root_type));
        std.debug.assert(ret == 0); // storage always holds at least one node
        self.len = len;
    }

    /// Replace the content with a copy of `document` after `validate`. On
    /// failure the content is unchanged. `document` may be (part of) this
    /// Document's own bytes.
    pub fn importBytes(self: *Document, gpa: Allocator, document: []const u8) (ReadError || error{ OutOfMemory, NoSpaceLeft })!void {
        validate(document) catch return error.CorruptData;
        return self.importBytesUnchecked(gpa, document);
    }

    /// Like `importBytes` without validation.
    pub fn importBytesUnchecked(self: *Document, gpa: Allocator, document: []const u8) error{ OutOfMemory, NoSpaceLeft }!void {
        self.gpa_check.check(gpa);
        if (document.len > self.max_capacity) return error.NoSpaceLeft;
        self.epoch +%= 1;
        if (overlaps(self.storage, document) or document.len <= self.storage.len) {
            // Fits (own bytes always do): move in place.
            std.debug.assert(document.len <= self.storage.len);
            @memmove(self.storage[0..document.len], document);
        } else {
            const storage = try gpa.alignedAlloc(u8, .@"4", document.len);
            @memcpy(storage, document);
            gpa.free(self.storage);
            self.storage = storage;
        }
        self.len = document.len;
    }

    /// Replace the content with decoded JSON. On failure the content is
    /// unchanged (the result is built in new memory, then swapped in).
    pub fn decodeJson(self: *Document, gpa: Allocator, json: []const u8, diagnostics: ?*JsonDiagnostics) DecodeError!void {
        comptime requireJson();
        self.gpa_check.check(gpa);
        var new = try fromJson(gpa, json, .{ .max_capacity = self.max_capacity, .diagnostics = diagnostics });
        gpa.free(self.storage);
        self.storage = new.storage;
        self.len = new.len;
        self.epoch +%= 1;
        new = undefined;
    }

    /// Make room for `additional` more bytes.
    pub fn reserve(self: *Document, gpa: Allocator, additional: usize) GrowError!void {
        self.gpa_check.check(gpa);
        const needed = std.math.add(usize, self.len, additional) catch return error.NoSpaceLeft;
        if (needed <= self.storage.len) return;
        try self.grow(gpa, needed);
    }

    /// Release unused capacity.
    pub fn shrinkToFit(self: *Document, gpa: Allocator) error{OutOfMemory}!void {
        self.gpa_check.check(gpa);
        const target = std.mem.alignForward(usize, @max(self.len, node_size), node_alignment);
        if (target >= self.storage.len) return;
        try self.moveTo(gpa, target);
    }

    fn grow(self: *Document, gpa: Allocator, min_capacity: usize) GrowError!void {
        if (min_capacity > self.max_capacity or self.storage.len >= self.max_capacity) return error.NoSpaceLeft;
        const doubled = self.storage.len *| 2;
        const target = std.mem.alignForward(usize, @min(@max(min_capacity, doubled), self.max_capacity), node_alignment);
        try self.moveTo(gpa, @min(target, self.max_capacity));
    }

    /// Move the content into a new allocation of `new_capacity` bytes. Only
    /// the used bytes are copied.
    fn moveTo(self: *Document, gpa: Allocator, new_capacity: usize) error{OutOfMemory}!void {
        const storage = try gpa.alignedAlloc(u8, .@"4", new_capacity);
        @memcpy(storage[0..self.len], self.storage[0..self.len]);
        gpa.free(self.storage);
        self.storage = storage;
        self.epoch +%= 1;
    }

    fn raw(self: *Document) Raw {
        return .{ .mem = self.storage, .len = &self.len };
    }

    /// Resolve the key to a NUL-terminated pointer that stays valid across
    /// growth: borrowed if possible, else copied (stack, or heap if long).
    fn ownedKey(self: *const Document, gpa: Allocator, slot: Slot, stack: []u8, heap: *?[:0]u8) GrowError!?[*:0]const u8 {
        const k = switch (slot) {
            .key => |k| k,
            .index => return null,
        };
        if (k.z) |z| if (!overlaps(self.storage, k.bytes)) return z;
        if (k.bytes.len < stack.len) return stackKey(.{ .key = .{ .bytes = k.bytes, .hash = k.hash, .z = null } }, stack, &.{});
        const copy = try gpa.allocSentinel(u8, k.bytes.len, 0);
        @memcpy(copy, k.bytes);
        heap.* = copy;
        return copy.ptr;
    }

    fn write(self: *Document, gpa: Allocator, at: Offset, target: anytype, value: anytype) GrowError!void {
        self.gpa_check.check(gpa);
        const scalar = try Scalar.of(value);
        const slot = try writeSlot(self.view(), at, target);
        self.epoch +%= 1;
        var key_stack: [256]u8 = undefined;
        var key_heap: ?[:0]u8 = null;
        defer if (key_heap) |h| gpa.free(h);
        const z = try self.ownedKey(gpa, slot, &key_stack, &key_heap);

        // Copy a value that lies inside this Document aside: growth would
        // free it, and lite3 zeroes the old value on overwrite.
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        var stored = scalar;
        if (overlaps(self.storage, scalar.data())) {
            owned = try gpa.dupe(u8, scalar.data());
            stored = scalar.withData(owned.?);
        }

        const reserve_len = writeReserve(slot, try stored.payloadLen());
        try self.reserve(gpa, reserve_len);
        while (true) {
            self.raw().insertScalar(at, slot, z, stored) catch |err| switch (err) {
                // A failed write may have split nodes (still a valid
                // document); retrying with more room completes it.
                error.NoSpaceLeft => {
                    try self.grow(gpa, self.storage.len + 1);
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    fn writeContainer(self: *Document, gpa: Allocator, at: Offset, target: anytype, kind: Container) GrowError!Offset {
        self.gpa_check.check(gpa);
        const slot = try writeSlot(self.view(), at, target);
        self.epoch +%= 1;
        var key_stack: [256]u8 = undefined;
        var key_heap: ?[:0]u8 = null;
        defer if (key_heap) |h| gpa.free(h);
        const z = try self.ownedKey(gpa, slot, &key_stack, &key_heap);
        try self.reserve(gpa, writeReserve(slot, node_size));
        while (true) {
            return self.raw().insertContainer(at, slot, z, kind) catch |err| switch (err) {
                error.NoSpaceLeft => {
                    try self.grow(gpa, self.storage.len + 1);
                    continue;
                },
                else => return err,
            };
        }
    }

    /// Store `value` under key `k` in the object at `at` (see `Buffer.set`).
    pub fn set(self: *Document, gpa: Allocator, at: Offset, k: anytype, value: anytype) GrowError!void {
        return self.write(gpa, at, k, value);
    }

    pub fn setObject(self: *Document, gpa: Allocator, at: Offset, k: anytype) GrowError!Offset {
        return self.writeContainer(gpa, at, k, .object);
    }

    pub fn setArray(self: *Document, gpa: Allocator, at: Offset, k: anytype) GrowError!Offset {
        return self.writeContainer(gpa, at, k, .array);
    }

    pub fn append(self: *Document, gpa: Allocator, arr: Offset, value: anytype) GrowError!void {
        return self.write(gpa, arr, Append{}, value);
    }

    pub fn appendObject(self: *Document, gpa: Allocator, arr: Offset) GrowError!Offset {
        return self.writeContainer(gpa, arr, Append{}, .object);
    }

    pub fn appendArray(self: *Document, gpa: Allocator, arr: Offset) GrowError!Offset {
        return self.writeContainer(gpa, arr, Append{}, .array);
    }

    pub fn arrSet(self: *Document, gpa: Allocator, arr: Offset, index: u32, value: anytype) GrowError!void {
        return self.write(gpa, arr, ArrayIndex{ .index = index }, value);
    }

    pub fn arrSetObject(self: *Document, gpa: Allocator, arr: Offset, index: u32) GrowError!Offset {
        return self.writeContainer(gpa, arr, ArrayIndex{ .index = index }, .object);
    }

    pub fn arrSetArray(self: *Document, gpa: Allocator, arr: Offset, index: u32) GrowError!Offset {
        return self.writeContainer(gpa, arr, ArrayIndex{ .index = index }, .array);
    }

    /// A copy containing only live data: space left behind by overwrites is
    /// not copied.
    pub fn clone(self: *const Document, gpa: Allocator) (GrowError || ReadError)!Document {
        self.gpa_check.check(gpa);
        const v = self.view();
        var out = try initOptions(gpa, .{
            .root = try v.rootType(),
            .initial_capacity = self.len,
            .max_capacity = self.max_capacity,
        });
        errdefer out.deinit(gpa);
        try copyTree(gpa, v, &out);
        return out;
    }

    /// Rebuild the document to reclaim space left behind by overwrites.
    /// Offsets from before are invalid afterwards.
    pub fn compact(self: *Document, gpa: Allocator) (GrowError || ReadError)!void {
        var fresh = try self.clone(gpa);
        gpa.free(self.storage);
        self.storage = fresh.storage;
        self.len = fresh.len;
        self.epoch +%= 1;
        fresh = undefined;
    }
};

/// Copy every entry of `src` into the (empty) `dst`, iteratively.
fn copyTree(gpa: Allocator, src: View, dst: *Document) (GrowError || ReadError)!void {
    const Frame = struct {
        it: union(enum) { object: ObjectIterator, array: ArrayIterator },
        dst: Offset,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{
        .it = switch (try src.rootType()) {
            .object => .{ .object = try src.objectIterator(root) },
            .array => .{ .array = try src.arrayIterator(root) },
        },
        .dst = root,
    });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const at = top.dst;
        var key_bytes: ?[]const u8 = null;
        const value = switch (top.it) {
            .object => |*it| if (try it.next()) |e| blk: {
                key_bytes = e.key;
                break :blk e.value;
            } else null,
            .array => |*it| if (try it.next()) |e| e.value else null,
        } orelse {
            _ = stack.pop();
            continue;
        };
        switch (value) {
            .object, .array => |inner| {
                const kind: Container = if (value == .object) .object else .array;
                const new = if (key_bytes) |k|
                    try dst.writeContainer(gpa, at, k, kind)
                else
                    try dst.writeContainer(gpa, at, Append{}, kind);
                try stack.append(gpa, .{
                    .it = if (kind == .object) .{ .object = try src.objectIterator(inner) } else .{ .array = try src.arrayIterator(inner) },
                    .dst = new,
                });
            },
            else => {
                const scalar: Scalar = switch (value) {
                    .null => .null,
                    .bool => |b| .{ .bool = b },
                    .int => |i| .{ .int = i },
                    .float => |f| .{ .float = f },
                    .string => |str| .{ .string = str },
                    .bytes => |b| .{ .bytes = b },
                    .object, .array => unreachable,
                };
                if (key_bytes) |k| try dst.write(gpa, at, k, scalar) else try dst.write(gpa, at, Append{}, scalar);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// ManagedDocument
// ---------------------------------------------------------------------------

/// A `Document` that stores its allocator. Same operations without the
/// allocator argument.
pub const ManagedDocument = struct {
    gpa: Allocator,
    doc: Document,

    pub fn init(gpa: Allocator, root_type: Container) GrowError!ManagedDocument {
        return .{ .gpa = gpa, .doc = try .init(gpa, root_type) };
    }

    pub fn initOptions(gpa: Allocator, options: Document.Options) GrowError!ManagedDocument {
        return .{ .gpa = gpa, .doc = try .initOptions(gpa, options) };
    }

    pub fn fromBytes(gpa: Allocator, document: []const u8) (ReadError || error{OutOfMemory})!ManagedDocument {
        return .{ .gpa = gpa, .doc = try .fromBytes(gpa, document) };
    }

    pub fn fromBytesUnchecked(gpa: Allocator, document: []const u8) error{OutOfMemory}!ManagedDocument {
        return .{ .gpa = gpa, .doc = try .fromBytesUnchecked(gpa, document) };
    }

    pub fn fromJson(gpa: Allocator, json: []const u8, options: Document.JsonOptions) DecodeError!ManagedDocument {
        return .{ .gpa = gpa, .doc = try .fromJson(gpa, json, options) };
    }

    pub fn deinit(self: *ManagedDocument) void {
        self.doc.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn view(self: *const ManagedDocument) View {
        return self.doc.view();
    }

    pub fn slice(self: *const ManagedDocument) []const u8 {
        return self.doc.slice();
    }

    pub fn capacity(self: *const ManagedDocument) usize {
        return self.doc.capacity();
    }

    pub fn reset(self: *ManagedDocument, root_type: Container) void {
        self.doc.reset(root_type);
    }

    pub fn importBytes(self: *ManagedDocument, document: []const u8) (ReadError || error{ OutOfMemory, NoSpaceLeft })!void {
        return self.doc.importBytes(self.gpa, document);
    }

    pub fn importBytesUnchecked(self: *ManagedDocument, document: []const u8) error{ OutOfMemory, NoSpaceLeft }!void {
        return self.doc.importBytesUnchecked(self.gpa, document);
    }

    pub fn decodeJson(self: *ManagedDocument, json: []const u8, diagnostics: ?*JsonDiagnostics) DecodeError!void {
        return self.doc.decodeJson(self.gpa, json, diagnostics);
    }

    pub fn reserve(self: *ManagedDocument, additional: usize) GrowError!void {
        return self.doc.reserve(self.gpa, additional);
    }

    pub fn shrinkToFit(self: *ManagedDocument) error{OutOfMemory}!void {
        return self.doc.shrinkToFit(self.gpa);
    }

    pub fn set(self: *ManagedDocument, at: Offset, k: anytype, value: anytype) GrowError!void {
        return self.doc.set(self.gpa, at, k, value);
    }

    pub fn setObject(self: *ManagedDocument, at: Offset, k: anytype) GrowError!Offset {
        return self.doc.setObject(self.gpa, at, k);
    }

    pub fn setArray(self: *ManagedDocument, at: Offset, k: anytype) GrowError!Offset {
        return self.doc.setArray(self.gpa, at, k);
    }

    pub fn append(self: *ManagedDocument, arr: Offset, value: anytype) GrowError!void {
        return self.doc.append(self.gpa, arr, value);
    }

    pub fn appendObject(self: *ManagedDocument, arr: Offset) GrowError!Offset {
        return self.doc.appendObject(self.gpa, arr);
    }

    pub fn appendArray(self: *ManagedDocument, arr: Offset) GrowError!Offset {
        return self.doc.appendArray(self.gpa, arr);
    }

    pub fn arrSet(self: *ManagedDocument, arr: Offset, index: u32, value: anytype) GrowError!void {
        return self.doc.arrSet(self.gpa, arr, index, value);
    }

    pub fn arrSetObject(self: *ManagedDocument, arr: Offset, index: u32) GrowError!Offset {
        return self.doc.arrSetObject(self.gpa, arr, index);
    }

    pub fn arrSetArray(self: *ManagedDocument, arr: Offset, index: u32) GrowError!Offset {
        return self.doc.arrSetArray(self.gpa, arr, index);
    }

    pub fn clone(self: *const ManagedDocument) (GrowError || ReadError)!ManagedDocument {
        return .{ .gpa = self.gpa, .doc = try self.doc.clone(self.gpa) };
    }

    pub fn compact(self: *ManagedDocument) (GrowError || ReadError)!void {
        return self.doc.compact(self.gpa);
    }
};
