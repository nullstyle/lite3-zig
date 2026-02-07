// lite3-zig: Idiomatic Zig wrapper for the Lite³ serialization library
//
// Lite³ is a JSON-compatible zero-copy serialization format that encodes data
// as a B-tree inside a single contiguous buffer, allowing O(log n) access and
// mutation on any arbitrary field.

const std = @import("std");

pub const c = @cImport({
    @cInclude("lite3_shim.h");
});

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
};

/// Translate a C return code (< 0 on error) into a Zig error.
fn translateError(ret: c_int) Error {
    _ = ret;
    const e_val = std.c._errno().*;
    return switch (e_val) {
        2 => Error.NotFound, // ENOENT
        22 => Error.InvalidArgument, // EINVAL
        105 => Error.NoBufferSpace, // ENOBUFS
        else => Error.Unexpected,
    };
}

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Lite³ value types.
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
};

// ---------------------------------------------------------------------------
// Offset handle
// ---------------------------------------------------------------------------

/// An offset into a Lite³ buffer pointing to an object or array.
/// The root is always offset 0.
pub const Offset = usize;

/// Root offset constant.
pub const root: Offset = 0;

// ---------------------------------------------------------------------------
// Buffer API
// ---------------------------------------------------------------------------

/// A Lite³ buffer backed by caller-supplied memory.
///
/// This wraps the lite3 "Buffer API" and provides an idiomatic Zig interface
/// with proper error handling and slice-based access.
pub const Buffer = struct {
    buf: [*]u8,
    len: usize,
    capacity: usize,

    /// Initialize a new Lite³ buffer as an object.
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

    /// Initialize a new Lite³ buffer as an array.
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

    // ----- Set operations (object) -----

    /// Set a null value for the given key.
    pub fn setNull(self: *Buffer, ofs: Offset, key: [*:0]const u8) Error!void {
        const ret = c.shim_lite3_set_null(self.buf, &self.len, ofs, self.capacity, key);
        if (ret < 0) return translateError(ret);
    }

    /// Set a boolean value for the given key.
    pub fn setBool(self: *Buffer, ofs: Offset, key: [*:0]const u8, value: bool) Error!void {
        const ret = c.shim_lite3_set_bool(self.buf, &self.len, ofs, self.capacity, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set an i64 value for the given key.
    pub fn setI64(self: *Buffer, ofs: Offset, key: [*:0]const u8, value: i64) Error!void {
        const ret = c.shim_lite3_set_i64(self.buf, &self.len, ofs, self.capacity, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set an f64 value for the given key.
    pub fn setF64(self: *Buffer, ofs: Offset, key: [*:0]const u8, value: f64) Error!void {
        const ret = c.shim_lite3_set_f64(self.buf, &self.len, ofs, self.capacity, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set a string value for the given key.
    pub fn setStr(self: *Buffer, ofs: Offset, key: [*:0]const u8, value: []const u8) Error!void {
        const ret = c.shim_lite3_set_str(self.buf, &self.len, ofs, self.capacity, key, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Set a bytes value for the given key.
    pub fn setBytes(self: *Buffer, ofs: Offset, key: [*:0]const u8, value: []const u8) Error!void {
        const ret = c.shim_lite3_set_bytes(self.buf, &self.len, ofs, self.capacity, key, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Set a nested object for the given key. Returns the offset of the new object.
    pub fn setObj(self: *Buffer, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_set_obj(self.buf, &self.len, ofs, self.capacity, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Set a nested array for the given key. Returns the offset of the new array.
    pub fn setArr(self: *Buffer, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_set_arr(self.buf, &self.len, ofs, self.capacity, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Get operations (object) -----

    /// Get the type of a value by key.
    pub fn getType(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!Type {
        const ret = c.shim_lite3_get_type(self.buf, self.len, ofs, key);
        if (ret < 0) return translateError(ret);
        return @enumFromInt(@as(u8, @intCast(ret)));
    }

    /// Check if a key exists.
    pub fn exists(self: *const Buffer, ofs: Offset, key: [*:0]const u8) bool {
        return c.shim_lite3_exists(self.buf, self.len, ofs, key) != 0;
    }

    /// Get a boolean value by key.
    pub fn getBool(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!bool {
        var out: bool = false;
        const ret = c.shim_lite3_get_bool(self.buf, self.len, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an i64 value by key.
    pub fn getI64(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!i64 {
        var out: i64 = 0;
        const ret = c.shim_lite3_get_i64(self.buf, self.len, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an f64 value by key.
    pub fn getF64(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!f64 {
        var out: f64 = 0;
        const ret = c.shim_lite3_get_f64(self.buf, self.len, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get a string value by key. Returns the string slice directly.
    /// Note: The returned slice points into the buffer and is invalidated by mutations.
    pub fn getStr(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_get_str(self.buf, self.len, ofs, key, @ptrCast(&out_ptr), &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| {
            return p[0..out_len];
        }
        return Error.StaleReference;
    }

    /// Get a bytes value by key. Returns the byte slice directly.
    /// Note: The returned slice points into the buffer and is invalidated by mutations.
    pub fn getBytes(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_get_bytes(self.buf, self.len, ofs, key, &out_ptr, &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| {
            return p[0..out_len];
        }
        return Error.StaleReference;
    }

    /// Get a nested object offset by key.
    pub fn getObj(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_get_obj(self.buf, self.len, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Get a nested array offset by key.
    pub fn getArr(self: *const Buffer, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_get_arr(self.buf, self.len, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Array append operations -----

    /// Append a null value to an array.
    pub fn arrAppendNull(self: *Buffer, ofs: Offset) Error!void {
        const ret = c.shim_lite3_arr_append_null(self.buf, &self.len, ofs, self.capacity);
        if (ret < 0) return translateError(ret);
    }

    /// Append a boolean value to an array.
    pub fn arrAppendBool(self: *Buffer, ofs: Offset, value: bool) Error!void {
        const ret = c.shim_lite3_arr_append_bool(self.buf, &self.len, ofs, self.capacity, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append an i64 value to an array.
    pub fn arrAppendI64(self: *Buffer, ofs: Offset, value: i64) Error!void {
        const ret = c.shim_lite3_arr_append_i64(self.buf, &self.len, ofs, self.capacity, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append an f64 value to an array.
    pub fn arrAppendF64(self: *Buffer, ofs: Offset, value: f64) Error!void {
        const ret = c.shim_lite3_arr_append_f64(self.buf, &self.len, ofs, self.capacity, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append a string value to an array.
    pub fn arrAppendStr(self: *Buffer, ofs: Offset, value: []const u8) Error!void {
        const ret = c.shim_lite3_arr_append_str(self.buf, &self.len, ofs, self.capacity, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Append a bytes value to an array.
    pub fn arrAppendBytes(self: *Buffer, ofs: Offset, value: []const u8) Error!void {
        const ret = c.shim_lite3_arr_append_bytes(self.buf, &self.len, ofs, self.capacity, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Append a nested object to an array. Returns the offset of the new object.
    pub fn arrAppendObj(self: *Buffer, ofs: Offset) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_arr_append_obj(self.buf, &self.len, ofs, self.capacity, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Append a nested array to an array. Returns the offset of the new array.
    pub fn arrAppendArr(self: *Buffer, ofs: Offset) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_arr_append_arr(self.buf, &self.len, ofs, self.capacity, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Array get operations -----

    /// Get a boolean value from an array by index.
    pub fn arrGetBool(self: *const Buffer, ofs: Offset, index: u32) Error!bool {
        var out: bool = false;
        const ret = c.shim_lite3_arr_get_bool(self.buf, self.len, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an i64 value from an array by index.
    pub fn arrGetI64(self: *const Buffer, ofs: Offset, index: u32) Error!i64 {
        var out: i64 = 0;
        const ret = c.shim_lite3_arr_get_i64(self.buf, self.len, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an f64 value from an array by index.
    pub fn arrGetF64(self: *const Buffer, ofs: Offset, index: u32) Error!f64 {
        var out: f64 = 0;
        const ret = c.shim_lite3_arr_get_f64(self.buf, self.len, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get a string value from an array by index.
    pub fn arrGetStr(self: *const Buffer, ofs: Offset, index: u32) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_arr_get_str(self.buf, self.len, ofs, index, @ptrCast(&out_ptr), &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get a bytes value from an array by index.
    pub fn arrGetBytes(self: *const Buffer, ofs: Offset, index: u32) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_arr_get_bytes(self.buf, self.len, ofs, index, &out_ptr, &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get a nested object offset from an array by index.
    pub fn arrGetObj(self: *const Buffer, ofs: Offset, index: u32) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_arr_get_obj(self.buf, self.len, ofs, index, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Get a nested array offset from an array by index.
    pub fn arrGetArr(self: *const Buffer, ofs: Offset, index: u32) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_arr_get_arr(self.buf, self.len, ofs, index, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Get the type of an array element by index.
    pub fn arrGetType(self: *const Buffer, ofs: Offset, index: u32) Type {
        const t = c.shim_lite3_arr_get_type(self.buf, self.len, ofs, index);
        if (t < 0) return .invalid;
        return @enumFromInt(@as(u8, @intCast(t)));
    }

    // ----- Utility -----

    /// Return the number of entries in an object or elements in an array.
    pub fn count(self: *const Buffer, ofs: Offset) Error!u32 {
        var out: u32 = 0;
        const ret = c.shim_lite3_count(@constCast(self.buf), self.len, ofs, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    // ----- Iterator -----

    /// An iterator over the entries of a Lite³ object or array.
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
                .val_offset = val_ofs,
            };
        }
    };

    /// Create an iterator over the entries at the given offset.
    pub fn iterate(self: *const Buffer, ofs: Offset) Error!Iterator {
        var iter: c.shim_lite3_iter = undefined;
        const ret = c.shim_lite3_iter_create(self.buf, self.len, ofs, &iter);
        if (ret < 0) return translateError(ret);
        return Iterator{
            .raw = iter,
            .buf = self.buf,
            .buflen = self.len,
        };
    }

    // ----- JSON -----

    /// Decode a JSON string into a buffer, reinitializing it.
    pub fn jsonDecode(mem: []align(4) u8, json: []const u8) Error!Buffer {
        var buflen: usize = 0;
        const ret = c.shim_lite3_json_dec(mem.ptr, &buflen, mem.len, json.ptr, json.len);
        if (ret < 0) return translateError(ret);
        return Buffer{
            .buf = mem.ptr,
            .len = buflen,
            .capacity = mem.len,
        };
    }

    /// Encode the buffer contents as a JSON string.
    /// The returned slice is allocated by the C library and must be freed with `std.c.free`.
    pub fn jsonEncode(self: *const Buffer, ofs: Offset) Error![]const u8 {
        var out_len: usize = 0;
        const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc(self.buf, self.len, ofs, &out_len));
        if (ptr) |p| {
            return p[0..out_len];
        }
        return Error.Unexpected;
    }

    /// Encode the buffer contents as a pretty-printed JSON string.
    /// The returned slice is allocated by the C library and must be freed with `std.c.free`.
    pub fn jsonEncodePretty(self: *const Buffer, ofs: Offset) Error![]const u8 {
        var out_len: usize = 0;
        const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc_pretty(self.buf, self.len, ofs, &out_len));
        if (ptr) |p| {
            return p[0..out_len];
        }
        return Error.Unexpected;
    }

    /// Encode the buffer contents as JSON into a caller-supplied buffer.
    /// Returns the number of bytes written.
    pub fn jsonEncodeBuf(self: *const Buffer, ofs: Offset, out: []u8) Error!usize {
        const ret = c.shim_lite3_json_enc_buf(self.buf, self.len, ofs, out.ptr, out.len);
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

/// A Lite³ context with automatic memory management.
///
/// This wraps the lite3 "Context API" where allocations are handled internally.
pub const Context = struct {
    ctx: *c.lite3_ctx,

    /// Create a new context with default size.
    pub fn create() Error!Context {
        const ctx = c.shim_lite3_ctx_create();
        if (ctx == null) return Error.Unexpected;
        return Context{ .ctx = ctx.? };
    }

    /// Create a new context with a specific buffer size.
    pub fn createWithSize(bufsz: usize) Error!Context {
        const ctx = c.shim_lite3_ctx_create_with_size(bufsz);
        if (ctx == null) return Error.Unexpected;
        return Context{ .ctx = ctx.? };
    }

    /// Create a context by copying from an existing buffer.
    pub fn createFromBuf(buf: []const u8) Error!Context {
        const ctx = c.shim_lite3_ctx_create_from_buf(buf.ptr, buf.len);
        if (ctx == null) return Error.Unexpected;
        return Context{ .ctx = ctx.? };
    }

    /// Destroy the context, freeing all associated memory.
    pub fn destroy(self: *Context) void {
        c.shim_lite3_ctx_destroy(self.ctx);
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

    // ----- Set operations (object) -----

    /// Set a null value for the given key.
    pub fn setNull(self: *Context, ofs: Offset, key: [*:0]const u8) Error!void {
        const ret = c.shim_lite3_ctx_set_null(self.ctx, ofs, key);
        if (ret < 0) return translateError(ret);
    }

    /// Set a boolean value for the given key.
    pub fn setBool(self: *Context, ofs: Offset, key: [*:0]const u8, value: bool) Error!void {
        const ret = c.shim_lite3_ctx_set_bool(self.ctx, ofs, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set an i64 value for the given key.
    pub fn setI64(self: *Context, ofs: Offset, key: [*:0]const u8, value: i64) Error!void {
        const ret = c.shim_lite3_ctx_set_i64(self.ctx, ofs, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set an f64 value for the given key.
    pub fn setF64(self: *Context, ofs: Offset, key: [*:0]const u8, value: f64) Error!void {
        const ret = c.shim_lite3_ctx_set_f64(self.ctx, ofs, key, value);
        if (ret < 0) return translateError(ret);
    }

    /// Set a string value for the given key.
    pub fn setStr(self: *Context, ofs: Offset, key: [*:0]const u8, value: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_set_str(self.ctx, ofs, key, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Set a bytes value for the given key.
    pub fn setBytes(self: *Context, ofs: Offset, key: [*:0]const u8, value: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_set_bytes(self.ctx, ofs, key, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Set a nested object for the given key. Returns the offset of the new object.
    pub fn setObj(self: *Context, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_set_obj(self.ctx, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Set a nested array for the given key. Returns the offset of the new array.
    pub fn setArr(self: *Context, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_set_arr(self.ctx, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Get operations (object) -----

    /// Get the type of a value by key.
    pub fn getType(self: *const Context, ofs: Offset, key: [*:0]const u8) Type {
        const t = c.shim_lite3_ctx_get_type(self.ctx, ofs, key);
        if (t < 0) return .invalid;
        return @enumFromInt(@as(u8, @intCast(t)));
    }

    /// Check if a key exists.
    pub fn exists(self: *const Context, ofs: Offset, key: [*:0]const u8) bool {
        return c.shim_lite3_ctx_exists(self.ctx, ofs, key) != 0;
    }

    /// Get a boolean value by key.
    pub fn getBool(self: *const Context, ofs: Offset, key: [*:0]const u8) Error!bool {
        var out: bool = false;
        const ret = c.shim_lite3_ctx_get_bool(self.ctx, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an i64 value by key.
    pub fn getI64(self: *const Context, ofs: Offset, key: [*:0]const u8) Error!i64 {
        var out: i64 = 0;
        const ret = c.shim_lite3_ctx_get_i64(self.ctx, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an f64 value by key.
    pub fn getF64(self: *const Context, ofs: Offset, key: [*:0]const u8) Error!f64 {
        var out: f64 = 0;
        const ret = c.shim_lite3_ctx_get_f64(self.ctx, ofs, key, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get a string value by key. Returns the string slice directly.
    pub fn getStr(self: *const Context, ofs: Offset, key: [*:0]const u8) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_ctx_get_str(self.ctx, ofs, key, @ptrCast(&out_ptr), &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get a bytes value by key. Returns the byte slice directly.
    pub fn getBytes(self: *const Context, ofs: Offset, key: [*:0]const u8) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_ctx_get_bytes(self.ctx, ofs, key, &out_ptr, &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get a nested object offset by key.
    pub fn getObj(self: *const Context, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_get_obj(self.ctx, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Get a nested array offset by key.
    pub fn getArr(self: *const Context, ofs: Offset, key: [*:0]const u8) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_get_arr(self.ctx, ofs, key, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Array operations -----

    /// Append a null value to an array.
    pub fn arrAppendNull(self: *Context, ofs: Offset) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_null(self.ctx, ofs);
        if (ret < 0) return translateError(ret);
    }

    /// Append a boolean value to an array.
    pub fn arrAppendBool(self: *Context, ofs: Offset, value: bool) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_bool(self.ctx, ofs, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append an i64 value to an array.
    pub fn arrAppendI64(self: *Context, ofs: Offset, value: i64) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_i64(self.ctx, ofs, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append an f64 value to an array.
    pub fn arrAppendF64(self: *Context, ofs: Offset, value: f64) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_f64(self.ctx, ofs, value);
        if (ret < 0) return translateError(ret);
    }

    /// Append a string value to an array.
    pub fn arrAppendStr(self: *Context, ofs: Offset, value: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_str(self.ctx, ofs, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Append a bytes value to an array.
    pub fn arrAppendBytes(self: *Context, ofs: Offset, value: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_arr_append_bytes(self.ctx, ofs, value.ptr, value.len);
        if (ret < 0) return translateError(ret);
    }

    /// Append a nested object to an array. Returns the offset of the new object.
    pub fn arrAppendObj(self: *Context, ofs: Offset) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_arr_append_obj(self.ctx, ofs, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Append a nested array to an array. Returns the offset of the new array.
    pub fn arrAppendArr(self: *Context, ofs: Offset) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_arr_append_arr(self.ctx, ofs, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Array get operations -----

    /// Get a boolean from an array by index.
    pub fn arrGetBool(self: *const Context, ofs: Offset, index: u32) Error!bool {
        var out: bool = false;
        const ret = c.shim_lite3_ctx_arr_get_bool(self.ctx, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an i64 from an array by index.
    pub fn arrGetI64(self: *const Context, ofs: Offset, index: u32) Error!i64 {
        var out: i64 = 0;
        const ret = c.shim_lite3_ctx_arr_get_i64(self.ctx, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get an f64 from an array by index.
    pub fn arrGetF64(self: *const Context, ofs: Offset, index: u32) Error!f64 {
        var out: f64 = 0;
        const ret = c.shim_lite3_ctx_arr_get_f64(self.ctx, ofs, index, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Get a string from an array by index.
    pub fn arrGetStr(self: *const Context, ofs: Offset, index: u32) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_ctx_arr_get_str(self.ctx, ofs, index, @ptrCast(&out_ptr), &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get bytes from an array by index.
    pub fn arrGetBytes(self: *const Context, ofs: Offset, index: u32) Error![]const u8 {
        var out_ptr: ?[*]const u8 = null;
        var out_len: u32 = 0;
        const ret = c.shim_lite3_ctx_arr_get_bytes(self.ctx, ofs, index, &out_ptr, &out_len);
        if (ret < 0) return translateError(ret);
        if (out_ptr) |p| return p[0..out_len];
        return Error.StaleReference;
    }

    /// Get a nested object offset from an array by index.
    pub fn arrGetObj(self: *const Context, ofs: Offset, index: u32) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_arr_get_obj(self.ctx, ofs, index, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    /// Get a nested array offset from an array by index.
    pub fn arrGetArr(self: *const Context, ofs: Offset, index: u32) Error!Offset {
        var out_ofs: usize = 0;
        const ret = c.shim_lite3_ctx_arr_get_arr(self.ctx, ofs, index, &out_ofs);
        if (ret < 0) return translateError(ret);
        return out_ofs;
    }

    // ----- Utility -----

    /// Return the number of entries in an object or elements in an array.
    pub fn count(self: *const Context, ofs: Offset) Error!u32 {
        var out: u32 = 0;
        const ret = c.shim_lite3_ctx_count(self.ctx, ofs, &out);
        if (ret < 0) return translateError(ret);
        return out;
    }

    /// Create an iterator over the entries at the given offset.
    pub fn iterate(self: *const Context, ofs: Offset) Error!Buffer.Iterator {
        const buf = c.shim_lite3_ctx_buf(self.ctx);
        const buflen = c.shim_lite3_ctx_buflen(self.ctx);
        var iter: c.shim_lite3_iter = undefined;
        const ret = c.shim_lite3_iter_create(buf, buflen, ofs, &iter);
        if (ret < 0) return translateError(ret);
        return Buffer.Iterator{
            .raw = iter,
            .buf = buf,
            .buflen = buflen,
        };
    }

    // ----- JSON -----

    /// Decode a JSON string into this context.
    pub fn jsonDecode(self: *Context, json: []const u8) Error!void {
        const buf = c.shim_lite3_ctx_buf(self.ctx);
        var buflen = c.shim_lite3_ctx_buflen(self.ctx);
        const bufsz = c.shim_lite3_ctx_bufsz(self.ctx);
        const ret = c.shim_lite3_json_dec(buf, &buflen, bufsz, json.ptr, json.len);
        if (ret < 0) return translateError(ret);
        // Note: buflen is updated but we can't set ctx->buflen from Zig.
        // For JSON decode on context, use createFromBuf with a buffer decoded from Buffer.jsonDecode.
    }

    /// Encode the context contents as a JSON string.
    /// The returned slice is allocated by the C library and must be freed with `std.c.free`.
    pub fn jsonEncode(self: *const Context, ofs: Offset) Error![]const u8 {
        const buf = c.shim_lite3_ctx_buf(self.ctx);
        const buflen = c.shim_lite3_ctx_buflen(self.ctx);
        var out_len: usize = 0;
        const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc(buf, buflen, ofs, &out_len));
        if (ptr) |p| {
            return p[0..out_len];
        }
        return Error.Unexpected;
    }

    /// Encode the context contents as a pretty-printed JSON string.
    /// The returned slice is allocated by the C library and must be freed with `std.c.free`.
    pub fn jsonEncodePretty(self: *const Context, ofs: Offset) Error![]const u8 {
        const buf = c.shim_lite3_ctx_buf(self.ctx);
        const buflen = c.shim_lite3_ctx_buflen(self.ctx);
        var out_len: usize = 0;
        const ptr: ?[*]u8 = @ptrCast(c.shim_lite3_json_enc_pretty(buf, buflen, ofs, &out_len));
        if (ptr) |p| {
            return p[0..out_len];
        }
        return Error.Unexpected;
    }

    /// Import data from an existing buffer into this context.
    pub fn importFromBuf(self: *Context, buf: []const u8) Error!void {
        const ret = c.shim_lite3_ctx_import_from_buf(self.ctx, buf.ptr, buf.len);
        if (ret < 0) return translateError(ret);
    }
};
