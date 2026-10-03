//! Structural validation of a serialized lite3 document.
//!
//! `validate` checks every invariant the lite3 C library relies on, so that a
//! document received from an untrusted source can afterwards be read (and
//! written) through the normal API without out-of-bounds access, unbounded
//! work, or inconsistent results. It is written in Zig so it can be fuzzed
//! directly, allocates nothing, and does not recurse.
//!
//! Format summary (see vendor/lite3/src/lite3.c):
//! - A container (object or array) is a B-tree of 96-byte, 4-aligned nodes:
//!   `gen_type: u32` (low byte: type), `hashes: [7]u32`, `size_kc: u32`
//!   (high 26 bits: element count, kept in the container's root node only;
//!   low 3 bits: keys in this node), `kv_ofs: [7]u32`, `child_ofs: [8]u32`.
//!   The document root container starts at offset 0.
//! - Keys in a container are ordered by hash. Object hashes are the DJB2 hash
//!   of the key plus a quadratic probe offset (`attempt * attempt`, attempt <
//!   128); array hashes are the element index.
//! - An object entry is a key tag (1, 2 or 4 bytes: `size << 2 | (tag_len-1)`),
//!   the key bytes including a NUL terminator, then the value. An array entry
//!   is just the value.
//! - A value is a type byte followed by its payload: nothing (null), 1 byte
//!   (bool), 8 bytes (i64, f64), or a u32 length plus bytes (bytes; string,
//!   whose length includes a NUL terminator). A nested object or array value
//!   *is* the 96-byte root node of that container, so it must be 4-aligned.

const std = @import("std");

pub const Error = error{CorruptData};

/// Maximum nesting of containers accepted by `validate` (the document root is
/// depth 1). lite3 itself has no nesting limit, but its JSON conversion stops
/// at 32 levels; this bounds the validator's fixed-size stack.
pub const max_nesting_depth = 64;

const node_size = 96;
const node_alignment = 4;
/// lite3 rejects walks of more than this many child links within a container.
const tree_height_max = 9;
const key_count_max = 7;
const hash_probe_max = 128;
const djb2_seed: u32 = 5381;

const type_object = 6;
const type_array = 7;

const ofs_hashes = 4;
const ofs_size_kc = 32;
const ofs_kv = 36;
const ofs_child = 64;

/// Position within one B-tree node during an in-order walk: even `pos` 2j
/// visits child j (internal nodes only), odd `pos` 2j+1 visits key j.
const Cursor = struct {
    ofs: u32,
    key_count: u8,
    internal: bool,
    pos: u8 = 0,
};

const Container = struct {
    root: u32,
    type: u8,
    expected_count: u32,
    seen: u32 = 0,
    last_hash: ?u32 = null,
    depth: u8 = 0,
    path: [tree_height_max + 1]Cursor = undefined,
};

const Walker = struct {
    bytes: []const u8,
    /// Bytes of nodes and entries visited so far. A well-formed document
    /// never visits a byte twice, so this cannot exceed `bytes.len`;
    /// exceeding it means shared or cyclic structure.
    budget: u64 = 0,
    /// One bit per document byte, set when a node or entry claims it
    /// (`validateStrict` only).
    claimed: ?[]u8 = null,
    stack: [max_nesting_depth]Container = undefined,
    stack_len: usize = 0,

    /// Account for the `n` bytes at `ofs` being part of a node or entry.
    fn charge(w: *Walker, ofs: u64, n: u64) Error!void {
        w.budget += n;
        if (w.budget > w.bytes.len) return error.CorruptData;
        const claimed = w.claimed orelse return;
        // In bounds, so the range fits in usize on 32-bit targets too.
        if (!w.inBounds(ofs, n)) return error.CorruptData;
        const start: usize = @intCast(ofs);
        for (start..start + @as(usize, @intCast(n))) |i| {
            const mask = @as(u8, 1) << @intCast(i % 8);
            if (claimed[i / 8] & mask != 0) return error.CorruptData;
            claimed[i / 8] |= mask;
        }
    }

    fn inBounds(w: *const Walker, ofs: u64, len: u64) bool {
        return ofs <= w.bytes.len and len <= w.bytes.len - ofs;
    }

    const run = runWalker;

    fn u32At(w: *const Walker, ofs: u64) u32 {
        return std.mem.readInt(u32, w.bytes[@intCast(ofs)..][0..4], .little);
    }

    /// Check a node's header and return a cursor positioned at its start.
    fn openNode(w: *Walker, ofs: u64, container_type: u8) Error!Cursor {
        if (ofs % node_alignment != 0 or !w.inBounds(ofs, node_size)) return error.CorruptData;
        try w.charge(ofs, node_size);
        if (w.bytes[@intCast(ofs)] != container_type) return error.CorruptData;

        const kc: u8 = @intCast(w.u32At(ofs + ofs_size_kc) & 0x7);
        const internal = w.u32At(ofs + ofs_child) != 0;
        // Internal nodes have a child on both sides of every key. Leaves have
        // none at all: lite3 creates every node with all 8 child slots zero,
        // and its iterator descends wherever child_ofs[i] != 0. A stray
        // pointer past the key count would become live once an insert raises
        // the count, so it is rejected too. (Internal nodes may legitimately
        // keep stale pointers past their key count; lite3 overwrites those
        // before it reads them.)
        const checked: usize = if (internal) @as(usize, kc) + 1 else key_count_max + 1;
        for (0..checked) |i| {
            if ((w.u32At(ofs + ofs_child + 4 * i) != 0) != internal) return error.CorruptData;
        }
        if (internal and kc == 0) return error.CorruptData;
        return .{ .ofs = @intCast(ofs), .key_count = kc, .internal = internal };
    }

    fn openContainer(w: *Walker, ofs: u64, container_type: u8) Error!void {
        if (w.stack_len == max_nesting_depth) return error.CorruptData;
        const root = try w.openNode(ofs, container_type);
        w.stack[w.stack_len] = .{
            .root = @intCast(ofs),
            .type = container_type,
            .expected_count = w.u32At(ofs + ofs_size_kc) >> 6,
        };
        w.stack[w.stack_len].path[0] = root;
        w.stack_len += 1;
    }

    /// Advance the innermost container by one step.
    fn step(w: *Walker) Error!void {
        const c = &w.stack[w.stack_len - 1];
        const cur = &c.path[c.depth];

        if (cur.pos > 2 * @as(usize, cur.key_count)) {
            // Node finished.
            if (c.depth > 0) {
                c.depth -= 1;
                return;
            }
            if (c.seen != c.expected_count) return error.CorruptData;
            w.stack_len -= 1;
            return;
        }

        const pos = cur.pos;
        cur.pos += 1;
        if (pos % 2 == 0) {
            if (!cur.internal) return;
            const child = w.u32At(@as(u64, cur.ofs) + ofs_child + 2 * @as(u64, pos));
            if (c.depth == tree_height_max) return error.CorruptData;
            const next = try w.openNode(child, c.type);
            c.depth += 1;
            c.path[c.depth] = next;
            return;
        }

        const j = pos / 2;
        const hash = w.u32At(@as(u64, cur.ofs) + ofs_hashes + 4 * @as(u64, j));
        const kv = w.u32At(@as(u64, cur.ofs) + ofs_kv + 4 * @as(u64, j));

        if (c.type == type_array) {
            if (hash != c.seen) return error.CorruptData;
        } else {
            if (c.last_hash) |last| if (hash <= last) return error.CorruptData;
            c.last_hash = hash;
        }
        c.seen += 1;
        if (c.seen > c.expected_count) return error.CorruptData;

        const value_ofs = if (c.type == type_object) try w.key(c.root, kv, hash) else kv;
        try w.value(value_ofs);
    }

    /// Decode the key entry at `kv`: returns the key bytes including the NUL
    /// terminator and the length of the tag.
    fn keyAt(w: *const Walker, kv: u64) Error!struct { bytes: []const u8, tag_len: u64 } {
        if (!w.inBounds(kv, 1)) return error.CorruptData;
        const tag_len: u64 = (w.bytes[@intCast(kv)] & 0x3) + 1;
        if (!w.inBounds(kv, tag_len)) return error.CorruptData;
        var tag: u32 = 0;
        for (0..@intCast(tag_len)) |i| tag |= @as(u32, w.bytes[@intCast(kv + i)]) << @intCast(8 * i);
        const key_size: u64 = tag >> 2; // includes the NUL terminator

        // lite3 compares tag sizes on lookup, so only the canonical size works.
        const canonical: u64 = 1 + @as(u64, @intFromBool(key_size >= 1 << 6)) + 2 * @as(u64, @intFromBool(key_size >= 1 << 14));
        if (key_size == 0 or tag_len != canonical) return error.CorruptData;

        const key_ofs = kv + tag_len;
        if (!w.inBounds(key_ofs, key_size)) return error.CorruptData;
        const bytes = w.bytes[@intCast(key_ofs)..@intCast(key_ofs + key_size)];
        if (bytes[bytes.len - 1] != 0) return error.CorruptData;
        return .{ .bytes = bytes, .tag_len = tag_len };
    }

    /// Search one container for `hash` the way lite3_get_impl does and
    /// return the kv offset, or null. Nodes on the path may not have been
    /// validated yet, so every read is bounds-checked.
    fn findHash(w: *const Walker, root: u32, hash: u32) Error!?u64 {
        var node: u64 = root;
        var walks: usize = 0;
        while (true) {
            if (node % node_alignment != 0 or !w.inBounds(node, node_size)) return error.CorruptData;
            const kc = w.u32At(node + ofs_size_kc) & 0x7;
            var i: u64 = 0;
            while (i < kc and w.u32At(node + ofs_hashes + 4 * i) < hash) i += 1;
            if (i < kc and w.u32At(node + ofs_hashes + 4 * i) == hash) return w.u32At(node + ofs_kv + 4 * i);
            if (w.u32At(node + ofs_child) == 0) return null;
            walks += 1;
            if (walks > tree_height_max) return error.CorruptData;
            node = w.u32At(node + ofs_child + 4 * i);
        }
    }

    /// Check an object key entry and return the offset of its value.
    fn key(w: *Walker, container_root: u32, kv: u64, hash: u32) Error!u64 {
        const k = try w.keyAt(kv);
        const key_bytes = k.bytes;
        const tag_len = k.tag_len;
        const key_ofs = kv + tag_len;
        const key_size: u64 = key_bytes.len;

        var h = djb2_seed;
        for (key_bytes[0 .. key_bytes.len - 1]) |b| {
            if (b == 0) return error.CorruptData; // lookups stop at the first NUL
            h = (h << 5) +% h +% b;
        }
        // The stored hash must be where lite3's lookup finds this key: it
        // probes h + i*i for i = 0, 1, ... and only moves on from slot i when
        // that slot holds a *different* key. Otherwise the key would be
        // listed by iteration but not found by get (or be a duplicate).
        const delta = hash -% h;
        const attempt: u32 = std.math.sqrt(delta);
        if (attempt >= hash_probe_max or attempt * attempt != delta) return error.CorruptData;
        for (0..attempt) |i| {
            const probe = h +% @as(u32, @intCast(i * i));
            const other_kv = try w.findHash(container_root, probe) orelse return error.CorruptData;
            const other = try w.keyAt(other_kv);
            if (std.mem.eql(u8, other.bytes, key_bytes)) return error.CorruptData;
        }

        try w.charge(kv, tag_len + key_size);
        return key_ofs + key_size;
    }

    fn value(w: *Walker, ofs: u64) Error!void {
        if (!w.inBounds(ofs, 1)) return error.CorruptData;
        const t = w.bytes[@intCast(ofs)];
        switch (t) {
            0 => try w.charge(ofs, 1), // null
            1 => { // bool, loaded as C _Bool
                if (!w.inBounds(ofs, 2) or w.bytes[@intCast(ofs + 1)] > 1) return error.CorruptData;
                try w.charge(ofs, 2);
            },
            2, 3 => { // i64, f64
                if (!w.inBounds(ofs, 9)) return error.CorruptData;
                try w.charge(ofs, 9);
            },
            4, 5 => { // bytes, string
                if (!w.inBounds(ofs, 5)) return error.CorruptData;
                const n: u64 = w.u32At(ofs + 1);
                if (!w.inBounds(ofs + 5, n)) return error.CorruptData;
                if (t == 5 and (n == 0 or w.bytes[@intCast(ofs + 5 + n - 1)] != 0)) return error.CorruptData;
                try w.charge(ofs, 5 + n);
            },
            type_object, type_array => try w.openContainer(ofs, t),
            else => return error.CorruptData,
        }
    }
};

/// Check that `bytes` is a well-formed lite3 document (root container at
/// offset 0, `bytes.len` = used length). Runs in time linear in `bytes.len`,
/// allocates nothing and uses about 6 KiB of stack.
///
/// Guarantees reading and writing the document through the lite3 API stays
/// in bounds and does bounded work, and that every entry is well-formed and
/// reachable. Structure sharing that fits inside the document's dead space
/// (bytes left behind by overwrites) is not detected; see `validateStrict`.
pub fn validate(bytes: []const u8) Error!void {
    var w: Walker = .{ .bytes = bytes };
    return w.run();
}

/// Like `validate`, and additionally proves that no byte belongs to more
/// than one node or entry. A document that passes stays valid under any
/// sequence of lite3 writes. Needs `bytes.len / 8` bytes of scratch memory.
pub fn validateStrict(gpa: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!void {
    const claimed = try gpa.alloc(u8, std.math.divCeil(usize, bytes.len, 8) catch unreachable);
    defer gpa.free(claimed);
    @memset(claimed, 0);
    var w: Walker = .{ .bytes = bytes, .claimed = claimed };
    return w.run();
}

fn runWalker(w: *Walker) Error!void {
    const bytes = w.bytes;
    if (!w.inBounds(0, node_size)) return error.CorruptData;
    const t = bytes[0];
    if (t != type_object and t != type_array) return error.CorruptData;
    try w.openContainer(0, t);
    while (w.stack_len > 0) try w.step();
}
