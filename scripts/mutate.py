#!/usr/bin/env python3
"""Mutation test for lite3-zig.

Applies each hand-written mutant below to a copy of the repository and runs
`zig build test`; a mutant is killed if the suite fails. Usage:

    scripts/mutate.py            # all mutants
    scripts/mutate.py 3 17       # selected ones, by index

Known equivalent mutants (expected to survive): "no retry after NoSpaceLeft"
(growth doubles, so the reserve is never short), "shim: no verify_set" (the
Zig side checks the same conditions first), "json: nesting limit +1" (lite3's
decoder enforces the same limit).
"""
import os, shutil, subprocess, sys

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(SRC, '.zig-cache', 'mutate-repo')
ENV = dict(os.environ, PATH=os.path.expanduser('~/.local/bin') + ':' + os.environ['PATH'])

M = [
 ('src/lite3.zig', 'findHash <= hash', 'v.u32At(node + ofs_hashes + 4 * i) < hash) i += 1;', 'v.u32At(node + ofs_hashes + 4 * i) <= hash) i += 1;'),
 ('src/lite3.zig', 'keyAt skips NUL check', 'or !v.inBounds(start, size) or v.bytes[start + size - 1] != 0) return error.CorruptData;', 'or !v.inBounds(start, size)) return error.CorruptData;'),
 ('src/lite3.zig', 'lookup linear probing', 'const probe = k.hash +% @as(u32, @intCast(attempt * attempt));', 'const probe = k.hash +% @as(u32, @intCast(attempt));'),
 ('src/lite3.zig', 'lookup compares length only', 'if (std.mem.eql(u8, entry.key, k.bytes)) return entry.value_ofs;', 'if (entry.key.len == k.bytes.len) return entry.value_ofs;'),
 ('src/lite3.zig', 'lookupIndex off by one', 'if (index >= try v.count(arr)) return error.IndexOutOfBounds;', 'if (index > try v.count(arr)) return error.IndexOutOfBounds;'),
 ('src/lite3.zig', 'bool accepts 2', 'if (!v.inBounds(ofs, 2) or v.bytes[ofs + 1] > 1) return error.CorruptData;\n                return', 'if (!v.inBounds(ofs, 2) or v.bytes[ofs + 1] > 2) return error.CorruptData;\n                return'),
 ('src/lite3.zig', 'string size 0 accepted', 'if (n == 0 or data[n - 1] != 0) return error.CorruptData;', 'if (data[n - 1] != 0) return error.CorruptData;'),
 ('src/lite3.zig', 'container value alignment unchecked', 'if (ofs % node_alignment != 0 or !v.inBounds(ofs, node_size)) return error.CorruptData;\n                const o:', 'if (!v.inBounds(ofs, node_size)) return error.CorruptData;\n                const o:'),
 ('src/lite3.zig', 'walk not capped by count', '.remaining = @min(n, v.bytes.len) };', '.remaining = @max(n, v.bytes.len) };'),
 ('src/lite3.zig', 'walk remaining check removed', 'if (w.remaining == 0) return error.CorruptData;\n            w.remaining -= 1;', 'w.remaining -|= 1;'),
 ('src/lite3.zig', 'stale view never detected', 'if (v.epoch) |e| if (e.* != v.epoch_seen) return error.StaleView;', 'if (v.epoch) |e| if (e.* == v.epoch_seen +% 12345) return error.StaleView;'),
 ('src/lite3.zig', 'float without .0', 'if (std.mem.indexOfAny(u8, text, ".e") == null) try w.writeAll(".0");', ''),
 ('src/lite3.zig', 'newline escape dropped', "'\\n' => \"\\\\n\",", ''),
 ('src/lite3.zig', 'control chars below 0x10 only', 'if (escape == null and ch >= 0x20) continue;', 'if (escape == null and ch >= 0x10) continue;'),
 ('src/lite3.zig', 'encoder nesting limit +1', '.object => |o| {\n            if (depth > max_nesting_depth) return error.NestingTooDeep;', '.object => |o| {\n            if (depth > max_nesting_depth + 1) return error.NestingTooDeep;'),
 ('src/lite3.zig', 'int read without range check', '.int => |i| std.math.cast(T, i) orelse error.IntegerOverflow,', '.int => |i| std.math.cast(T, i) orelse 0,'),
 ('src/lite3.zig', 'NUL in key accepted', 'if (std.mem.indexOfScalar(u8, k.bytes, 0) != null) return error.InvalidKey;', ''),
 ('src/lite3.zig', 'arrSet allows index count+1', 'if (target.index > v.count(at) catch unreachable) return error.IndexOutOfBounds;', 'if (target.index > (v.count(at) catch unreachable) + 1) return error.IndexOutOfBounds;'),
 ('src/lite3.zig', 'aliasing value not copied (Buffer)', 'if (!overlaps(self.mem, scalar.data())) return self.raw().insertScalar(at, slot, z, scalar);', 'return self.raw().insertScalar(at, slot, z, scalar);'),
 ('src/lite3.zig', 'overlaps misses tail overlap', 'return d < m + mem.len and m < d + data.len;', 'return d >= m and d < m + mem.len;'),
 ('src/lite3.zig', 'aliasing key not copied', 'if (k.z) |z| if (!overlaps(doc, k.bytes)) return z;', 'if (k.z) |z| if (!overlaps(doc, k.bytes[0..0])) return z;'),
 ('src/lite3.zig', 'no retry after NoSpaceLeft', '''                error.NoSpaceLeft => {
                    try self.grow(gpa, self.storage.len + 1);
                    continue;
                },
                else => return err,
            };
            return;''', '''                else => return err,
            };
            return;'''),
 ('src/lite3.zig', 'max_capacity ignored', 'if (min_capacity > self.max_capacity or self.storage.len >= self.max_capacity) return error.NoSpaceLeft;', ''),
 ('src/lite3.zig', 'moveTo keeps epoch', '''        self.storage = storage;
        self.epoch +%= 1;
    }''', '''        self.storage = storage;
    }'''),
 ('src/lite3.zig', 'decodeJson leaks old storage', '''        gpa.free(self.storage);
        self.storage = new.storage;''', '''        self.storage = new.storage;'''),
 ('src/lite3.zig', 'string payload without NUL room', '.string => |str| if (str.len >= std.math.maxInt(u32)) error.ValueTooLarge else 4 + str.len + 1,', '.string => |str| if (str.len >= std.math.maxInt(u32)) error.ValueTooLarge else 4 + str.len,'),
 ('src/lite3.zig', 'bytes stored as string', '            .bytes => 4,\n            .string => 5,', '            .bytes => 5,\n            .string => 5,'),
 ('src/lite3.zig', 'Key hash ignored', 'if (T == Key) return .{ .bytes = k.str, .hash = k.hash, .z = k.str.ptr };', 'if (T == Key) return .{ .bytes = k.str, .hash = k.hash +% 1, .z = k.str.ptr };'),
 ('src/lite3.zig', 'shrinkToFit below len', 'const target = std.mem.alignForward(usize, @max(self.len, node_size), node_alignment);', 'const target = std.mem.alignForward(usize, node_size, node_alignment);'),
 ('src/validate.zig', 'validate: hashes not ordered', 'if (c.last_hash) |last| if (hash <= last) return error.CorruptData;', ''),
 ('src/validate.zig', 'validate: count mismatch ignored', 'if (c.seen != c.expected_count) return error.CorruptData;', ''),
 ('src/validate.zig', 'validate: array index hash', 'if (hash != c.seen) return error.CorruptData;', ''),
 ('src/validate.zig', 'validate: leaf/internal children', 'if ((w.u32At(ofs + ofs_child + 4 * i) != 0) != internal) return error.CorruptData;', 'if ((w.u32At(ofs + ofs_child + 4 * i) != 0) != internal and false) return error.CorruptData;'),
 ('src/validate.zig', 'validate: key NUL', 'if (bytes[bytes.len - 1] != 0) return error.CorruptData;', ''),
 ('src/validate.zig', 'validate: probe square', 'if (attempt >= hash_probe_max or attempt * attempt != delta) return error.CorruptData;', 'if (attempt >= hash_probe_max) return error.CorruptData;'),
 ('src/validate.zig', 'validate: bool byte', 'if (!w.inBounds(ofs, 2) or w.bytes[@intCast(ofs + 1)] > 1) return error.CorruptData;', 'if (!w.inBounds(ofs, 2)) return error.CorruptData;'),
 ('src/validate.zig', 'validate: shared bytes', 'if (claimed[i / 8] & mask != 0) return error.CorruptData;', ''),
 ('src/validate.zig', 'validate: nesting depth', 'if (w.stack_len == max_nesting_depth) return error.CorruptData;', 'if (w.stack_len == max_nesting_depth + 1) return error.CorruptData;'),
 ('src/lite3_shim.c', 'shim: ENOSPC as NO_SPACE', 'case ENOSPC: return LITE3ZIG_E_KEY_COLLISION;', 'case ENOSPC: return LITE3ZIG_E_NO_SPACE;'),
 ('src/lite3_shim.c', 'shim: no verify_set', '''    int ret = st(_lite3_verify_set(buf, inout_buflen, ofs, bufsz));
    if (ret < 0) return ret;
    lite3_key_data key_data = { .hash = hash, .size = key_size };
    lite3_val *val;''', '''    int ret;
    lite3_key_data key_data = { .hash = hash, .size = key_size };
    lite3_val *val;'''),
 ('src/lite3_json.c', 'json: nesting limit +1', 'if (yyjson_is_obj(val)) {\n        if (depth > LITE3_JSON_NESTING_DEPTH_MAX)', 'if (yyjson_is_obj(val)) {\n        if (depth > LITE3_JSON_NESTING_DEPTH_MAX + 1)'),
 ('src/lite3_json.c', 'json: NUL keys accepted', 'if (memchr(yyjson_get_str(key), 0, yyjson_get_len(key))) return -LITE3ZIG_E_JSON_KEY;', ''),
 ('src/lite3_json.c', 'json: scalar root accepted', '(yyjson_is_obj(root) || yyjson_is_arr(root)) ? json_precheck(root, 1) : -LITE3ZIG_E_JSON_ROOT', 'json_precheck(root, 1)'),
 ('src/lite3.zig', 'aliasing key not copied (Buffer fast path)', '    if (overlaps(doc, k.bytes)) return null;\n    return z;', '    if (overlaps(doc, k.bytes[0..0])) return null;\n    return z;'),
 ('src/lite3.zig', 'aliasing key not copied (Document)', 'if (k.z) |z| if (!overlaps(self.storage, k.bytes)) return z;', 'if (k.z) |z| if (!overlaps(self.storage, k.bytes[0..0])) return z;'),
 ('src/lite3.zig', 'aliasing value not copied (Document)', '''        if (overlaps(self.storage, scalar.data())) {
            owned = try gpa.dupe(u8, scalar.data());''', '''        if (false) {
            owned = try gpa.dupe(u8, scalar.data());'''),
 ('src/lite3.zig', 'compact keeps epoch', '''        self.len = fresh.len;
        self.epoch +%= 1;
        fresh = undefined;
    }
};''', '''        self.len = fresh.len;
        fresh = undefined;
    }
};'''),
]

def run(args, cwd):
    # New session so a timeout can kill zig and the test binary too.
    p = subprocess.Popen(args, cwd=cwd, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        p.communicate()
        raise
    return subprocess.CompletedProcess(args, p.returncode, out, '')

def main():
    only = sys.argv[1:]
    if os.path.exists(WORK): shutil.rmtree(WORK)
    shutil.copytree(SRC, WORK, ignore=shutil.ignore_patterns('.zig-cache', 'zig-out', '.git'))
    base = run(['mise', 'exec', '--', 'zig', 'build', 'test'], WORK)
    assert base.returncode == 0, base.stderr[-2000:]
    killed = survived = invalid = 0
    for i, (path, name, old, new) in enumerate(M):
        if only and str(i) not in only: continue
        p = os.path.join(WORK, path)
        text = open(p, newline='').read()
        if text.count(old) != 1:
            print(f'{i:2} INVALID (pattern x{text.count(old)}): {name}'); invalid += 1; continue
        open(p, 'w', newline='').write(text.replace(old, new))
        try:
            r = run(['mise', 'exec', '--', 'zig', 'build', 'test'], WORK)
            out = r.stdout + r.stderr
            if r.returncode == 0: status = 'SURVIVED'; survived += 1
            elif 'compilation error' in out:
                status = 'COMPILE-ERROR'; invalid += 1
            else: status = 'killed'; killed += 1
        except subprocess.TimeoutExpired:
            status = 'killed (timeout)'; killed += 1
        finally:
            open(p, 'w', newline='').write(text)
        print(f'{i:2} {status}: {name}', flush=True)
    total = killed + survived
    print(f'\nkilled {killed}/{total} ({100.0 * killed / max(total, 1):.0f}%), invalid {invalid}')

main()
