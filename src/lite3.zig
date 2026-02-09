// lite3-zig: Idiomatic Zig wrapper for the Lite3 serialization library
//
// Lite3 is a JSON-compatible zero-copy serialization format that encodes data
// as a B-tree inside a single contiguous buffer, allowing O(log n) access and
// mutation on any arbitrary field.
//
// Thread safety:
//   Buffer and Context are NOT thread-safe. Concurrent reads and writes to the
//   same instance require external synchronization (e.g. a Mutex). In particular:
//   - Slices returned by getStr/getBytes point into the buffer and are
//     invalidated by ANY subsequent mutation (including from another thread).
//   - For Context, mutations may trigger realloc, invalidating ALL prior slices.
//   - Iterators are invalidated by any mutation to the underlying buffer.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("lite3_build_options");

const c = @cImport({
    @cInclude("lite3_shim.h");
});

/// True when JSON conversion support is compiled in.
pub const json_enabled: bool = build_options.json_enabled;

comptime {
    if (builtin.target.cpu.arch.endian() == .big)
        @compileError("lite3 requires a little-endian target");
    if (builtin.target.os.tag == .windows)
        @compileError("lite3-zig does not yet support Windows (errno mapping is incomplete)");
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors returned by lite3 operations.
pub const Error = error{
    /// The key was not found in the object.
    NotFound,
    /// An invalid argument was provided (e.g. wrong type, null key).
    InvalidArgument,
    /// The buffer is too small to hold the data.
    NoBufferSpace,
    /// An unspecified lite3 error occurred.
    Unexpected,
    /// The generational pointer is stale (buffer was mutated since the
    /// reference was obtained).
    StaleReference,
    /// The buffer data is corrupt or malformed.
    CorruptData,
    /// Memory allocation failed (Context API only).
    OutOfMemory,
};

/// Translate a C return code (< 0 on error) into a Zig error.
/// The lite3 C library returns -1 and sets errno on failure.
fn translateError(ret: c_int) Error {
    std.debug.assert(ret < 0);
    const raw_errno = std.c._errno().*;
    // In debug builds, catch cases where C returned an error but forgot to set errno.
    std.debug.assert(raw_errno != 0);
    return mapErrno(raw_errno);
}

/// Translate the current errno value into a Zig error.
/// Used for C functions that signal failure via NULL return rather than a negative code.
fn translateErrno() Error {
    const raw_errno = std.c._errno().*;
    if (raw_errno == 0) return Error.Unexpected;
    return mapErrno(raw_errno);
}

/// Map a raw errno integer to a Zig error.
fn mapErrno(raw_errno: c_int) Error {
    const raw_u16 = std.math.cast(u16, raw_errno) orelse return Error.Unexpected;
    const e_val: std.posix.E = @enumFromInt(raw_u16);
    return switch (e_val) {
        .NOENT => Error.NotFound,
        .INVAL => Error.InvalidArgument,
        .NOBUFS, .MSGSIZE => Error.NoBufferSpace,
        .BADMSG => Error.CorruptData,
        .NOMEM => Error.OutOfMemory,
        .IO, .FAULT, .OVERFLOW => Error.Unexpected,
        else => Error.Unexpected,
    };
}

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Lite3 value types.
pub const Type = enum(u8) {
    null = 0,
    bool_ = 1,
    i64_ = 2,
    f64_ = 3,
    bytes = 4,
    string = 5,
    object = 6,
    array = 7,
    invalid = 8,

    const max_valid: u8 = 8;
};

/// A tagged union representing any Lite3 value, useful for dynamic access.
pub const Value = union(enum) {
    null,
    bool_: bool,
    i64_: i64,
    f64_: f64,
    string: []const u8,
    bytes: []const u8,
    object: Offset,
    array: Offset,
};

// ---------------------------------------------------------------------------
// Offset handle
// ---------------------------------------------------------------------------

/// A typed offset into a Lite3 buffer pointing to an object or array.
/// Using a distinct type prevents accidentally passing arbitrary `usize` values.
pub const Offset = enum(usize) {
    /// The root node is always at offset 0.
    root = 0,
    /// Catch-all for runtime offset values returned by C.
    _,
};

/// Convenience alias for `Offset.root`.
pub const root = Offset.root;

/// An opaque handle to a C-allocated JSON string.
/// Must be freed by calling `deinit()` exactly once.
pub const JsonString = struct {
    ptr: [*]u8,
    len: usize,

    /// Return the JSON content as a slice.
    pub fn slice(self: JsonString) []const u8 {
        return self.ptr[0..self.len];
    }

    /// Free the C-allocated JSON string. Must be called exactly once.
    pub fn deinit(self: JsonString) void {
        std.c.free(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Iterator (shared by Buffer and Context)
// ---------------------------------------------------------------------------

/// An iterator over the entries of a Lite3 object or array.
///
/// WARNING: The iterator captures the buffer pointer at creation time.
/// Any mutation to the underlying buffer (or Context reallocation) invalidates
/// the iterator. Do not mutate the buffer while iterating.
pub const Iterator = struct {
    raw: c.shim_lite3_iter,
    buf: [*]const u8,
    buflen: usize,

    pub const Entry = struct {
        /// The key string (null for array iterators).
        key: ?[]const u8,
        /// The byte offset of the value in the buffer.
        val_offset: Offset,
    };

    /// Get the next entry from the iterator.
    /// Returns null when iteration is complete.
    pub fn next(self: *Iterator) Error!?Entry {
        var key_ptr: ?[*]const u8 = null;
        var key_len: u32 = 0;
        var val_ofs: usize = 0;
        const ret = c.shim_lite3_iter_next(self.buf, self.buflen, &self.raw, @ptrCast(&key_ptr), &key_len, &val_ofs);
        if (ret == 1) return null; // DONE
        if (ret < 0) return translateError(ret);
        const entry_key: ?[]const u8 = if (key_ptr) |p| p[0..key_len] else null;
        return Entry{
            .key = entry_key,
            .val_offset = @enumFromInt(val_ofs),
        };
    }
};

// ---------------------------------------------------------------------------
// Shared method implementations (comptime mixin)
// ---------------------------------------------------------------------------

/// Shared method implementations for Buffer and Context.
/// This eliminates duplication by generating identical method signatures
/// that dispatch to the appropriate C functions based on the backend type.
fn SharedMethods(comptime Self: type) type {
    const is_ctx = (Self == Context);
    return struct {
        /// Maximum key length in bytes. Keys longer than this return InvalidArgument.
        const max_key_len: usize = 255;

        /// Convert a key slice to a null-terminated stack buffer for passing to C.
        /// Returns a fixed-size array that can be passed to C via `&kz`.
        inline fn toKeyZ(key: []const u8) Error![max_key_len + 1]u8 {
            if (key.len > max_key_len) return Error.InvalidArgument;
            var buf: [max_key_len + 1]u8 = undefined;
            @memcpy(buf[0..key.len], key);
            buf[key.len] = 0;
            return buf;
        }

        /// Save the current len for Buffer (no-op for Context).
        /// The C library documents that a failed write may still increment
        /// *inout_buflen, so we snapshot and restore to preserve invariants.
        inline fn saveLen(self: *Self) usize {
            return if (!is_ctx) self.len else 0;
        }

        /// Restore len on error for Buffer (no-op for Context).
        inline fn restoreLen(self: *Self, saved: usize) void {
            if (!is_ctx) self.len = saved;
        }

        // --- Set operations ---

        /// Set a null value for the given key.
        pub fn setNull(self: *Self, ofs: Offset, key: []const u8) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_null(self.ctx, @intFromEnum(ofs), &kz)
            else
                c.shim_lite3_set_null(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set a boolean value for the given key.
        pub fn setBool(self: *Self, ofs: Offset, key: []const u8, value: bool) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_bool(self.ctx, @intFromEnum(ofs), &kz, value)
            else
                c.shim_lite3_set_bool(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set an i64 value for the given key.
        pub fn setI64(self: *Self, ofs: Offset, key: []const u8, value: i64) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_i64(self.ctx, @intFromEnum(ofs), &kz, value)
            else
                c.shim_lite3_set_i64(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set an f64 value for the given key.
        pub fn setF64(self: *Self, ofs: Offset, key: []const u8, value: f64) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_f64(self.ctx, @intFromEnum(ofs), &kz, value)
            else
                c.shim_lite3_set_f64(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set a string value for the given key.
        pub fn setStr(self: *Self, ofs: Offset, key: []const u8, value: []const u8) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_str(self.ctx, @intFromEnum(ofs), &kz, value.ptr, value.len)
            else
                c.shim_lite3_set_str(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, value.ptr, value.len);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set a bytes value for the given key.
        pub fn setBytes(self: *Self, ofs: Offset, key: []const u8, value: []const u8) Error!void {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_bytes(self.ctx, @intFromEnum(ofs), &kz, value.ptr, value.len)
            else
                c.shim_lite3_set_bytes(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, value.ptr, value.len);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Set a nested object for the given key. Returns the offset of the new object.
        pub fn setObj(self: *Self, ofs: Offset, key: []const u8) Error!Offset {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_obj(self.ctx, @intFromEnum(ofs), &kz, &out_ofs)
            else
                c.shim_lite3_set_obj(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, &out_ofs);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
            return @enumFromInt(out_ofs);
        }

        /// Set a nested array for the given key. Returns the offset of the new array.
        pub fn setArr(self: *Self, ofs: Offset, key: []const u8) Error!Offset {
            var kz = try toKeyZ(key);
            const saved = saveLen(self);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_set_arr(self.ctx, @intFromEnum(ofs), &kz, &out_ofs)
            else
                c.shim_lite3_set_arr(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &kz, &out_ofs);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
            return @enumFromInt(out_ofs);
        }

        // --- Get operations ---

        /// Get the type of a value by key.
        pub fn getType(self: *const Self, ofs: Offset, key: []const u8) Error!Type {
            var kz = try toKeyZ(key);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_type(self.ctx, @intFromEnum(ofs), &kz)
            else
                c.shim_lite3_get_type(self.buf, self.len, @intFromEnum(ofs), &kz);
            if (ret < 0) return translateError(ret);
            if (ret > Type.max_valid) return Error.CorruptData;
            const t: Type = @enumFromInt(@as(u8, @intCast(ret)));
            if (t == .invalid) return Error.NotFound;
            return t;
        }

        /// Check if a key exists. Returns an error if the key conversion fails.
        pub fn exists(self: *const Self, ofs: Offset, key: []const u8) Error!bool {
            var kz = try toKeyZ(key);
            return if (is_ctx)
                c.shim_lite3_ctx_exists(self.ctx, @intFromEnum(ofs), &kz) != 0
            else
                c.shim_lite3_exists(self.buf, self.len, @intFromEnum(ofs), &kz) != 0;
        }

        /// Get a boolean value by key.
        pub fn getBool(self: *const Self, ofs: Offset, key: []const u8) Error!bool {
            var kz = try toKeyZ(key);
            var out: bool = false;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_bool(self.ctx, @intFromEnum(ofs), &kz, &out)
            else
                c.shim_lite3_get_bool(self.buf, self.len, @intFromEnum(ofs), &kz, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get an i64 value by key.
        pub fn getI64(self: *const Self, ofs: Offset, key: []const u8) Error!i64 {
            var kz = try toKeyZ(key);
            var out: i64 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_i64(self.ctx, @intFromEnum(ofs), &kz, &out)
            else
                c.shim_lite3_get_i64(self.buf, self.len, @intFromEnum(ofs), &kz, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get an f64 value by key.
        pub fn getF64(self: *const Self, ofs: Offset, key: []const u8) Error!f64 {
            var kz = try toKeyZ(key);
            var out: f64 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_f64(self.ctx, @intFromEnum(ofs), &kz, &out)
            else
                c.shim_lite3_get_f64(self.buf, self.len, @intFromEnum(ofs), &kz, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get a string value by key.
        /// WARNING: The returned slice points directly into the buffer and is
        /// invalidated by any subsequent mutation. For Context, auto-reallocation
        /// can cause use-after-free. Use `getStrCopy` for a safe alternative.
        pub fn getStr(self: *const Self, ofs: Offset, key: []const u8) Error![]const u8 {
            var kz = try toKeyZ(key);
            var out_ptr: ?[*]const u8 = null;
            var out_len: u32 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_str(self.ctx, @intFromEnum(ofs), &kz, @ptrCast(&out_ptr), &out_len)
            else
                c.shim_lite3_get_str(self.buf, self.len, @intFromEnum(ofs), &kz, @ptrCast(&out_ptr), &out_len);
            if (ret < 0) return translateError(ret);
            if (out_ptr) |p| return p[0..out_len];
            return Error.StaleReference;
        }

        /// Get a bytes value by key.
        /// WARNING: The returned slice points directly into the buffer and is
        /// invalidated by any subsequent mutation. For Context, auto-reallocation
        /// can cause use-after-free. Use `getBytesCopy` for a safe alternative.
        pub fn getBytes(self: *const Self, ofs: Offset, key: []const u8) Error![]const u8 {
            var kz = try toKeyZ(key);
            var out_ptr: ?[*]const u8 = null;
            var out_len: u32 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_bytes(self.ctx, @intFromEnum(ofs), &kz, &out_ptr, &out_len)
            else
                c.shim_lite3_get_bytes(self.buf, self.len, @intFromEnum(ofs), &kz, &out_ptr, &out_len);
            if (ret < 0) return translateError(ret);
            if (out_ptr) |p| return p[0..out_len];
            return Error.StaleReference;
        }

        /// Get a nested object offset by key.
        pub fn getObj(self: *const Self, ofs: Offset, key: []const u8) Error!Offset {
            var kz = try toKeyZ(key);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_obj(self.ctx, @intFromEnum(ofs), &kz, &out_ofs)
            else
                c.shim_lite3_get_obj(self.buf, self.len, @intFromEnum(ofs), &kz, &out_ofs);
            if (ret < 0) return translateError(ret);
            return @enumFromInt(out_ofs);
        }

        /// Get a nested array offset by key.
        pub fn getArr(self: *const Self, ofs: Offset, key: []const u8) Error!Offset {
            var kz = try toKeyZ(key);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_get_arr(self.ctx, @intFromEnum(ofs), &kz, &out_ofs)
            else
                c.shim_lite3_get_arr(self.buf, self.len, @intFromEnum(ofs), &kz, &out_ofs);
            if (ret < 0) return translateError(ret);
            return @enumFromInt(out_ofs);
        }

        /// Get a string value by key, copying into a caller-supplied buffer.
        /// Returns the copied slice. Safe to use even after buffer mutations.
        pub fn getStrCopy(self: *const Self, ofs: Offset, key: []const u8, dest: []u8) Error![]const u8 {
            const src = try self.getStr(ofs, key);
            if (src.len > dest.len) return Error.NoBufferSpace;
            @memcpy(dest[0..src.len], src);
            return dest[0..src.len];
        }

        /// Get a bytes value by key, copying into a caller-supplied buffer.
        /// Returns the copied slice. Safe to use even after buffer mutations.
        pub fn getBytesCopy(self: *const Self, ofs: Offset, key: []const u8, dest: []u8) Error![]const u8 {
            const src = try self.getBytes(ofs, key);
            if (src.len > dest.len) return Error.NoBufferSpace;
            @memcpy(dest[0..src.len], src);
            return dest[0..src.len];
        }

        // --- Array append operations ---

        /// Append a null value to an array.
        pub fn arrAppendNull(self: *Self, ofs: Offset) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_null(self.ctx, @intFromEnum(ofs))
            else
                c.shim_lite3_arr_append_null(self.buf, &self.len, @intFromEnum(ofs), self.capacity);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append a boolean value to an array.
        pub fn arrAppendBool(self: *Self, ofs: Offset, value: bool) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_bool(self.ctx, @intFromEnum(ofs), value)
            else
                c.shim_lite3_arr_append_bool(self.buf, &self.len, @intFromEnum(ofs), self.capacity, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append an i64 value to an array.
        pub fn arrAppendI64(self: *Self, ofs: Offset, value: i64) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_i64(self.ctx, @intFromEnum(ofs), value)
            else
                c.shim_lite3_arr_append_i64(self.buf, &self.len, @intFromEnum(ofs), self.capacity, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append an f64 value to an array.
        pub fn arrAppendF64(self: *Self, ofs: Offset, value: f64) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_f64(self.ctx, @intFromEnum(ofs), value)
            else
                c.shim_lite3_arr_append_f64(self.buf, &self.len, @intFromEnum(ofs), self.capacity, value);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append a string value to an array.
        pub fn arrAppendStr(self: *Self, ofs: Offset, value: []const u8) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_str(self.ctx, @intFromEnum(ofs), value.ptr, value.len)
            else
                c.shim_lite3_arr_append_str(self.buf, &self.len, @intFromEnum(ofs), self.capacity, value.ptr, value.len);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append a bytes value to an array.
        pub fn arrAppendBytes(self: *Self, ofs: Offset, value: []const u8) Error!void {
            const saved = saveLen(self);
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_bytes(self.ctx, @intFromEnum(ofs), value.ptr, value.len)
            else
                c.shim_lite3_arr_append_bytes(self.buf, &self.len, @intFromEnum(ofs), self.capacity, value.ptr, value.len);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
        }

        /// Append a nested object to an array. Returns the offset of the new object.
        pub fn arrAppendObj(self: *Self, ofs: Offset) Error!Offset {
            const saved = saveLen(self);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_obj(self.ctx, @intFromEnum(ofs), &out_ofs)
            else
                c.shim_lite3_arr_append_obj(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &out_ofs);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
            return @enumFromInt(out_ofs);
        }

        /// Append a nested array to an array. Returns the offset of the new array.
        pub fn arrAppendArr(self: *Self, ofs: Offset) Error!Offset {
            const saved = saveLen(self);
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_append_arr(self.ctx, @intFromEnum(ofs), &out_ofs)
            else
                c.shim_lite3_arr_append_arr(self.buf, &self.len, @intFromEnum(ofs), self.capacity, &out_ofs);
            if (ret < 0) {
                restoreLen(self, saved);
                return translateError(ret);
            }
            return @enumFromInt(out_ofs);
        }

        // --- Array get operations ---

        /// Get a boolean value from an array by index.
        pub fn arrGetBool(self: *const Self, ofs: Offset, index: u32) Error!bool {
            var out: bool = false;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_bool(self.ctx, @intFromEnum(ofs), index, &out)
            else
                c.shim_lite3_arr_get_bool(self.buf, self.len, @intFromEnum(ofs), index, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get an i64 value from an array by index.
        pub fn arrGetI64(self: *const Self, ofs: Offset, index: u32) Error!i64 {
            var out: i64 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_i64(self.ctx, @intFromEnum(ofs), index, &out)
            else
                c.shim_lite3_arr_get_i64(self.buf, self.len, @intFromEnum(ofs), index, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get an f64 value from an array by index.
        pub fn arrGetF64(self: *const Self, ofs: Offset, index: u32) Error!f64 {
            var out: f64 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_f64(self.ctx, @intFromEnum(ofs), index, &out)
            else
                c.shim_lite3_arr_get_f64(self.buf, self.len, @intFromEnum(ofs), index, &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Get a string value from an array by index.
        /// WARNING: The returned slice points directly into the buffer and is
        /// invalidated by any subsequent mutation. For Context, auto-reallocation
        /// can cause use-after-free. Use `arrGetStrCopy` for a safe alternative.
        pub fn arrGetStr(self: *const Self, ofs: Offset, index: u32) Error![]const u8 {
            var out_ptr: ?[*]const u8 = null;
            var out_len: u32 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_str(self.ctx, @intFromEnum(ofs), index, @ptrCast(&out_ptr), &out_len)
            else
                c.shim_lite3_arr_get_str(self.buf, self.len, @intFromEnum(ofs), index, @ptrCast(&out_ptr), &out_len);
            if (ret < 0) return translateError(ret);
            if (out_ptr) |p| return p[0..out_len];
            return Error.StaleReference;
        }

        /// Get a bytes value from an array by index.
        /// WARNING: The returned slice points directly into the buffer and is
        /// invalidated by any subsequent mutation. For Context, auto-reallocation
        /// can cause use-after-free. Use `arrGetBytesCopy` for a safe alternative.
        pub fn arrGetBytes(self: *const Self, ofs: Offset, index: u32) Error![]const u8 {
            var out_ptr: ?[*]const u8 = null;
            var out_len: u32 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_bytes(self.ctx, @intFromEnum(ofs), index, &out_ptr, &out_len)
            else
                c.shim_lite3_arr_get_bytes(self.buf, self.len, @intFromEnum(ofs), index, &out_ptr, &out_len);
            if (ret < 0) return translateError(ret);
            if (out_ptr) |p| return p[0..out_len];
            return Error.StaleReference;
        }

        /// Get a nested object offset from an array by index.
        pub fn arrGetObj(self: *const Self, ofs: Offset, index: u32) Error!Offset {
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_obj(self.ctx, @intFromEnum(ofs), index, &out_ofs)
            else
                c.shim_lite3_arr_get_obj(self.buf, self.len, @intFromEnum(ofs), index, &out_ofs);
            if (ret < 0) return translateError(ret);
            return @enumFromInt(out_ofs);
        }

        /// Get a nested array offset from an array by index.
        pub fn arrGetArr(self: *const Self, ofs: Offset, index: u32) Error!Offset {
            var out_ofs: usize = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_arr_get_arr(self.ctx, @intFromEnum(ofs), index, &out_ofs)
            else
                c.shim_lite3_arr_get_arr(self.buf, self.len, @intFromEnum(ofs), index, &out_ofs);
            if (ret < 0) return translateError(ret);
            return @enumFromInt(out_ofs);
        }

        /// Get the type of an array element by index.
        pub fn arrGetType(self: *const Self, ofs: Offset, index: u32) Error!Type {
            const t = if (is_ctx)
                c.shim_lite3_ctx_arr_get_type(self.ctx, @intFromEnum(ofs), index)
            else
                c.shim_lite3_arr_get_type(self.buf, self.len, @intFromEnum(ofs), index);
            if (t < 0) return translateError(t);
            if (t > Type.max_valid) return Error.CorruptData;
            const ret: Type = @enumFromInt(@as(u8, @intCast(t)));
            if (ret == .invalid) return Error.NotFound;
            return ret;
        }

        /// Get a string value from an array by index, copying into a caller-supplied buffer.
        /// Returns the copied slice. Safe to use even after buffer mutations.
        pub fn arrGetStrCopy(self: *const Self, ofs: Offset, index: u32, dest: []u8) Error![]const u8 {
            const src = try self.arrGetStr(ofs, index);
            if (src.len > dest.len) return Error.NoBufferSpace;
            @memcpy(dest[0..src.len], src);
            return dest[0..src.len];
        }

        /// Get a bytes value from an array by index, copying into a caller-supplied buffer.
        /// Returns the copied slice. Safe to use even after buffer mutations.
        pub fn arrGetBytesCopy(self: *const Self, ofs: Offset, index: u32, dest: []u8) Error![]const u8 {
            const src = try self.arrGetBytes(ofs, index);
            if (src.len > dest.len) return Error.NoBufferSpace;
            @memcpy(dest[0..src.len], src);
            return dest[0..src.len];
        }

        // --- Utility ---

        /// Return the number of entries in an object or elements in an array.
        pub fn count(self: *const Self, ofs: Offset) Error!u32 {
            var out: u32 = 0;
            const ret = if (is_ctx)
                c.shim_lite3_ctx_count(self.ctx, @intFromEnum(ofs), &out)
            else
                c.shim_lite3_count(self.buf, self.len, @intFromEnum(ofs), &out);
            if (ret < 0) return translateError(ret);
            return out;
        }

        /// Create an iterator over the entries at the given offset.
        ///
        /// WARNING: The iterator captures the buffer pointer at creation time.
        /// Any mutation (or Context reallocation) invalidates the iterator.
        pub fn iterate(self: *const Self, ofs: Offset) Error!Iterator {
            const buf_ptr: [*]const u8 = if (is_ctx) c.shim_lite3_ctx_buf(self.ctx) else self.buf;
            const buf_len: usize = if (is_ctx) c.shim_lite3_ctx_buflen(self.ctx) else self.len;
            var iter: c.shim_lite3_iter = undefined;
            const ret = c.shim_lite3_iter_create(buf_ptr, buf_len, @intFromEnum(ofs), &iter);
            if (ret < 0) return translateError(ret);
            return Iterator{
                .raw = iter,
                .buf = buf_ptr,
                .buflen = buf_len,
            };
        }

        // --- JSON ---

        /// Encode the buffer contents as a JSON string.
        /// The returned `JsonString` is allocated by the C library and must be freed with `.deinit()`.
        pub fn jsonEncode(self: *const Self, ofs: Offset) Error!JsonString {
            if (!json_enabled) return Error.InvalidArgument;
            const buf_ptr: [*]const u8 = if (is_ctx) c.shim_lite3_ctx_buf(self.ctx) else self.buf;
            const buf_len: usize = if (is_ctx) c.shim_lite3_ctx_buflen(self.ctx) else self.len;
            var out_len: usize = 0;
            std.c._errno().* = 0;
            const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc(buf_ptr, buf_len, @intFromEnum(ofs), &out_len));
            if (ptr) |p| return JsonString{ .ptr = p, .len = out_len };
            return translateErrno();
        }

        /// Encode the buffer contents as a pretty-printed JSON string.
        /// The returned `JsonString` is allocated by the C library and must be freed with `.deinit()`.
        pub fn jsonEncodePretty(self: *const Self, ofs: Offset) Error!JsonString {
            if (!json_enabled) return Error.InvalidArgument;
            const buf_ptr: [*]const u8 = if (is_ctx) c.shim_lite3_ctx_buf(self.ctx) else self.buf;
            const buf_len: usize = if (is_ctx) c.shim_lite3_ctx_buflen(self.ctx) else self.len;
            var out_len: usize = 0;
            std.c._errno().* = 0;
            const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc_pretty(buf_ptr, buf_len, @intFromEnum(ofs), &out_len));
            if (ptr) |p| return JsonString{ .ptr = p, .len = out_len };
            return translateErrno();
        }

        /// Get the value at the given key as a tagged union.
        /// WARNING: String and bytes slices point into the buffer; see getStr safety notes.
        pub fn getValue(self: *const Self, ofs: Offset, key: []const u8) Error!Value {
            const t = try self.getType(ofs, key);
            return switch (t) {
                .null => .null,
                .bool_ => .{ .bool_ = try self.getBool(ofs, key) },
                .i64_ => .{ .i64_ = try self.getI64(ofs, key) },
                .f64_ => .{ .f64_ = try self.getF64(ofs, key) },
                .string => .{ .string = try self.getStr(ofs, key) },
                .bytes => .{ .bytes = try self.getBytes(ofs, key) },
                .object => .{ .object = try self.getObj(ofs, key) },
                .array => .{ .array = try self.getArr(ofs, key) },
                .invalid => Error.Unexpected,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Buffer API
// ---------------------------------------------------------------------------

/// A Lite3 buffer backed by caller-supplied memory.
///
/// This wraps the lite3 "Buffer API" and provides an idiomatic Zig interface
/// with proper error handling and slice-based access.
pub const Buffer = struct {
    buf: [*]u8,
    len: usize,
    capacity: usize,

    // Import shared methods
    pub const setNull = SharedMethods(Buffer).setNull;
    pub const setBool = SharedMethods(Buffer).setBool;
    pub const setI64 = SharedMethods(Buffer).setI64;
    pub const setF64 = SharedMethods(Buffer).setF64;
    pub const setStr = SharedMethods(Buffer).setStr;
    pub const setBytes = SharedMethods(Buffer).setBytes;
    pub const setObj = SharedMethods(Buffer).setObj;
    pub const setArr = SharedMethods(Buffer).setArr;
    pub const getType = SharedMethods(Buffer).getType;
    pub const exists = SharedMethods(Buffer).exists;
    pub const getBool = SharedMethods(Buffer).getBool;
    pub const getI64 = SharedMethods(Buffer).getI64;
    pub const getF64 = SharedMethods(Buffer).getF64;
    pub const getStr = SharedMethods(Buffer).getStr;
    pub const getBytes = SharedMethods(Buffer).getBytes;
    pub const getObj = SharedMethods(Buffer).getObj;
    pub const getArr = SharedMethods(Buffer).getArr;
    pub const getStrCopy = SharedMethods(Buffer).getStrCopy;
    pub const getBytesCopy = SharedMethods(Buffer).getBytesCopy;
    pub const arrAppendNull = SharedMethods(Buffer).arrAppendNull;
    pub const arrAppendBool = SharedMethods(Buffer).arrAppendBool;
    pub const arrAppendI64 = SharedMethods(Buffer).arrAppendI64;
    pub const arrAppendF64 = SharedMethods(Buffer).arrAppendF64;
    pub const arrAppendStr = SharedMethods(Buffer).arrAppendStr;
    pub const arrAppendBytes = SharedMethods(Buffer).arrAppendBytes;
    pub const arrAppendObj = SharedMethods(Buffer).arrAppendObj;
    pub const arrAppendArr = SharedMethods(Buffer).arrAppendArr;
    pub const arrGetBool = SharedMethods(Buffer).arrGetBool;
    pub const arrGetI64 = SharedMethods(Buffer).arrGetI64;
    pub const arrGetF64 = SharedMethods(Buffer).arrGetF64;
    pub const arrGetStr = SharedMethods(Buffer).arrGetStr;
    pub const arrGetBytes = SharedMethods(Buffer).arrGetBytes;
    pub const arrGetObj = SharedMethods(Buffer).arrGetObj;
    pub const arrGetArr = SharedMethods(Buffer).arrGetArr;
    pub const arrGetType = SharedMethods(Buffer).arrGetType;
    pub const arrGetStrCopy = SharedMethods(Buffer).arrGetStrCopy;
    pub const arrGetBytesCopy = SharedMethods(Buffer).arrGetBytesCopy;
    pub const count = SharedMethods(Buffer).count;
    pub const iterate = SharedMethods(Buffer).iterate;
    pub const jsonEncode = SharedMethods(Buffer).jsonEncode;
    pub const jsonEncodePretty = SharedMethods(Buffer).jsonEncodePretty;
    pub const getValue = SharedMethods(Buffer).getValue;

    // Buffer-specific methods

    /// Initialize a new Lite3 buffer as an object.
    pub fn initObj(mem: []align(4) u8) Error!Buffer {
        var buflen: usize = 0;
        const ret = lite3_init_obj(mem.ptr, &buflen, mem.len);
        if (ret < 0) return translateError(ret);
        return Buffer{
            .buf = mem.ptr,
            .len = buflen,
            .capacity = mem.len,
        };
    }

    /// Initialize a new Lite3 buffer as an array.
    pub fn initArr(mem: []align(4) u8) Error!Buffer {
        var buflen: usize = 0;
        const ret = lite3_init_arr(mem.ptr, &buflen, mem.len);
        if (ret < 0) return translateError(ret);
        return Buffer{
            .buf = mem.ptr,
            .len = buflen,
            .capacity = mem.len,
        };
    }

    /// Return the underlying buffer as a slice of the used portion.
    pub fn data(self: *const Buffer) []const u8 {
        return self.buf[0..self.len];
    }

    /// Decode a JSON string into a buffer, reinitializing it.
    pub fn jsonDecode(mem: []align(4) u8, json: []const u8) Error!Buffer {
        if (!json_enabled) return Error.InvalidArgument;
        var buflen: usize = 0;
        const ret = c.shim_lite3_json_dec(mem.ptr, &buflen, mem.len, json.ptr, json.len);
        if (ret < 0) return translateError(ret);
        return Buffer{
            .buf = mem.ptr,
            .len = buflen,
            .capacity = mem.len,
        };
    }

    /// Encode the buffer contents as JSON into a caller-supplied buffer.
    /// Returns the number of bytes written.
    pub fn jsonEncodeBuf(self: *const Buffer, ofs: Offset, out: []u8) Error!usize {
        if (!json_enabled) return Error.InvalidArgument;
        const ret = c.shim_lite3_json_enc_buf(self.buf, self.len, @intFromEnum(ofs), out.ptr, out.len);
        if (ret < 0) return translateError(@intCast(ret));
        return @intCast(ret);
    }
};

// Extern declarations for the non-inline C functions
extern fn lite3_init_obj(buf: [*]u8, out_buflen: *usize, bufsz: usize) c_int;
extern fn lite3_init_arr(buf: [*]u8, out_buflen: *usize, bufsz: usize) c_int;

// ---------------------------------------------------------------------------
// Context API
// ---------------------------------------------------------------------------

/// A Lite3 context with automatic memory management.
///
/// This wraps the lite3 "Context API" where allocations are handled internally.
pub const Context = struct {
    ctx: *c.lite3_ctx,

    // Import shared methods
    pub const setNull = SharedMethods(Context).setNull;
    pub const setBool = SharedMethods(Context).setBool;
    pub const setI64 = SharedMethods(Context).setI64;
    pub const setF64 = SharedMethods(Context).setF64;
    pub const setStr = SharedMethods(Context).setStr;
    pub const setBytes = SharedMethods(Context).setBytes;
    pub const setObj = SharedMethods(Context).setObj;
    pub const setArr = SharedMethods(Context).setArr;
    pub const getType = SharedMethods(Context).getType;
    pub const exists = SharedMethods(Context).exists;
    pub const getBool = SharedMethods(Context).getBool;
    pub const getI64 = SharedMethods(Context).getI64;
    pub const getF64 = SharedMethods(Context).getF64;
    pub const getStr = SharedMethods(Context).getStr;
    pub const getBytes = SharedMethods(Context).getBytes;
    pub const getObj = SharedMethods(Context).getObj;
    pub const getArr = SharedMethods(Context).getArr;
    pub const getStrCopy = SharedMethods(Context).getStrCopy;
    pub const getBytesCopy = SharedMethods(Context).getBytesCopy;
    pub const arrAppendNull = SharedMethods(Context).arrAppendNull;
    pub const arrAppendBool = SharedMethods(Context).arrAppendBool;
    pub const arrAppendI64 = SharedMethods(Context).arrAppendI64;
    pub const arrAppendF64 = SharedMethods(Context).arrAppendF64;
    pub const arrAppendStr = SharedMethods(Context).arrAppendStr;
    pub const arrAppendBytes = SharedMethods(Context).arrAppendBytes;
    pub const arrAppendObj = SharedMethods(Context).arrAppendObj;
    pub const arrAppendArr = SharedMethods(Context).arrAppendArr;
    pub const arrGetBool = SharedMethods(Context).arrGetBool;
    pub const arrGetI64 = SharedMethods(Context).arrGetI64;
    pub const arrGetF64 = SharedMethods(Context).arrGetF64;
    pub const arrGetStr = SharedMethods(Context).arrGetStr;
    pub const arrGetBytes = SharedMethods(Context).arrGetBytes;
    pub const arrGetObj = SharedMethods(Context).arrGetObj;
    pub const arrGetArr = SharedMethods(Context).arrGetArr;
    pub const arrGetType = SharedMethods(Context).arrGetType;
    pub const arrGetStrCopy = SharedMethods(Context).arrGetStrCopy;
    pub const arrGetBytesCopy = SharedMethods(Context).arrGetBytesCopy;
    pub const count = SharedMethods(Context).count;
    pub const iterate = SharedMethods(Context).iterate;
    pub const jsonEncode = SharedMethods(Context).jsonEncode;
    pub const jsonEncodePretty = SharedMethods(Context).jsonEncodePretty;
    pub const getValue = SharedMethods(Context).getValue;

    // Context-specific methods

    /// Create a new context with default size.
    pub fn create() Error!Context {
        const ctx = c.shim_lite3_ctx_create();
        if (ctx == null) return Error.OutOfMemory;
        return Context{ .ctx = ctx.? };
    }

    /// Create a new context with a specific buffer size.
    pub fn createWithSize(bufsz: usize) Error!Context {
        const ctx = c.shim_lite3_ctx_create_with_size(bufsz);
        if (ctx == null) return Error.OutOfMemory;
        return Context{ .ctx = ctx.? };
    }

    /// Create a context by copying from an existing buffer.
    pub fn createFromBuf(buf: []const u8) Error!Context {
        const ctx = c.shim_lite3_ctx_create_from_buf(buf.ptr, buf.len);
        if (ctx == null) return Error.OutOfMemory;
        return Context{ .ctx = ctx.? };
    }

    /// Destroy the context, freeing all associated memory.
    /// After calling destroy, the Context is poisoned and must not be used again.
    /// In debug/safe builds, any subsequent use will trigger safety checks.
    pub fn destroy(self: *Context) void {
        c.shim_lite3_ctx_destroy(self.ctx);
        self.* = undefined;
    }

    /// Return the underlying buffer pointer.
    pub fn bufPtr(self: *const Context) [*]const u8 {
        return c.shim_lite3_ctx_buf(self.ctx);
    }

    /// Return the underlying buffer as a slice of the used portion.
    pub fn data(self: *const Context) []const u8 {
        const buf = c.shim_lite3_ctx_buf(self.ctx);
        const buflen = c.shim_lite3_ctx_buflen(self.ctx);
        return buf[0..buflen];
    }

    /// Initialize the context as an object.
    pub fn initObj(self: *Context) Error!void {
        const ret = c.shim_lite3_ctx_init_obj(self.ctx);
        if (ret < 0) return translateError(ret);
    }

    /// Initialize the context as an array.
    pub fn initArr(self: *Context) Error!void {
        const ret = c.shim_lite3_ctx_init_arr(self.ctx);
        if (ret < 0) return translateError(ret);
    }

    /// Decode a JSON string into this context.
    pub fn jsonDecode(self: *Context, json: []const u8) Error!void {
        if (!json_enabled) return Error.InvalidArgument;
        const ret = c.shim_lite3_ctx_json_dec(self.ctx, json.ptr, json.len);
        if (ret < 0) return translateError(ret);
    }

    /// Import data from an existing buffer into this context.
    pub fn importFromBuf(self: *Context, buf: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_import_from_buf(self.ctx, buf.ptr, buf.len);
        if (ret < 0) return translateError(ret);
    }
};
