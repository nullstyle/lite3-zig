# Reproduction tests from the 2026-10-01 review

Each entry below is a minimal test from the independent reproduction pass for one critical or high finding. It **fails on commit `b7cb2b9`** and should pass once the fix lands.
Phase 0/1 of `PRODUCTION_READINESS_PLAN.md` adopts these tests into `src/tests.zig`. Some tests assume a scratch `repro` build step; the header comment of each test describes it.

## MEM-1 — saveLen/restoreLen rolls back buflen after the C library has already split a node, corrupting the document; ManagedContext/ExternalContext fail after about 40-100 array appends
Reproduced: **True** · severity after repro: **critical** · same root cause: CSH-2, ALC-1, TST-1, ALC-9

```zig
// Scratch harness: repro-0/repo/src/repro_tests.zig, wired into build.zig with a `repro` step and a -Drfilter option:
//   const repro_mod = b.createModule(.{ .root_source_file = b.path("src/repro_tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "lite3", .module = zig_mod }} });
//   const rf = b.option([]const u8, "rfilter", "repro filter");
//   const repro_tests = b.addTest(.{ .root_module = repro_mod, .use_llvm = true, .filters = if (rf) |f| b.dupeStrings(&.{f}) else &.{} });
//   b.step("repro", "").dependOn(&b.addRunArtifact(repro_tests).step);
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "MEM-1 Buffer: failed write must not orphan split nodes" {
    var big: [8192]u8 align(4) = undefined;
    var b0 = try lite3.Buffer.initObj(&big);
    var kb: [8]u8 = undefined;
    for (0..7) |i| try b0.setI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @intCast(i));
    const base = b0.len;
    var cap: usize = std.mem.alignForward(usize, base, 4);
    var failures: usize = 0;
    while (cap < base + 600) : (cap += 4) {
        var mem: [8192]u8 align(4) = undefined;
        var b = try lite3.Buffer.initObj(mem[0..cap]);
        for (0..7) |i| try b.setI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @intCast(i));
        var val: [300]u8 = @splat('v');
        b.setStr(lite3.root, "big", &val) catch |e| {
            try testing.expectEqual(lite3.Error.NoBufferSpace, e);
            for (0..7) |i| {
                const got = b.getI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i})) catch { failures += 1; continue; };
                try testing.expectEqual(@as(i64, @intCast(i)), got);
            }
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "MEM-1 ManagedContext: nested array appends survive growth" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    const arr = try ctx.setArr(lite3.root, "items");
    var s: [64]u8 = @splat('s');
    for (0..500) |_| try ctx.arrAppendStr(arr, &s);
    try testing.expectEqual(@as(u32, 500), try ctx.count(arr));
}

test "MEM-1 ManagedContext: nested i64 appends survive growth" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    const arr = try ctx.setArr(lite3.root, "items");
    for (0..5000) |i| try ctx.arrAppendI64(arr, @intCast(i));
    for (0..5000) |i| try testing.expectEqual(@as(i64, @intCast(i)), try ctx.arrGetI64(arr, @intCast(i)));
}

test "MEM-1 ExternalContext: 7 keys then large value keeps keys readable" {
    const a = testing.allocator;
    var ctx = try lite3.ExternalContext.init(a);
    defer ctx.deinit(a);
    var kb: [8]u8 = undefined;
    for (0..7) |i| try ctx.setI64(a, lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @intCast(i));
    var val: [2000]u8 = @splat('v');
    try ctx.setStr(a, lite3.root, "big", &val);
    for (0..7) |i| try testing.expectEqual(@as(i64, @intCast(i)), try ctx.getI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
}
```

<details><summary>Output on b7cb2b9</summary>

```
zig build repro -Drfilter=MEM-1 (Debug; ReleaseFast gives the same result):
MEM-1 Buffer cap=380 len=187: k0 -> Unexpected   (also k1,k2,k4,k5,k6; the same holds for every cap from 380 to ~560. 468 unreadable-key lines in total)
'MEM-1 ManagedContext: nested array appends survive growth' failed: MEM-1 Managed arrAppendStr failed at #39: Unexpected
'MEM-1 ManagedContext: nested i64 appends survive growth' failed: MEM-1 Managed arrAppendI64 failed at #99: Unexpected
'MEM-1 ExternalContext: 7 keys then large value keeps keys readable' failed: MEM-1 External setStr(2000B) -> Unexpected; len=187 cap=4096

With restoreLen made a no-op (repro-0/fixed): all 4 tests pass in Debug and ReleaseFast. The existing suite still passes 117/117, which shows that tests.zig 'mutation rollback preserves buffer length on NoBufferSpace' never reaches the split path.
```
</details>

**Fix sketch:** src/lite3.zig:229-239: delete saveLen/restoreLen, and remove every `const saved = saveLen(self)` / `restoreLen(self, saved)` pair in SharedMethods set*/arrAppend* (about 16 call sites). The C library then owns len: after NoBufferSpace, len may have grown by up to 2*96 bytes of valid split nodes, as the upstream contract allows. callWithGrowth in ManagedContext (1181-1192) and ExternalContext (1529-1545) then works unchanged. Update the doc comments on Buffer setters to say 'on NoBufferSpace, len may increase; the document remains valid'. Replace tests.zig:1377 ('mutation rollback preserves buffer length') with the four tests above and add ExternalContext nested-append variants. No public API signature change. Behaviour change: after a failed Buffer write, len may be larger than before. Files: src/lite3.zig, src/tests.zig.

## MEM-2 — Iterator.Entry.key uses the raw key tag as its length, so key slices are about 4x too long and read past the end of the buffer
Reproduced: **True** · severity after repro: **critical** · same root cause: CSH-1, API-1, TST-2, SEC-1

```zig
test "MEM-2 iterator key slice equals inserted key" {
    var mem: [1024]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    try b.setI64(lite3.root, "hello", 1);
    var it = try b.iterate(lite3.root);
    const e = (try it.next()).?;
    try testing.expectEqualStrings("hello", e.key.?);
}

test "MEM-2 iterator key of last entry stays within data()" {
    var mem: [1024]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    try b.setNull(lite3.root, "a" ** 47);
    var it = try b.iterate(lite3.root);
    const e = (try it.next()).?;
    const end = @intFromPtr(e.key.?.ptr) + e.key.?.len;
    try testing.expect(end <= @intFromPtr(b.data().ptr) + b.data().len);
}

// Regression test for after the fix (tag-size boundaries):
test "MEM-2c iterator keys across tag-size boundary" {
    var mem: [16384]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    var kb: [255]u8 = undefined;
    const lens = [_]usize{ 1, 62, 63, 64, 100, 255 };
    for (lens) |l| { @memset(kb[0..l], @intCast('a' + l % 26)); try b.setNull(lite3.root, kb[0..l]); }
    var it = try b.iterate(lite3.root);
    var n: usize = 0;
    while (try it.next()) |e| : (n += 1) {
        const k = e.key.?;
        try testing.expect(std.mem.indexOfScalar(usize, &lens, k.len) != null);
        try testing.expectEqual(@as(u8, @intCast('a' + k.len % 26)), k[0]);
        try testing.expectEqual(@as(u8, 0), k.ptr[k.len]);
    }
    try testing.expectEqual(lens.len, n);
}
```

<details><summary>Output on b7cb2b9</summary>

```
'MEM-2 iterator key slice equals inserted key' failed: MEM-2 key.len=23 bytes={ 104, 101, 108, 108, 111, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 170, 170, 170, 170, 170, 170, 170, 170 }
  expected: hello  found: hello\0\x02\x01...\xAA\xAA (0xAA = undefined stack bytes past buf.len)
'MEM-2 iterator key of last entry stays within data()' failed: MEM-2 key.len=191, key end - data end = 142

With the shim fix (repro-0/fixed): key.len=5 bytes={104,101,108,108,111}; key.len=47, key end - data end = -2; MEM-2c passes for key lengths 1/62/63/64/100/255; the full suite passes 117/117.
```
</details>

**Fix sketch:** The root cause is vendor/lite3/src/lite3.c:401-406 (lite3_iter_next copies the raw tag (size<<2)|(tag_size-1) into out_key->len, then subtracts 1 without shifting), passed through at src/lite3_shim.c:284 and sliced at src/lite3.zig:185. Minimal fix, validated: in shim_lite3_iter_next, `*key_len = ((key.len + 1u) >> 2) - 1u; /* tag=(size<<2)|(tag_size-1), size incl. NUL */`. Add a comment plus a _Static_assert or test that pins the shift of 2, because LITE3_KEY_TAG_KEY_SIZE_SHIFT is private to lite3.c. A cleaner option is to patch lite3_iter_next in the vendored C (`out_key->len = (tag >> LITE3_KEY_TAG_KEY_SIZE_SHIFT) - 1`), record it as a local patch, and report it upstream. If you do that, remove the shim arithmetic so the length is not corrected twice. Optional hardening: debug-assert key_ptr+key_len < buf+buflen and key_ptr[key_len]==0. Files: src/lite3_shim.c (or vendor/lite3/src/lite3.c) and src/tests.zig. No API change.

## MEM-3 — shim_lite3_iter_next reads an uninitialised lite3_str, so array iterators can return a stale non-null key
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-4, SEC-10, OPS-1

```zig
test "MEM-3b array iterator after inline object iterator step" {
    var mem: [1024]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    const arr = try b.setArr(lite3.root, "arr");
    try b.arrAppendI64(arr, 1);
    try b.arrAppendI64(arr, 2);
    var oit = try b.iterate(lite3.root);
    _ = try oit.next();
    var it = try b.iterate(arr);
    while (try it.next()) |e| try testing.expect(e.key == null);
}
// Fails natively in ReleaseFast and ReleaseSafe. In Debug it passes natively (the stack slot happens to be 0),
// but valgrind flags it in every mode (run: zig build install -Dcpu=baseline -Drfilter=MEM-3 && valgrind --error-exitcode=9 zig-out/bin/test).
```

<details><summary>Output on b7cb2b9</summary>

```
ReleaseFast: 1/1 ...MEM-3b array entry key = arr\nFAIL (TestUnexpectedResult)
ReleaseSafe: 1/1 ...MEM-3b array entry key = arr\nFAIL (TestUnexpectedResult)
Debug native: OK
valgrind (Debug and ReleaseFast, -Dcpu=baseline):
==27355== Conditional jump or move depends on uninitialised value(s)
==27355==    at 0x1116121: shim_lite3_iter_next (lite3_shim.c:279)
==27355==    by 0x103A396: lite3.Iterator.next (lite3.zig:182)
==27355== Conditional jump or move depends on uninitialised value(s)
==27355==    at 0x103A40D: lite3.Iterator.next (lite3.zig:185)
With `lite3_str key = {0};` (repro-0/fixed): both MEM-3 tests pass in Debug and ReleaseFast.
```
</details>

**Fix sketch:** src/lite3_shim.c:275: `lite3_str key = {0};`. lite3_iter_next writes out_key only for OBJECT nodes (lite3.c:403), so for arrays the zeroed ptr gives key=null. This fix is validated. Optional hardening: record the container type in Iterator at iterate() time and force key=null for arrays. Add the MEM-3b test to tests.zig and add a valgrind or -fsanitize=memory CI job so the test catches the bug in Debug too. One-line change, no API impact.

## MEM-4 — Passing a slice of the same document as the value of setStr/setBytes/arrAppend* causes use-after-free on growth and silent data destruction on in-place overwrite
Reproduced: **True** · severity after repro: **critical** · same root cause: CSH-5

```zig
test "MEM-4 ManagedContext: copy field from same document across growth" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    var v: [600]u8 = undefined;
    for (&v, 0..) |*x, i| x.* = @intCast('a' + i % 26);
    try ctx.setStr(lite3.root, "a", &v);
    try ctx.setStr(lite3.root, "b", try ctx.getStr(lite3.root, "a"));
    try testing.expectEqualStrings(&v, try ctx.getStr(lite3.root, "b"));
}

test "MEM-4 Buffer: in-place overwrite with subslice of own value" {
    var mem: [1024]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    const orig = "0123456789abcdefghijklmnopqrstuvwxyzABCD";
    try b.setStr(lite3.root, "a", orig);
    try b.setStr(lite3.root, "a", (try b.getStr(lite3.root, "a"))[4..]);
    try testing.expectEqualStrings(orig[4..], try b.getStr(lite3.root, "a"));
}

// Passes natively by luck; fails under valgrind:
test "MEM-4 Context: copy field from same document across C growth" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetObj();
    var v: [600]u8 = @splat('q');
    try ctx.setStr(lite3.root, "a", &v);
    try ctx.setStr(lite3.root, "b", try ctx.getStr(lite3.root, "a"));
    try testing.expectEqualStrings(&v, try ctx.getStr(lite3.root, "b"));
}
```

<details><summary>Output on b7cb2b9</summary>

```
ManagedContext (Debug native): Segmentation fault at address 0x7fbcc0460068 ... test runner terminated with signal 6 (the testing allocator unmapped the old storage and the retry memcpy's from it).
Buffer: 'MEM-4 Buffer: in-place overwrite with subslice of own value' failed: MEM-4 Buffer got={ 0, 0, 0, 0, 0, 0, 0, 0 }  (value zeroed by the LITE3_ZERO_MEM_DELETED memset before the overlapping copy)
Context under valgrind (Debug): Invalid read of size 16 ... by _lite3_ctx_set_str_n_impl (lite3_context_api.h:578) by shim_lite3_ctx_set_str (lite3_shim.c:331) by lite3.SharedMethods(lite3.Context).setStr (lite3.zig:309) ... Address 0x4a78108 is 104 bytes inside a block of size 1,024 free'd
Context under valgrind (ReleaseFast): Invalid read of size 1 at memmove ... free'd at free by lite3_ctx_grow_impl (ctx_api.c:187)
```
</details>

**Fix sketch:** In SharedMethods setStr/setBytes/arrAppendStr/arrAppendBytes (src/lite3.zig:304-331, 574-599), before calling C, test whether value overlaps the document's backing range: [buf, buf+capacity) for Buffer, which also covers Managed/External through inner, and [ctx_buf, ctx_buf+bufsz) for Context via a new shim accessor shim_lite3_ctx_bufsz. If it overlaps, copy the value first: std.heap.stackFallback(256, allocator) for Managed/External, a stack buffer or std.c.malloc for Buffer/Context. Always copy on overlap. Pre-reserving capacity alone does not fix the in-place case, because the C code memsets the old value slot before memcpy (lite3.c ~714). Because ManagedContext/ExternalContext.callWithGrowth retry with the same args, do the copy in the Managed/External forwarders before callWithGrowth, so the copied slice outlives realloc. Files: src/lite3.zig, src/lite3_shim.c/.h, src/tests.zig. No public signature change; a small cost from the overlap check (two pointer compares).

## MEM-5 — Iterators capture a raw buffer pointer and length, so next() after Context/ManagedContext/ExternalContext growth reads freed memory (the C generation check itself dereferences it)
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-6, API-5

```zig
test "MEM-5 ManagedContext: iterator next() after growth must fail cleanly" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setI64(lite3.root, "x", 1);
    try ctx.setI64(lite3.root, "y", 2);
    var it = try ctx.iterate(lite3.root);
    _ = try it.next();
    var v: [5000]u8 = @splat('z');
    try ctx.setStr(lite3.root, "big", &v);
    try testing.expectError(lite3.Error.StaleReference, it.next()); // or a new error.StaleIterator
}

test "MEM-5 Context: iterator next() after growth must fail cleanly" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetObj();
    try ctx.setI64(lite3.root, "x", 1);
    try ctx.setI64(lite3.root, "y", 2);
    var it = try ctx.iterate(lite3.root);
    _ = try it.next();
    var v: [5000]u8 = @splat('z');
    try ctx.setStr(lite3.root, "big", &v);
    try testing.expectError(lite3.Error.StaleReference, it.next());
}
```

<details><summary>Output on b7cb2b9</summary>

```
ManagedContext (Debug native): Segmentation fault at address 0x7f0258520000 ... terminated with signal 6 (next() dereferences the freed storage in lite3_iter_next)
Context (Debug native): failed: MEM-5 Context next after growth -> error.InvalidArgument (the UAF read happened to see a different gen)
Context under valgrind (Debug):
==27513== Invalid read of size 4
==27513==    at 0x111C3B4: lite3_iter_next (lite3.c:371)
==27513==    by 0x1119BA1: shim_lite3_iter_next (lite3_shim.c:276)
==27513==    by 0x103CAA6: lite3.Iterator.next (lite3.zig:182)
==27513==  Address 0x4a780a0 is 0 bytes inside a block of size 1,024 free'd
==27513==    by 0x1159B11: lite3_ctx_grow_impl (ctx_api.c:187)
```
</details>

**Fix sketch:** src/lite3.zig:159-191: replace the captured `buf`/`buflen` with a way to re-read the current buffer on each next(): an `owner: *const anyopaque` plus a `fetch: *const fn (*const anyopaque) []const u8`, or a generic Iterator(Owner). Add a wrapper-level `epoch: u32` to Buffer, ManagedContext and ExternalContext, and a Zig-side counter on Context. Increment it in every mutating method (set*, arrAppend*, reset*, importFromBuf, jsonDecode, grow). The iterator snapshots the epoch and returns a dedicated error (StaleReference, or a new StaleIterator) on mismatch before calling C, so the check never touches freed memory. Update iterate() at 781-793, 1442-1444 and 1796-1798. Document that Entry.key borrows the buffer until the next mutation. Breaking change: the Iterator struct fields change and the owner must stay at a stable address (see MEM-12). Also pull upstream 8a4fca6 (iterator target_ofs fix). Files: src/lite3.zig, src/tests.zig, README.

## MEM-7 — The vendored lite3 (about 2026-01-07, 874d89e) lacks upstream fixes that affect offset/reference soundness, all reachable through the wrapper
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-7, CSH-8, SEC-5, SEC-6, SEC-7, SEC-9, BLD-2, OPS-6

```zig
test "MEM-7 setObj over long string yields 4-aligned offset (upstream da01893)" {
    var mem: [4096]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    var v: [200]u8 = @splat('s');
    try b.setStr(lite3.root, "k", &v);
    const o = try b.setObj(lite3.root, "k");
    try testing.expectEqual(@as(usize, 0), @intFromEnum(o) % 4);
}

test "MEM-7 empty key with null value is readable (upstream 7b62398)" {
    var mem: [1024]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    try b.setNull(lite3.root, "");
    try testing.expectEqual(lite3.Type.null, try b.getType(lite3.root, ""));
}

test "MEM-7 root iterator invalidated by nested write (upstream 66bb52a)" {
    var mem: [4096]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    const o = try b.setObj(lite3.root, "o");
    try b.setI64(lite3.root, "x", 1);
    var it = try b.iterate(lite3.root);
    _ = try it.next();
    try b.setI64(o, "n", 5);
    try testing.expect(std.meta.isError(it.next()));
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code (Debug):
'MEM-7 setObj over long string ...' failed: MEM-7 obj offset 99 mod4=3
'MEM-7 empty key with null value ...' failed: error.NotFound from getType (lite3.zig:380)
'MEM-7 root iterator invalidated by nested write' failed: MEM-7 root iter after nested write -> .{ .key = { 120, 0, 2, 1, 0, 0, 0 }, .val_offset = 199 }  (entry returned, not an error; the key also shows the MEM-2 length bug)
`git show 874d89e:src/lite3.c | diff -q - vendor/lite3/src/lite3.c` -> IDENTICAL. Upstream 874d89e..48ab0e9 includes 69d8461, 8a4fca6, 7b62398, da01893 and 66bb52a.
After copying upstream 48ab0e9 src/lite3.c + include/lite3.h into the scratch copy (repro-0/fixed, keeping the LITE3_DISABLE_PREFETCHING guard): 'MEM-7 obj offset 100 mod4=0', 'root iter after nested write -> error.InvalidArgument', 3/3 pass; the full suite passes 117/117.
```
</details>

**Fix sketch:** Re-vendor vendor/lite3 from upstream 48ab0e9: src/lite3.c, include/lite3.h, and also json_enc.c, json_dec.c and lite3_context_api.h, which differ too. Keep the local `#ifndef LITE3_DISABLE_PREFETCHING` guard in lite3.h as a documented patch, and carry the MEM-2 iter-key-length fix as a second local patch. Add vendor/lite3/VERSION (upstream URL, commit, patch list) and a CI script that checks vendor == commit + patches. Note that after the re-vendor, nested-mutation staleness surfaces as error.InvalidArgument, not StaleReference (see API-5), so map the iterator errno accordingly or rely on the MEM-5 epoch. Add the three tests above to tests.zig. Files: vendor/lite3/**, src/tests.zig, CI. No Zig API change. Tested in scratch: the existing tests plus the MEM-7 tests pass after the re-vendor.

## CSH-1 — Iterator returns the raw key tag as the key length (about 4x too long), so reading the key reads past the buffer
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-2, API-1, TST-2, SEC-1

```zig
// Add to src/repro_tests.zig. build.zig needs a test step that imports module "lite3" (see scratch repro-1/repo/build.zig: step `repro`, option -Drf=<filter>)
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");
const root = lite3.root;

test "CSH-1: Buffer iterator returns exact key bytes" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(root, "x", 1);
    var it = try buf.iterate(root);
    const e = (try it.next()).?;
    try testing.expectEqualStrings("x", e.key.?);
}

test "CSH-1: Context iterator returns exact key bytes" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.resetObj();
    try ctx.setI64(root, "abc", 1);
    var it = try ctx.iterate(root);
    const e = (try it.next()).?;
    try testing.expectEqualStrings("abc", e.key.?);
}

test "CSH-1: 60-byte key at end of exact-size heap buffer stays in bounds" {
    const key = "k" ** 60;
    var mem: [4096]u8 align(4) = undefined;
    var src = try lite3.Buffer.initObj(&mem);
    try src.setNull(root, key);
    const heap = try testing.allocator.alignedAlloc(u8, .@"4", src.len);
    defer testing.allocator.free(heap);
    @memcpy(heap, src.data());
    var buf = try lite3.Buffer.fromSerialized(heap, heap.len);
    var it = try buf.iterate(root);
    const k = (try it.next()).?.key.?;
    try testing.expect(@intFromPtr(k.ptr) + k.len <= @intFromPtr(heap.ptr) + heap.len);
    try testing.expectEqualStrings(key, k);
}
```

<details><summary>Output on b7cb2b9</summary>

```
1/13 CSH-1: Buffer iterator returns exact key bytes...
====== expected this output: =========
x␃
======== instead found this: =========
x    ␃   (bytes 'x',0x00,0x02,0x01,...)
FAIL (TestExpectedEqual)
2/13 CSH-1: Context iterator returns exact key bytes... FAIL (TestExpectedEqual)
3/13 CSH-1: 60-byte key at end of exact-size heap buffer stays in bounds...FAIL (TestUnexpectedResult)   <- key slice extends past end of the heap allocation
With scratch fix (shim computes len via strnlen bounded by buflen, key zero-init): all 3 -> OK; `zig build test` still passes (117/117).
```
</details>

**Fix sketch:** Root cause: vendor/lite3/src/lite3.c:403-405 memcpy's the raw key tag into out_key->len and only decrements it, never shifting right by LITE3_KEY_TAG_KEY_SIZE_SHIFT. src/lite3_shim.c:282 forwards it and src/lite3.zig:185 slices p[0..key_len].
Fix in the shim (src/lite3_shim.c shim_lite3_iter_next). Either decode the tag correctly, or do what was verified in scratch: `size_t avail = buflen - ((const unsigned char*)p - buf); size_t n = strnlen(p, avail); if (n == avail) { errno = EBADMSG; return -1; } *key_len = (uint32_t)n;`. Best: also patch lite3.c:403-405 locally (`out_key->len = (tag >> LITE3_KEY_TAG_KEY_SIZE_SHIFT) - 1`, plus a p[len]==0 check), because json_enc and other internal callers share lite3_iter_next, and report it upstream (still present at HEAD 48ab0e9).
Blast radius: shim only, no API change. Add byte-exact key tests (1-byte, 5-byte, keys over 63 bytes with a 2-byte tag, Context/Managed/External).

## CSH-2 — restoreLen after a failed mutation corrupts the document: node splits are orphaned beyond len (data loss in ManagedContext/ExternalContext auto-grow)
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-1, ALC-1, TST-1

```zig
test "CSH-2: ManagedContext grow across a node split keeps all keys" {
    var mc = try lite3.ManagedContext.initWithCapacity(testing.allocator, 1024);
    defer mc.deinit();
    const val = "v" ** 94;
    var kb: [8]u8 = undefined;
    for (0..7) |i| try mc.setStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), val);
    try mc.setI64(root, "k7", 7);
    for (0..7) |i| try testing.expectEqualStrings(val, try mc.getStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
    try testing.expectEqual(@as(i64, 7), try mc.getI64(root, "k7"));
}

test "CSH-2: ExternalContext grow across a node split keeps all keys" {
    const a = testing.allocator;
    var ec = try lite3.ExternalContext.initWithCapacity(a, 1024);
    defer ec.deinit(a);
    const val = "v" ** 94;
    var kb: [8]u8 = undefined;
    for (0..7) |i| try ec.setStr(a, root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), val);
    try ec.setI64(a, root, "k7", 7);
    for (0..7) |i| try testing.expectEqualStrings(val, try ec.getStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
    try testing.expectEqual(@as(i64, 7), try ec.getI64(root, "k7"));
}

test "CSH-2: Buffer NoBufferSpace leaves document readable" {
    var mem: [1024]u8 align(4) = undefined;
    var big: [4096]u8 align(4) = undefined;
    const val = "v" ** 94;
    var kb: [8]u8 = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    for (0..7) |i| try buf.setStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), val);
    var cap = buf.len + 1;
    while (cap < mem.len) : (cap += 4) {
        var tmp: [1024]u8 align(4) = undefined;
        @memcpy(tmp[0..buf.len], buf.data());
        var b2 = try lite3.Buffer.fromSerialized(tmp[0..cap], buf.len);
        b2.setI64(root, "k7", 7) catch |err| {
            try testing.expectEqual(error.NoBufferSpace, err);
            for (0..7) |i| try testing.expectEqualStrings(val, try b2.getStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
            @memcpy(big[0..b2.len], b2.data());
            var b3 = try lite3.Buffer.fromSerialized(&big, b2.len);
            try b3.setI64(root, "k7", 7);
            try testing.expectEqual(@as(i64, 7), try b3.getI64(root, "k7"));
            for (0..7) |i| try testing.expectEqualStrings(val, try b3.getStr(root, try std.fmt.bufPrint(&kb, "k{d}", .{i})));
            continue;
        };
    }
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code:
1/3 CSH-2: ManagedContext grow across a node split keeps all keys...FAIL (Unexpected)   <- the setI64("k7") auto-grow retry itself returns error.Unexpected (lite3.zig:1181 callWithGrowth)
2/3 CSH-2: ExternalContext grow across a node split keeps all keys...FAIL (Unexpected)  (lite3.zig:1542 callWithGrowth)
3/3 CSH-2: Buffer NoBufferSpace leaves document readable...FAIL (Unexpected)  <- getStr(k0) after the failed write (trace: lite3.zig:446 getStr -> translateError)
With restoreLen made a no-op in scratch: all 3 OK, and the existing `zig build test` suite still passes.
```
</details>

**Fix sketch:** Delete saveLen/restoreLen (src/lite3.zig:227-238) and every restoreLen(self, saved) call in SharedMethods: all set*, setObj/setArr and arrAppend* paths. The C library owns *inout_buflen, and a failed lite3_set_impl may already have split nodes and advanced it (lite3.c:574/746). The ManagedContext/ExternalContext callWithGrowth loops then work unchanged, because realloc keeps the bytes past len.
Document on Buffer that a failed mutation can consume space and is not rolled back (as the C docs say). Remove or invert any existing test that asserts len is unchanged after NoBufferSpace (see TST-1).
Blast radius: lite3.zig only. The behaviour change is that Buffer.len may grow on a failed write. No signature change.

## CSH-3 — Untrusted buffer with a stored string size of 0 makes getStr/arrGetStr return a 4 GiB slice
Reproduced: **True** · severity after repro: **critical** · same root cause: SEC-2, SEC-16

```zig
test "CSH-3: stored string size 0 is rejected" {
    var mem: [256]u8 align(4) = undefined;
    var src = try lite3.Buffer.initObj(&mem);
    try src.setStr(root, "s", "abc");
    var copy: [256]u8 align(4) = undefined;
    const n = src.len;
    @memcpy(copy[0..n], src.data());
    const at = std.mem.indexOf(u8, copy[0..n], "abc\x00").?;
    @memset(copy[at - 4 .. at], 0); // zero the 4-byte stored size
    var buf = try lite3.Buffer.fromSerialized(&copy, n);
    if (buf.getStr(root, "s")) |s| {
        try testing.expect(s.len < n);
    } else |_| {}
}
```

<details><summary>Output on b7cb2b9</summary>

```
7/13 CSH-3: stored string size 0 is rejected...CSH-3 getStr len=4294967295 buflen=108
FAIL (TestUnexpectedResult)
With scratch shim guard (reject s.len==UINT32_MAX, ptr+len beyond buflen, or missing NUL -> errno=EBADMSG): OK.
```
</details>

**Fix sketch:** In src/lite3_shim.c, in every string getter (shim_lite3_get_str :36, shim_lite3_arr_get_str :205, shim_lite3_ctx_get_str :342, shim_lite3_ctx_arr_get_str :392), after a successful call add: `if (s.len == UINT32_MAX || (size_t)((const unsigned char*)s.ptr - buf) + s.len >= buflen || s.ptr[s.len] != 0) { errno = EBADMSG; return -1; }`. This is verified for the object getter in scratch. It maps to CorruptData. The getValue path uses the same shims.
Bytes getters: a stored size of 0 is legal, but still bounds-check ptr+len <= buflen. Optionally add Buffer.validate()/fromSerializedChecked() that walks the whole tree. Report upstream (lite3.h:2347/2580 `--out->len`).
Blast radius: shim only. Callers see CorruptData instead of a 4 GiB slice.

## CSH-4 — shim_lite3_iter_next reads an uninitialised lite3_str: array iteration can report a stale key
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-3, SEC-10, OPS-1

```zig
fn iterObjThenArr(buf: *lite3.Buffer, arr: lite3.Offset) !usize {
    var it = try buf.iterate(root);
    while (try it.next()) |_| {}
    var ait = try buf.iterate(arr);
    var bogus: usize = 0;
    while (try ait.next()) |e| {
        if (e.key != null) bogus += 1;
    }
    return bogus;
}

test "CSH-4: array iterator entries have no key" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(root, "somekey", "val");
    const arr = try buf.setArr(root, "arr");
    try buf.arrAppendI64(arr, 1);
    try buf.arrAppendI64(arr, 2);
    try buf.arrAppendI64(arr, 3);
    try testing.expectEqual(@as(usize, 0), try iterObjThenArr(&buf, arr));
}
// Fails deterministically with -Doptimize=ReleaseFast or ReleaseSafe. In Debug it passes but valgrind flags it; run the test binary under `valgrind -q` (build with -Dcpu=x86_64_v3 so valgrind accepts the instructions).
```

<details><summary>Output on b7cb2b9</summary>

```
-Doptimize=ReleaseFast: `CSH-4 array key len=31` / `expected 0, found 1` FAIL (TestExpectedEqual)
-Doptimize=ReleaseSafe: same FAIL
Debug: OK, but valgrind reports:
==27843== Conditional jump or move depends on uninitialised value(s)
==27843==    at shim_lite3_iter_next (lite3_shim.c:279)
==27843==    by lite3.Iterator.next (lite3.zig:182)
==27843==    by repro_tests.iterObjThenArr (repro_tests.zig:117)
With `lite3_str key = {0};` in the shim: OK in ReleaseFast.
```
</details>

**Fix sketch:** src/lite3_shim.c:275: `lite3_str key = {0};`, and always write *key_ptr/*key_len on every return path. Better: record whether the container is an object or an array at iter_create (type byte at ofs), keep it in the shim iterator, and report key=NULL for arrays without probing key.ptr. Do not pass NULL out_key for objects until after re-vendoring (pre-8a4fca6 mis-advances).
Add a test that entry.key == null for every array entry, including after an object iteration, and run it in ReleaseFast in CI.
Blast radius: shim only. The key-length half of the symptom is CSH-1.

## CSH-5 — Setting a value from a slice that aliases the same document: use-after-free on Context grow; self-assignment writes zeros
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-4

```zig
test "CSH-5: Buffer self-assignment of a string keeps its value" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(root, "a", "hello");
    try buf.setStr(root, "a", try buf.getStr(root, "a"));
    try testing.expectEqualStrings("hello", try buf.getStr(root, "a"));
}

test "CSH-5: ManagedContext copy of a field across a grow" {
    var mc = try lite3.ManagedContext.initWithCapacity(testing.allocator, 1024);
    defer mc.deinit();
    const val = "o" ** 700;
    try mc.setStr(root, "orig", val);
    try mc.setStr(root, "copy", try mc.getStr(root, "orig"));
    try testing.expectEqualStrings(val, try mc.getStr(root, "copy"));
}

test "CSH-5: Context copy of a field across a grow (run under valgrind)" {
    var ctx = try lite3.Context.initWithSize(1024);
    defer ctx.deinit();
    try ctx.resetObj();
    const val = "o" ** 700;
    try ctx.setStr(root, "orig", val);
    try ctx.setStr(root, "copy", try ctx.getStr(root, "orig"));
    try testing.expectEqualStrings(val, try ctx.getStr(root, "copy"));
}
```

<details><summary>Output on b7cb2b9</summary>

```
Buffer self-assign: FAIL (TestExpectedEqual), expected "hello", found "\x00\x00\x00\x00\x00"
ManagedContext copy across grow (Debug, testing.allocator): `Segmentation fault at address 0x7f8090c0006b` (the test runner aborts: the source slice points into storage that realloc freed)
Context copy across grow: test passes by luck, but valgrind reports:
==27810== Invalid read of size 32
==27810==    at memcpy (memcpy.zig:44)
==27810==    by _lite3_ctx_set_str_n_impl (lite3_context_api.h:578)
==27810==    by shim_lite3_ctx_set_str (lite3_shim.c:331)
==27810==    by lite3.SharedMethods(lite3.Context).setStr (lite3.zig:309)
==27810==  Address 0x4b6010b is 107 bytes inside a block of size 1,024 free'd
```
</details>

**Fix sketch:** In every str/bytes setter and appender (SharedMethods setStr/setBytes/arrAppendStr/arrAppendBytes in src/lite3.zig ~302-600, plus the ManagedContext/ExternalContext forwarders), detect when [value.ptr, value.ptr+len) overlaps the backing storage:
- Buffer: [buf, buf+capacity).
- Managed/External: storage. Check before callWithGrowth, because realloc invalidates the slice.
- Context: add a shim accessor that returns ctx->buf/bufsz.
On overlap, copy the value to a temporary (stack buffer for small values; allocator or c malloc otherwise) before calling C. Returning InvalidArgument is the less friendly alternative. Document that values must not alias the destination (the C setters use restrict).
Blast radius: lite3.zig and a small shim addition, no API break. Add tests for the in-place case and the grow case (ManagedContext with testing.allocator already segfaults, which makes a good regression test).

## CSH-7 — setObj/setArr over an existing long string or bytes value places the new node at a misaligned offset (upstream issue #11, fixed upstream but not vendored)
Reproduced: **True** · severity after repro: **high** · same root cause: SEC-6, MEM-7, CSH-8, BLD-2, OPS-6, SEC-5, MEM-8, CSH-12

```zig
test "CSH-7: setObj over a long string is 4-aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const long = "s" ** 120;
    try buf.setStr(root, "kk", long);
    try buf.setStr(root, "k", long);
    const o = try buf.setObj(root, "k");
    try testing.expectEqual(@as(usize, 0), @intFromEnum(o) % 4);
    try buf.setI64(o, "n", 5);
    try testing.expectEqual(@as(i64, 5), try buf.getI64(o, "n"));
}

test "CSH-7: setArr over a long string is 4-aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const long = "s" ** 120;
    try buf.setStr(root, "kk", long);
    try buf.setStr(root, "k", long);
    const o = try buf.setArr(root, "k");
    try testing.expectEqual(@as(usize, 0), @intFromEnum(o) % 4);
}
```

<details><summary>Output on b7cb2b9</summary>

```
1/2 CSH-7: setObj over a long string is 4-aligned...CSH-7 setObj ofs=229
expected 0, found 1
FAIL (TestExpectedEqual)
2/2 CSH-7: setArr over a long string is 4-aligned...expected 0, found 1
FAIL (TestExpectedEqual)
0 passed; 0 skipped; 2 failed.
(Upstream fix exists: `git log -1 da01893` in /home/user/fastserial/lite3 -> 'Align nodes during in-place overwrite'. I did not rebuild against upstream in this run; the earlier verifier reported offset 232, aligned, with upstream vendored.)
```
</details>

**Fix sketch:** Re-vendor lite3 to upstream HEAD (48ab0e9 or later, which includes da01893 'Align nodes during in-place overwrite'), or cherry-pick da01893 into vendor/lite3/src/lite3.c (in-place overwrite path near :691/:716 and the node init at :473/:800). Record provenance (upstream commit plus local patches) at the same time.
Defence in depth: in the Zig wrapper, assert or return CorruptData when setObj/setArr/getObj/getArr/arrGet* return an Offset that is not 4-aligned. Also add sanitized-C CI (Debug C with UBSan reports 'member access within misaligned address ... struct node' at lite3.c:473).
Blast radius: vendor update (review other upstream behaviour changes), no Zig API change.

## CSH-9 — lite3_ctx_import_from_buf frees the buffer before malloc; on allocation failure it leaves dangling pointers and deinit double-frees
Reproduced: **True** · severity after repro: **high** · same root cause: ALC-3, MEM-10

```zig
// src/repro_import.zig (build step: `zig build repro -Drepro=src/repro_import.zig`; the module needs link_libc)
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "CSH-9/ALC-3: Context.importFromBuf OOM keeps the context valid" {
    var ctx = try lite3.Context.init();
    try ctx.jsonDecode("{\"a\":1}");
    // Cap the address space so malloc(4 GiB) fails.
    const old = try std.posix.getrlimit(.AS);
    try std.posix.setrlimit(.AS, .{ .cur = 1500 * 1024 * 1024, .max = old.max });
    defer std.posix.setrlimit(.AS, old) catch {};
    var tiny: [4]u8 = .{ 0, 0, 0, 0 };
    // Never read: the allocation fails before memcpy.
    const huge: []const u8 = @as([*]const u8, &tiny)[0 .. 3 << 30];
    const r = ctx.importFromBuf(huge);
    const a = ctx.getI64(lite3.root, "a");
    try testing.expectError(error.OutOfMemory, r);
    try testing.expectEqual(@as(i64, 1), try a); // fails today: reads freed memory
    ctx.deinit(); // double free today (reached only once fixed)
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code:
  CSH-9 import=error.OutOfMemory getI64(a) after=error.InvalidArgument
  error: 'repro_import.test.CSH-9/ALC-3: ...' failed ... lite3.zig:1110:22 in importFromBuf ... lite3.zig:416:26 in getI64
  0/1 tests passed
Variant that calls ctx.deinit() right after the failed import (src/repro_import2.zig):
  import=error.OutOfMemory; calling deinit
  free(): double free detected in tcache 2
  ... terminated with signal 6
With the malloc-first patch to vendor/lite3/src/ctx_api.c (scratch copy .../wf/repro-2/fixed):
  CSH-9 import=error.OutOfMemory getI64(a) after=1
  1/1 tests passed; zig build test still 117/117.
```
</details>

**Fix sketch:** Patch vendor/lite3/src/ctx_api.c:214-218 so it mallocs before it frees:
    void *new = malloc(new_size);
    if (!new) { errno = ENOMEM; return -1; }
    free(ctx->underlying_buf);
    ctx->underlying_buf = new; ...
I verified this patch; the test passes. Record the patch in a vendoring or provenance note (see BLD-2/SEC-5) and report it upstream, because HEAD 48ab0e9 still has the bug. Alternative with no vendor patch: in Context.importFromBuf (src/lite3.zig:1107), when buf.len > shim_lite3_ctx_bufsz(ctx), call shim_lite3_ctx_create_from_buf into a new ctx, destroy the old ctx only on success, then swap. Blast radius: one C function or one Zig method, with no API change. Put the test in its own test binary, because it lowers RLIMIT_AS for the process.

## ALC-1 — Undoing buflen after a failed write corrupts documents; ManagedContext/ExternalContext grow-and-retry silently loses committed data
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-1, CSH-2, TST-1, ALC-9

```zig
// src/repro.zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "ALC-1: ManagedContext sequential setI64 keeps every committed key" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    var kb: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const k = try std.fmt.bufPrint(&kb, "key{d}", .{i});
        try ctx.setI64(lite3.root, k, @intCast(i));
    }
    var bad: usize = 0;
    i = 0;
    while (i < 5000) : (i += 1) {
        const k = try std.fmt.bufPrint(&kb, "key{d}", .{i});
        const v = ctx.getI64(lite3.root, k) catch -1;
        if (v != @as(i64, @intCast(i))) bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "ALC-1: ExternalContext sequential setI64 keeps every committed key" {
    const a = testing.allocator;
    var ctx = try lite3.ExternalContext.init(a);
    defer ctx.deinit(a);
    var kb: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const k = try std.fmt.bufPrint(&kb, "key{d}", .{i});
        try ctx.setI64(a, lite3.root, k, @intCast(i));
    }
}

test "ALC-1: Buffer committed keys stay readable after NoBufferSpace" {
    var broken_caps: usize = 0;
    var cap: usize = 200;
    while (cap <= 2000) : (cap += 4) {
        var mem: [2048]u8 align(4) = undefined;
        var buf = try lite3.Buffer.initObj(mem[0..cap]);
        var kb: [32]u8 = undefined;
        var n: usize = 0;
        while (true) : (n += 1) {
            const k = try std.fmt.bufPrint(&kb, "key{d}", .{n});
            buf.setI64(lite3.root, k, @intCast(n)) catch |e| {
                try testing.expectEqual(error.NoBufferSpace, e);
                break;
            };
        }
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const k = try std.fmt.bufPrint(&kb, "key{d}", .{j});
            const v = buf.getI64(lite3.root, k) catch -1;
            if (v != @as(i64, @intCast(j))) { broken_caps += 1; break; }
        }
    }
    try testing.expectEqual(@as(usize, 0), broken_caps);
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code (zig build repro):
  error: 'repro.test.ALC-1: ManagedContext sequential setI64 keeps every committed key' failed: ALC-1 managed setI64(key1334) -> error.CorruptData cap=262144
  error: 'repro.test.ALC-1: ExternalContext sequential setI64 keeps every committed key' failed: ALC-1 external setI64(key1334) -> error.CorruptData
  error: 'repro.test.ALC-1: Buffer committed keys stay readable after NoBufferSpace' failed: ALC-1 buffer cap=396: committed key0 -> error.Unexpected
  ALC-1 buffer caps with broken committed keys: 40
With restoreLen made a no-op (scratch copy .../wf/repro-2/fixed): all 3 ALC-1 tests pass ('ALC-1 buffer caps with broken committed keys: 0'), and zig build test is still 117/117 (including tests.zig:1377 'mutation rollback preserves buffer length').
```
</details>

**Fix sketch:** In src/lite3.zig SharedMethods, delete saveLen/restoreLen (lines 229-239) and every call to them (about 16 set*/arrAppend* bodies, 247-627). Always keep the *inout_buflen that C writes back, as upstream ctx_api does. Document the Buffer contract: after a failed write, `len` may have grown and the document stays valid (basic guarantee). Rewrite the comment on tests.zig:1377-1390; it still passes, because a single oversized entry does no split. Also add an assertion there that committed keys stay readable. Add the three tests above, and the same sweep with an array root and arrAppendI64. ManagedContext/ExternalContext.callWithGrowth (1181, 1529) then work unchanged, because they retry at the correct len. No public API change; this is a behaviour and documentation change for Buffer.len after a failure.

## ALC-2 — Failed jsonDecode leaves ManagedContext/ExternalContext unusable (root overwritten, len stale); Context silently loses the old document
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-9, CSH-15, API-15, TST-6, SEC-11

```zig
// src/repro.zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

fn deepJson(buf: []u8) []const u8 { // {"x":1,"deep":[[[...40...]]]} : nesting > 32
    var w: usize = 0;
    const head = "{\"x\":1,\"deep\":";
    @memcpy(buf[w..][0..head.len], head); w += head.len;
    for (0..40) |_| { buf[w] = '['; w += 1; }
    for (0..40) |_| { buf[w] = ']'; w += 1; }
    buf[w] = '}'; w += 1;
    return buf[0..w];
}

test "ALC-2: failed ManagedContext.jsonDecode leaves old document intact" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    try ctx.jsonDecode("{\"a\":1,\"name\":\"alice\"}");
    var jb: [256]u8 = undefined;
    const r = ctx.jsonDecode(deepJson(&jb));
    try testing.expect(std.meta.isError(r));
    try testing.expectEqual(@as(i64, 1), try ctx.getI64(lite3.root, "a"));
    try testing.expectError(error.NotFound, ctx.getI64(lite3.root, "x"));
}

test "ALC-2: failed ManagedContext.jsonDecode (big partial) leaves a usable context" {
    var ctx = try lite3.ManagedContext.init(testing.allocator);
    defer ctx.deinit();
    var jb: [4096]u8 = undefined;
    var w: usize = 0;
    jb[w] = '{'; w += 1;
    for (0..20) |i| { const s = try std.fmt.bufPrint(jb[w..], "\"k{d}\":{d},", .{ i, i }); w += s.len; }
    const tail = "\"deep\":" ++ "[" ** 40 ++ "]" ** 40 ++ "}";
    @memcpy(jb[w..][0..tail.len], tail); w += tail.len;
    try testing.expect(std.meta.isError(ctx.jsonDecode(jb[0..w])));
    try ctx.setI64(lite3.root, "new", 5);
    try testing.expectEqual(@as(i64, 5), try ctx.getI64(lite3.root, "new"));
}

test "ALC-2: failed ExternalContext.jsonDecode leaves old document intact" {
    const al = testing.allocator;
    var ctx = try lite3.ExternalContext.init(al);
    defer ctx.deinit(al);
    try ctx.jsonDecode(al, "{\"a\":1}");
    var jb: [256]u8 = undefined;
    try testing.expect(std.meta.isError(ctx.jsonDecode(al, deepJson(&jb))));
    try testing.expectEqual(@as(i64, 1), try ctx.getI64(lite3.root, "a"));
}

test "ALC-2: failed Context.jsonDecode leaves old document intact" {
    var ctx = try lite3.Context.init();
    defer ctx.deinit();
    try ctx.jsonDecode("{\"a\":1}");
    var jb: [256]u8 = undefined;
    try testing.expect(std.meta.isError(ctx.jsonDecode(deepJson(&jb))));
    try testing.expectEqual(@as(i64, 1), try ctx.getI64(lite3.root, "a"));
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code:
  'ALC-2: failed ManagedContext.jsonDecode leaves old document intact' failed: ALC-2 managed decode=error.InvalidArgument a=error.NotFound x=1
  'ALC-2: failed ManagedContext.jsonDecode (big partial) leaves a usable context' failed: ALC-2 managed(big) decode=error.InvalidArgument len=96 setI64(new)=error.Unexpected
  'ALC-2: failed ExternalContext.jsonDecode leaves old document intact' failed: ALC-2 external decode=error.InvalidArgument a=error.NotFound
  'ALC-2: failed Context.jsonDecode leaves old document intact' failed: ALC-2 context decode=error.InvalidArgument a=error.NotFound x=1
(x=1 comes from the FAILED decode. The old key a is gone. The stale len=96 makes every later write fail with Unexpected.)
With a prototype scratch-buffer-and-swap ManagedContext.jsonDecode (scratch copy .../wf/repro-2/fixed): both ManagedContext tests pass, and zig build test is still 117/117. The External and Context tests still fail, because I did not patch them.
```
</details>

**Fix sketch:** ManagedContext.jsonDecode (src/lite3.zig:1270-1284), prototyped and passing:
    var cap = self.storageSlice().len;
    while (true) {
        const scratch = allocator.alignedAlloc(u8, .@"4", cap) catch return error.OutOfMemory;
        const nb = Buffer.jsonDecode(scratch, json) catch |err| {
            allocator.free(scratch);
            if (err == error.NoBufferSpace and cap < max_capacity) { cap = @min(cap*4, max_capacity); continue; }
            return err;
        };
        allocator.free(self.storage.?); self.storage = scratch; self.inner = nb; return;
    }
Apply the same change to ExternalContext.jsonDecode (1624-1638). For Context.jsonDecode (1099), create a temporary ctx (shim_lite3_ctx_create_with_size), run shim_lite3_ctx_json_dec on it, and on success destroy the old ctx and swap the pointer; on failure, destroy the temporary. Document on Buffer.jsonDecode that `mem` is clobbered on failure. Blast radius: 3 methods, no signature change. Peak memory during a decode doubles, which is acceptable.

## ALC-3 — Context.importFromBuf: a malloc failure leaves dangling pointers; later reads use freed memory and deinit double-frees
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-9, MEM-10

```zig
// Same test as CSH-9 (src/repro_import.zig; separate test binary, because it lowers RLIMIT_AS)
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "CSH-9/ALC-3: Context.importFromBuf OOM keeps the context valid" {
    var ctx = try lite3.Context.init();
    try ctx.jsonDecode("{\"a\":1}");
    const old = try std.posix.getrlimit(.AS);
    try std.posix.setrlimit(.AS, .{ .cur = 1500 * 1024 * 1024, .max = old.max });
    defer std.posix.setrlimit(.AS, old) catch {};
    var tiny: [4]u8 = .{ 0, 0, 0, 0 };
    const huge: []const u8 = @as([*]const u8, &tiny)[0 .. 3 << 30];
    try testing.expectError(error.OutOfMemory, ctx.importFromBuf(huge));
    try testing.expectEqual(@as(i64, 1), try ctx.getI64(lite3.root, "a"));
    ctx.deinit();
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code: 'CSH-9 import=error.OutOfMemory getI64(a) after=error.InvalidArgument' (reads freed memory). The deinit variant gives 'free(): double free detected in tcache 2', signal 6.
With the malloc-first patch: 'getI64(a) after=1', 1/1 passed.
```
</details>

**Fix sketch:** Same fix as CSH-9. Patch ctx_api.c:214-218 to malloc, check the result, set errno=ENOMEM on failure, and only then free the old buffer. Or do the wrapper-side create_from_buf-then-swap in Context.importFromBuf (src/lite3.zig:1107-1111). No API change.

## API-1 — Iterator.Entry.key has the wrong length for every key, so reading it goes out of bounds on the heap
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-2, CSH-1, SEC-1, TST-2

```zig
// src/repro.zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "API-1: iterator returns exact key bytes" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const long = "k" ** 70;
    try buf.setI64(lite3.root, "x", 1);
    try buf.setI64(lite3.root, "hello", 2);
    try buf.setI64(lite3.root, long, 3);
    var it = try buf.iterate(lite3.root);
    var seen: usize = 0;
    while (try it.next()) |e| {
        const k = e.key.?;
        try testing.expect(std.mem.eql(u8, k, "x") or std.mem.eql(u8, k, "hello") or std.mem.eql(u8, k, long));
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

// Heap OOB evidence (src/repro_iter_vg.zig, run under valgrind with -Dcpu=x86_64_v2):
test "iterate key into exact-size heap doc" {
    var mem: [4096]u8 align(4) = undefined;
    var b = try lite3.Buffer.initObj(&mem);
    try b.setI64(lite3.root, "k" ** 70, 1);
    const heap = try std.heap.c_allocator.alignedAlloc(u8, .@"4", b.len);
    defer std.heap.c_allocator.free(heap);
    @memcpy(heap, mem[0..b.len]);
    var v = try lite3.Buffer.fromSerialized(heap, heap.len);
    var it = try v.iterate(lite3.root);
    while (try it.next()) |e| _ = std.hash.Wyhash.hash(0, e.key.?);
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code:
  error: 'repro.test.API-1: iterator returns exact key bytes' failed: API-1 key.len=7   (key "x")
valgrind ./zig-out/bin/test (heap doc of 178 bytes):
  ==29250== Invalid read of size 8
  ==29250==  Address 0x4b600f2 is 0 bytes after a block of size 178 alloc'd
  ==29250==  Address 0x4b60102 is 16 bytes after a block of size 178 alloc'd
  ...
With the shim fix (scratch copy .../wf/repro-2/fixed): 'API-1 key.len=1', the test passes, and zig build test is 117/117.
```
</details>

**Fix sketch:** In src/lite3_shim.c:272-288 (shim_lite3_iter_next), zero-initialise `lite3_str key = {0};` (this also fixes MEM-3) and decode the tag:
    *key_len = (uint32_t)((((size_t)key.len + 1) >> 2) - 1);
LITE3_KEY_TAG_KEY_SIZE_SHIFT is defined in lite3.c:115, not in the header, so use the literal 2 or copy the define into the shim. I verified this. As a hardening step, also reject the entry (return -EFAULT) if key_ptr+key_len+1 > buf+buflen. Add exact-bytes tests for key lengths 1, 5, 62, 63, 64, 70 and 255, and a >255 key from JSON decode. Report lite3_iter_next upstream (lite3.c:402-406). No API change.

## API-3 — getType, arrGetType and exists swallow errors, so a corrupt or truncated document looks like a missing key
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-13

```zig
// src/repro.zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "API-3: getType/exists must not report a truncated doc as 'key absent'" {
    var mem: [4096]u8 align(4) = undefined;
    var full = try lite3.Buffer.initObj(&mem);
    try full.setI64(lite3.root, "a", 1);
    try full.setI64(lite3.root, "b", 2);
    try full.setStr(lite3.root, "signature", "deadbeef");
    var trunc = try lite3.Buffer.fromSerialized(&mem, 48); // truncated message
    try testing.expect(std.meta.isError(trunc.getI64(lite3.root, "signature")));
    const gt = trunc.getType(lite3.root, "signature");
    const ex = trunc.exists(lite3.root, "signature");
    try testing.expect(gt != error.NotFound);
    try testing.expect(!std.meta.eql(ex, @as(lite3.Error!bool, false)));
}

test "API-3: getType on an array root is a type error, not NotFound" {
    var mem: [1024]u8 align(4) = undefined;
    var arr = try lite3.Buffer.initArr(&mem);
    try arr.arrAppendI64(lite3.root, 7);
    try testing.expect(arr.getType(lite3.root, "k") != error.NotFound);
    const at = arr.arrGetType(lite3.root, 99);
    const ai = arr.arrGetI64(lite3.root, 99);
    try testing.expectEqual(@as(anyerror!void, if (at) |_| {} else |e| e), @as(anyerror!void, if (ai) |_| {} else |e| e));
}
```

<details><summary>Output on b7cb2b9</summary>

```
Current code:
  failed: API-3 trunc: getI64=error.InvalidArgument getType=error.NotFound exists=false
  failed: API-3 arr: getType=error.NotFound getI64=error.InvalidArgument arrGetType(99)=error.NotFound arrGetI64(99)=error.InvalidArgument
Both tests still fail after the ALC-1 and API-1 fixes, as expected. The fix is not prototyped.
```
</details>

**Fix sketch:** The root cause is _lite3_get_type_impl (vendor/lite3/include/lite3.h:1779-1787). It collapses both _lite3_verify_obj_get failure and lite3_get_impl failure into LITE3_TYPE_INVALID. lite3_exists does the same with bool. Add shims shim_lite3_get_type_ex(buf,len,ofs,key,*out_type) and shim_lite3_ctx_get_type_ex. Each calls _lite3_verify_obj_get and lite3_get_impl and returns the errno-coded int (-1 with errno ENOENT for absent, EINVAL/EFAULT otherwise), and the arr_get_type equivalent does the same. Then in src/lite3.zig:370-392 and 730-741: getType maps ENOENT to NotFound and everything else through translateError. exists becomes `Error!bool`: false only on ENOENT, error otherwise; it already returns Error!bool, so the signature stays the same and only the semantics change. arrGetType returns the same error as arrGetI64 for OOB. getValue inherits the fix. Consider removing Type.invalid from the public enum. Blast radius: shim.c/.h, 3 SharedMethods functions plus their Managed/External forwarders. There is a behaviour change: callers that relied on exists()==false for malformed input will now see errors.

## API-4 — Corrupt data and every JSON-encode failure, including a too-small output buffer, come back as error.Unexpected
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-14, PRF-8, API-2

```zig
// src/repro.zig (scratch: wf/repro-3/repo), wired via build.zig step `zig build repro`
const std = @import("std"); const testing = std.testing; const lite3 = @import("lite3");

test "API-4a jsonEncodeBuf too-small output reports NoBufferSpace" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "abc", 123456);
    var out: [4]u8 = undefined;
    try testing.expectError(lite3.Error.NoBufferSpace, buf.jsonEncodeBuf(lite3.root, &out));
}

test "API-4b jsonEncodeBuf with exact-size output succeeds" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "abc", 123456);
    const js = try buf.jsonEncode(lite3.root);
    defer js.deinit();
    var out: [512]u8 = undefined;
    const n = try buf.jsonEncodeBuf(lite3.root, out[0..js.slice().len]);
    try testing.expectEqualStrings(js.slice(), out[0..n]);
}

test "API-4c NaN encode yields a specific error, not Unexpected" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setF64(lite3.root, "x", std.math.nan(f64));
    const r = buf.jsonEncode(lite3.root);
    if (r) |js| js.deinit() else |_| {}
    try testing.expect(std.meta.isError(r));
    try testing.expect((r catch |e| e) != lite3.Error.Unexpected);
}

test "API-4d truncated document reports CorruptData, not Unexpected" {
    var mem: [65536]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    var kb: [16]u8 = undefined;
    for (0..200) |i| try buf.setI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), @intCast(i));
    var t = try lite3.Buffer.fromSerialized(&mem, buf.len / 2); // truncated message
    var unexpected: usize = 0; var corrupt: usize = 0;
    for (0..200) |i| {
        _ = t.getI64(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i})) catch |e| switch (e) {
            error.Unexpected => unexpected += 1, error.CorruptData => corrupt += 1, else => {},
        };
    }
    try testing.expectEqual(@as(usize, 0), unexpected);
    try testing.expect(corrupt > 0);
}
```

<details><summary>Output on b7cb2b9</summary>

```
error: 'repro.test.API-4a jsonEncodeBuf too-small output reports NoBufferSpace' failed: API-4a small out -> error.Unexpected
error: 'repro.test.API-4b jsonEncodeBuf with exact-size output succeeds' failed: API-4b json len=14 smallest working out=48; exact -> error.Unexpected
error: 'repro.test.API-4c NaN encode yields a specific error, not Unexpected' failed: API-4c NaN encode -> error.Unexpected
error: 'repro.test.API-4d truncated document reports CorruptData, not Unexpected' failed: API-4d truncated: Unexpected=199 CorruptData=0
(grep: 9 `errno = EFAULT` sites in vendor/lite3/src/lite3.c:136,154,188,202,211,292,352,434,733, all bounds checks; 5 `errno = EIO` in json_enc.c:237-306)
```
</details>

**Fix sketch:** src/lite3.zig:86 mapErrno: map .FAULT => CorruptData; map .MSGSIZE/.OVERFLOW => a new DocumentTooLarge (keep NOBUFS => NoBufferSpace). Add a JSON encode error set (e.g. `JsonEncodeError = Error || error{NoSpaceLeft, NonFiniteNumber, InvalidUtf8}`). json_enc.c discards yyjson_write_err.code and sets EIO, so either (a) patch the vendored json_enc.c (or reimplement lite3_json_enc_buf in the shim by calling yyjson directly) so the yyjson code passes through, or (b) better, replace jsonEncodeBuf with a pure-Zig encoder that writes to std.Io.Writer (Writer.fixed makes exact-size buffers work and returns error.WriteFailed/NoSpaceLeft). At minimum, document the ~34-42 byte yyjson headroom (a 14-byte JSON needed 48 bytes) and return NoBufferSpace when out.len is below the required size. Blast radius: Error set changes (API break: callers matching on Unexpected), src/lite3.zig mapErrno + jsonEncode/jsonEncodePretty/jsonEncodeBuf on Buffer/Managed/External, possibly vendor/lite3/src/json_enc.c (a local patch that must be recorded, see BLD-2). Tests: API-4a..d above.

## API-5 — StaleReference is effectively dead; real staleness shows up as InvalidArgument or, for a Context iterator, a use-after-free
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-5, MEM-6, SEC-9

```zig
test "API-5a Buffer iterator after mutation reports StaleReference" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "a", 1);
    try buf.setI64(lite3.root, "b", 2);
    var it = try buf.iterate(lite3.root);
    try buf.setI64(lite3.root, "c", 3);
    try testing.expectError(lite3.Error.StaleReference, it.next());
}

test "API-5b Context iterator after growth: no UAF, reports StaleReference" {
    var ctx = try lite3.Context.initWithSize(1024);
    defer ctx.deinit();
    try ctx.resetObj(); // Context.initWithSize leaves root uninitialised (PRF-12)
    try ctx.setI64(lite3.root, "a", 1);
    var it = try ctx.iterate(lite3.root);
    const before = ctx.bufPtr();
    var kb: [16]u8 = undefined;
    for (0..200) |i| try ctx.setStr(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), "some string value here");
    try testing.expect(before != ctx.bufPtr());
    try testing.expectError(lite3.Error.StaleReference, it.next()); // run under valgrind too
}
```

<details><summary>Output on b7cb2b9</summary>

```
error: 'repro.test.API-5a ...' failed: API-5a next after mutate -> error.InvalidArgument
error: 'repro.test.API-5b ...' failed: API-5b buf moved=true / API-5b next after growth -> error.InvalidArgument
valgrind ./api5b (filtered test binary):
==29905== Invalid read of size 4
==29905==    at 0x11C4894: lite3_iter_next (lite3.c:371)
==29905==    by 0x1206391: shim_lite3_iter_next (lite3_shim.c:276)
==29905==    by 0x1039CCD: lite3.Iterator.next
==29905==    by 0x1037B59: repro.test.API-5b ... (repro.zig:90)
==29905==  Address 0x4b600a0 is 0 bytes inside a block of size 1,024 free'd
==29905==    at 0x484988F: free
==29905==    by 0x11C5B80: lite3_ctx_grow_impl (ctx_api.c:187)
==29905==    by 0x1206B8B: _lite3_ctx_set_str_n_impl (lite3_context_api.h:570)
```
</details>

**Fix sketch:** Iterator (src/lite3.zig:164-191) should stop caching `buf`/`buflen`. Store a type-erased owner reference instead (e.g. `ctx: *const anyopaque` plus a `getView: *const fn(*const anyopaque) struct{[*]const u8, usize}`, or make Iterator generic over the owner: `fn Iterator(comptime Doc: type) type { doc: *const Doc, ... }`). Re-read buf/len on every next(). lite3's gen check (lite3.c iter gen vs buffer gen) then catches the change without touching freed memory. In next(), map EINVAL from the gen mismatch to StaleReference. The shim can compare iter->gen against the buffer gen itself before calling lite3_iter_next, so this does not depend on errno. For ManagedContext/ExternalContext, point at the outer context (not the inner Buffer copy). Remove the unreachable `return Error.StaleReference` in getStr/getBytes (lite3.zig:447-448, 465-466), or turn it into `unreachable`/CorruptData. Document on getStr/getBytes that slices are borrowed until the next mutation of any kind. Blast radius: the Iterator type signature changes (API break if Iterator is named by users). Context.iterate becomes self-referential, so the Context must not be moved while iterating; document this. Tests: API-5a, API-5b (plus a valgrind CI job, see OPS-1).

## TST-1 — A failed write (NoBufferSpace) corrupts the document, and a test locks in the cause. It breaks growth in ManagedContext/ExternalContext and any doc over 16 MiB
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-1, CSH-2, ALC-1, ALC-9

```zig
test "TST-1a Buffer: NoBufferSpace must not corrupt existing keys (capacity sweep)" {
    var mem: [4096]u8 align(4) = undefined;
    var cap: usize = 200; var failures: usize = 0;
    while (cap <= 3000) : (cap += 4) {
        var buf = try lite3.Buffer.initObj(mem[0..cap]);
        var kb: [16]u8 = undefined; var n: usize = 0;
        while (true) : (n += 1) {
            buf.setStr(lite3.root, try std.fmt.bufPrint(&kb, "key{d}", .{n}), "0123456789abcdef") catch |e| {
                try testing.expectEqual(lite3.Error.NoBufferSpace, e); break;
            };
        }
        var bad: usize = 0;
        for (0..n) |i| {
            const v = buf.getStr(lite3.root, try std.fmt.bufPrint(&kb, "key{d}", .{i})) catch { bad += 1; continue; };
            if (!std.mem.eql(u8, v, "0123456789abcdef")) bad += 1;
        }
        if (bad != 0) failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "TST-1b ManagedContext: auto-growth keeps all data" {
    var mc = try lite3.ManagedContext.initWithCapacity(testing.allocator, 1024);
    defer mc.deinit();
    var kb: [16]u8 = undefined; var vb: [300]u8 = undefined; @memset(&vb, 'v');
    for (0..2000) |i| try mc.setStr(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}), vb[0 .. (i * 37) % 300]);
    for (0..2000) |i| {
        const v = try mc.getStr(lite3.root, try std.fmt.bufPrint(&kb, "k{d}", .{i}));
        try testing.expectEqual((i * 37) % 300, v.len);
    }
}

test "TST-1c ExternalContext: array appends across growth" {
    const gpa = testing.allocator;
    var ec = try lite3.ExternalContext.initWithCapacity(gpa, 1024);
    defer ec.deinit(gpa);
    _ = try ec.setArr(gpa, lite3.root, "a");
    const arr = try ec.getArr(lite3.root, "a");
    for (0..5000) |i| try ec.arrAppendI64(gpa, arr, @intCast(i));
    try testing.expectEqual(@as(u32, 5000), try ec.count(arr));
}
```

<details><summary>Output on b7cb2b9</summary>

```
TST-1a cap=484: 6/7 keys unreadable after NoBufferSpace
TST-1a cap=488: 6/7 keys unreadable after NoBufferSpace
TST-1a capacities with corruption: 95   (of 701 capacities swept)
TST-1b insert #1353 failed: error.Unexpected (len=261997 cap=1048576)
TST-1c append #399 failed: error.CorruptData

Fix validation (scratch copy wf/repro-3/fixed, restoreLen body replaced with `_ = self; _ = saved;`): TST-1a, TST-1b, TST-1c all PASS, and the original `zig build test` still passes 117/117. The existing test 'Buffer: mutation rollback preserves buffer length on NoBufferSpace' (src/tests.zig:1377) uses a 96-byte buffer where no split occurs, so it does not detect the removal.
```
</details>

**Fix sketch:** Delete saveLen/restoreLen (src/lite3.zig:229-239) and every `restoreLen(self, saved)` call in SharedMethods (all set*/arrAppend*). Keep the buflen value that the C library wrote back: upstream documents that a failed write may still advance buflen, and the split nodes it wrote are live and linked. Rewrite src/tests.zig:1377 to assert the opposite invariant (all prior keys still readable after NoBufferSpace, and len may grow). Add TST-1a/b/c as permanent regression tests, plus a model-based random-ops test (see TST-4) that sweeps several starting capacities. Blast radius: src/lite3.zig internal only, with no API change. ManagedContext/ExternalContext callWithGrowth then work as designed. Update the doc comment at lite3.zig:229-231, which gives the wrong rationale.

## TST-2 — Iterator keys have the wrong length (about 4x) and run past the buffer. Tests only check key != null
Reproduced: **True** · severity after repro: **critical** · same root cause: MEM-2, CSH-1, API-1, SEC-1, TST-11, TST-13

```zig
test "TST-2 iterator keys equal the inserted keys (1/63/64/200-byte keys)" {
    var mem: [8192]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const keys = [_][]const u8{ "x", "hello", "k" ** 63, "m" ** 64, "z" ** 200 };
    for (keys, 0..) |k, i| try buf.setI64(lite3.root, k, @intCast(i));
    var it = try buf.iterate(lite3.root);
    var seen: usize = 0;
    while (try it.next()) |e| {
        const k = e.key.?;
        var found = false;
        for (keys) |want| { if (std.mem.eql(u8, want, k)) found = true; }
        try testing.expect(found);
        seen += 1;
    }
    try testing.expectEqual(keys.len, seen);
}
```

<details><summary>Output on b7cb2b9</summary>

```
error: 'repro.test.TST-2 iterator keys equal the inserted keys (1/63/64/200-byte keys)' failed: TST-2 key.len=7
  (key "x": tag=(2<<2)|0=8, minus 1 = 7)
Fix validation (wf/repro-3/fixed): after decoding the length in shim_lite3_iter_next (`len = ((key.len+1) >> 2) - 1`, bounds-checked against buflen) and zero-initialising `lite3_str key = {0}`, TST-2 and SEC-1 PASS and the original suite passes 117/117. Side finding: with only the length fix, the existing test 'Buffer: array iterator' FAILED (EFAULT from my bounds check) because `key.ptr` for array iterators is uninitialised stack garbage (lite3_shim.c:275). This independently confirms MEM-3/CSH-4/SEC-10, so the two shim fixes must land together.
```
</details>

**Fix sketch:** src/lite3_shim.c:272-288 shim_lite3_iter_next: (1) `lite3_str key = {0};` (fixes the uninitialised read for arrays). (2) Decode the key size: lite3_iter_next leaves raw_tag-1 in key.len, so `uint32_t tag = key.len + 1; uint32_t len = (tag >> LITE3_KEY_TAG_KEY_SIZE_SHIFT) - 1;`. The robust alternative is to memcpy the tag bytes the way _verify_key does rather than relying on the -1 quirk. (3) Check `(p - buf) + len + 1 <= buflen` and `p[len] == 0`, otherwise errno=EBADMSG and return -1. In Zig, Iterator.next (src/lite3.zig:185) should also assert that the key slice ends within buf[0..buflen]. Report the bug upstream (upstream HEAD 48ab0e9 lite3.c:408-410 still has it), and patch vendor/lite3/src/lite3.c or keep the shim decode, recording the choice in the vendor manifest. Tests: TST-2, SEC-1, plus array-iterator tests asserting key==null and reading the value via val_offset. Blast radius: shim only. No API change, but Entry.key contents change (from wrong to right).

## BLD-2 — Vendored lite3 has no recorded provenance, carries an undocumented local patch, and is about 16 commits behind upstream, which has since fixed portability and correctness bugs
Reproduced: **True** · severity after repro: **high** · same root cause: MEM-7, CSH-8, OPS-6, SEC-5, CSH-7, SEC-6, SEC-7, BLD-14

```sh
#!/bin/sh
# Fails (exit 1) until a provenance manifest exists and update-vendor does real work.
set -e
R=/home/user/lite3-zig
ls $R/vendor/lite3/VENDORED.md $R/vendor/lite3/*.patch >/dev/null 2>&1 || { echo 'no provenance manifest/patch file'; exit 1; }
# identify the upstream base commit
cd /home/user/fastserial/lite3
for c in 0f38c36 874d89e 39d5e17 ac7fc19 d9d2e06 2834ba8; do n=0; for f in src/lite3.c src/json_enc.c src/json_dec.c include/lite3_context_api.h; do n=$((n+$(git show $c:$f | diff - $R/vendor/lite3/$f | wc -l))); done; echo "$c $n"; done
git show 0f38c36:include/lite3.h | diff - $R/vendor/lite3/include/lite3.h
git log --oneline 0f38c36..HEAD | wc -l
grep -n '^#define LITE3_PREFETCHING' include/lite3.h
```

<details><summary>Output on b7cb2b9</summary>

```
src/lite3.c, json_enc.c, json_dec.c, ctx_api.c, debug.c, lite3_context_api.h: 0 diff lines vs upstream 0f38c36.
Source-identical over 0f38c36 874d89e 39d5e17 ac7fc19 d9d2e06 (0 lines each; the intervening commits are README/tests only). 2834ba8: 30 lines, so the base is d9d2e06-or-earlier source.
include/lite3.h diff:
184c184,186
< #define LITE3_PREFETCHING
---
> #ifndef LITE3_DISABLE_PREFETCHING
> #define LITE3_PREFETCHING
> #endif
(+ EOF newline)
git log 0f38c36..HEAD: 16 commits, including 2834ba8 (C23 label), 69d8461 (memcpy portability), 8a4fca6 (iterator target_ofs), 7b62398 (_verify_key size check), da01893 (align nodes on overwrite), 66bb52a (invalidate refs after nested mutation).
Upstream HEAD include/lite3.h:184: `#define LITE3_PREFETCHING` (unguarded). build.zig:107 relies on LITE3_DISABLE_PREFETCHING.
Justfile:39-40 update-vendor: `@echo "Vendored sources are in vendor/lite3/. Update manually from upstream."`
No VENDORED/manifest file exists. Extra: vendor/lite3/lite3.pc is git-tracked (build artefact), and untracked json_dec.o/json_enc.o/lite3.o now sit in the working tree.
```
</details>

**Fix sketch:** Add vendor/lite3/VENDORED.md (or vendor.zon) that records the upstream URL, the exact commit (re-vendor to 48ab0e9 or newer) and the list of copied paths. Keep local changes as vendor/patches/0001-disable-prefetch-guard.patch (and a shim-side or C patch for the TST-2 key length). Replace Justfile update-vendor with a script that clones at the pinned commit, copies only src/*.c, include/*.h, lib/yyjson, lib/nibble_base64 and LICENSE, applies the patches, and fails if a patch does not apply. Remove the tracked lite3.pc and the untracked .o files, and add them to .gitignore. After re-vendoring, re-run the full suite plus the TST-1/TST-2/API-4/API-5 repro tests and a Debug-C/UBSan build. Upstream 66bb52a changes invalidation behaviour that iterator/reference tests may depend on. Upstream the LITE3_DISABLE_PREFETCHING guard. Longer term, take lite3 as a build.zig.zon dependency (url+hash) and apply the patches at build time, or drop them. Blast radius: vendor/, Justfile, .gitignore, and possibly behaviour changes from the upstream fixes (CSH-7/SEC-6/SEC-7/SEC-9 get fixed).

## SEC-1 — Iterator Entry.key has the wrong length (raw key tag minus 1), so every object key slice runs past the key and can read past the end of the buffer
Reproduced: **True** · severity after repro: **critical** · same root cause: TST-2, MEM-2, CSH-1, API-1

```zig
test "SEC-1 iterator key slice stays inside an exact-size heap buffer" {
    var mem: [1024]u8 align(4) = undefined;
    var src = try lite3.Buffer.initObj(&mem);
    try src.setI64(lite3.root, "z" ** 200, 1);
    const n = src.len;
    const heap = try std.heap.c_allocator.alignedAlloc(u8, .@"4", n);
    defer std.heap.c_allocator.free(heap);
    @memcpy(heap, mem[0..n]);
    var buf = try lite3.Buffer.fromSerialized(heap, n);
    var it = try buf.iterate(lite3.root);
    const e = (try it.next()).?;
    const k = e.key.?;
    const end = @intFromPtr(k.ptr) + k.len;
    const last: *volatile const u8 = &k[k.len - 1];
    _ = last.*; // valgrind: invalid read past the heap block
    try testing.expect(end <= @intFromPtr(heap.ptr) + n);
    try testing.expectEqual(@as(usize, 200), k.len);
}
```

<details><summary>Output on b7cb2b9</summary>

```
error: 'repro.test.SEC-1 ...' failed: SEC-1 buflen=308 key.len=804 key_end-buf=902
valgrind ./sec1:
==29924== Invalid read of size 1
==29924==    at 0x1036E02: repro.test.SEC-1 iterator key slice stays inside an exact-size heap buffer (repro.zig:198)
==29924== ERROR SUMMARY: 1 errors from 1 contexts
Passes after the shim fix described in TST-2 (wf/repro-3/fixed).
```
</details>

**Fix sketch:** Same root cause and fix as TST-2: decode the tag in shim_lite3_iter_next (src/lite3_shim.c:279-282), zero-init lite3_str, bounds-check ptr+len+1 <= buflen and ptr[len]==0, and add a Zig-side slice-in-bounds check in Iterator.next (src/lite3.zig:185). Do not use plain strlen (corrupt input can lack a NUL, see SEC-3). Report upstream. Blast radius: shim only.

## SEC-2 — A string with stored size 0 underflows to len=0xFFFFFFFF, so getStr/arrGetStr return a 4 GiB slice (OOB read or segfault from a single malicious byte)
Reproduced: **True** · severity after repro: **critical** · same root cause: CSH-3

```zig
// src/repro4_tests.zig (scratch: <scratch>/repro-4/repo/src/repro4_tests.zig), wired into build.zig as a `repro` test step importing module "lite3".
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

fn expectSliceInside(s: []const u8, doc: []const u8) !void {
    const lo = @intFromPtr(doc.ptr);
    const hi = lo + doc.len;
    const p = @intFromPtr(s.ptr);
    if (p < lo or p + s.len > hi) {
        std.debug.print("slice [0x{x}, +{d}) escapes document [0x{x}, +{d})\n", .{ p, s.len, lo, doc.len });
        return error.SliceOutOfBounds;
    }
}

fn zeroStrSize(doc: []u8, needle: []const u8) !void {
    const i = std.mem.indexOf(u8, doc, needle) orelse return error.NeedleMissing;
    @memset(doc[i - 4 .. i], 0); // u32 size field (was 07 00 00 00)
}

test "SEC-2: getStr on a stored string size of 0 must not return a slice past the buffer" {
    var mem: [256]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "k", "abcdef");
    try zeroStrSize(mem[0..buf.len], "abcdef\x00");
    const view = try lite3.Buffer.fromSerialized(&mem, buf.len);
    const s = view.getStr(lite3.root, "k") catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    try expectSliceInside(s, view.data());
}

test "SEC-2: arrGetStr on a stored string size of 0 must not return a slice past the buffer" {
    var mem: [256]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initArr(&mem);
    try buf.arrAppendStr(lite3.root, "abcdef");
    try zeroStrSize(mem[0..buf.len], "abcdef\x00");
    const s = buf.arrGetStr(lite3.root, 0) catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    try expectSliceInside(s, buf.data());
}

test "SEC-2: Context.initFromBuf of a corrupted buffer, getStr must not return a 4 GiB slice" {
    var mem: [256]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "k", "abcdef");
    try zeroStrSize(mem[0..buf.len], "abcdef\x00");
    var ctx = try lite3.Context.initFromBuf(mem[0..buf.len]);
    defer ctx.deinit();
    const s = ctx.getStr(lite3.root, "k") catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    try expectSliceInside(s, ctx.data());
}
```

<details><summary>Output on b7cb2b9</summary>

```
string size field before corruption: 07000000
SEC-2 getStr len=4294967295 buflen=111
slice [0x7ffec713d760, +4294967295) escapes document [0x7ffec713d6f8, +111)
SEC-2 arrGetStr len=4294967295 buflen=108
slice [0x7ffec713d75d, +4294967295) escapes document [0x7ffec713d6f8, +108)
SEC-2 ctx getStr len=4294967295 buflen=111
slice [0x2f649338, +4294967295) escapes document [0x2f6492d0, +111)
All 3 tests fail. They fail the same way when the vendored C is replaced with upstream HEAD 48ab0e9, so re-vendoring does not fix this.
```
</details>

**Fix sketch:** Root cause: vendor/lite3/include/lite3.h:2347-2348 (_lite3_get_str_impl) and :2580-2581 (_lite3_arr_get_str) do `--out->len` on an unvalidated u32, and _verify_val does not require size>=1 for strings. The wrapper (src/lite3.zig:437-449 getStr, :675 arrGetStr, plus getBytes/arrGetBytes/getStrCopy/getValue and Iterator.next at :185) builds p[0..len] with no bounds check.
Fix (wrapper, defensive): add one helper to SharedMethods, e.g. `fn checkedSlice(self, p: [*]const u8, len: usize, nul: bool) Error![]const u8`. It checks p >= base, p+len(+1 if nul) <= base+buflen, and base[p+len]==0 for strings, and returns CorruptData otherwise. base/buflen come from self.buf/self.len, or from shim_lite3_ctx_buf/buflen for Context. Route every slice-returning getter and the iterator key through it. ManagedContext/ExternalContext forward to Buffer, so they inherit the check. Fix (C, local patch + upstream PR): in the shim, or better in _verify_val, reject STRING with size==0 (EBADMSG). lite3_val_str_n (json_enc path) has the same underflow, so patch json_enc too or add a validate() pre-pass. Blast radius: src/lite3.zig and src/lite3_shim.c (plus an optional vendor patch). No API break, since CorruptData already exists. Add these 3 tests to src/tests.zig.

## SEC-3 — jsonEncode reads keys with strlen(), so an unterminated key in a malicious buffer causes a heap over-read and copies adjacent memory into the JSON output
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-11

```zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "SEC-3: jsonEncode must not read past buflen when a key's NUL terminator is overwritten" {
    var mem: [512]u8 align(4) = undefined;
    @memset(&mem, 0);
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setI64(lite3.root, "kk", 0x0101010101010101);
    const n = buf.len;
    const i = std.mem.indexOf(u8, mem[0..n], "kk\x00") orelse return error.NeedleMissing;
    mem[i + 2] = 'x';
    // Bytes that do NOT belong to the document, right after buflen.
    @memcpy(mem[n .. n + 8], "SECRET!!");
    const view = try lite3.Buffer.fromSerialized(&mem, n);
    const js = view.jsonEncode(lite3.root) catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    defer js.deinit();
    try testing.expect(std.mem.indexOf(u8, js.slice(), "SECRET") == null);
}
```

<details><summary>Output on b7cb2b9</summary>

```
SEC-3 buflen=109 json={"kkx\u0002\u0001\u0001\u0001\u0001\u0001\u0001\u0001\u0001SECRET!!":72340172838076673}
error: 'SEC-3 ...' failed (expect at repro4_tests.zig:82)
The bytes placed after buflen ("SECRET!!") appear in the JSON output, so the read past buflen deterministically leaks data into the output, without needing valgrind. It still fails with upstream HEAD 48ab0e9 vendored.
```
</details>

**Fix sketch:** Root cause: vendor/lite3/src/json_enc.c:153 passes LITE3_STR(buf,key) to yyjson_mut_str(), which calls strlen. _verify_key checks only that the declared key size fits, not that key[size-1]==0. Fix: (a) local vendor patch + upstream PR: in _verify_key require buf[key_start+key_size-1]==0 (EBADMSG), because the iterator and other LITE3_STR users also assume termination. Also use yyjson_mut_strn(doc, key, key_size-1) in json_enc. (b) Wrapper: a Buffer/Context.validate() pre-pass (see SEC-4/SEC-16) that checks key NULs, and document that jsonEncode on untrusted bytes requires validate(). Blast radius: vendor/lite3/src/lite3.c and json_enc.c (record the patch in the provenance file, see SEC-5), plus optionally src/lite3.zig. No API change.

## SEC-4 — A crafted ~1 KB buffer amplifies without bound: shared child/kv offsets turn iterate() into ~1e9 items and jsonEncode into 100 MB+ of output (CPU and memory DoS)
Reproduced: **True** · severity after repro: **high** · same root cause: SEC-16

```zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

fn rdU32(b: []u8, o: usize) u32 { return std.mem.readInt(u32, b[o..][0..4], .little); }
fn wrU32(b: []u8, o: usize, v: u32) void { std.mem.writeInt(u32, b[o..][0..4], v, .little); }
/// Turn a real B-tree into a DAG: every node gets 7 keys with identical kv_ofs and
/// (internal nodes) 8 identical child_ofs. No bytes are added.
/// struct node layout: gen_type@0, hashes[7]@4, size_kc@32, kv_ofs[7]@36, child_ofs[8]@64.
fn dagify(b: []u8, node: usize) usize {
    const child0 = rdU32(b, node + 64);
    const kv0 = rdU32(b, node + 36);
    const skc = rdU32(b, node + 32);
    wrU32(b, node + 32, (skc & ~@as(u32, 7)) | 7);
    var k: usize = 0;
    while (k < 7) : (k += 1) wrU32(b, node + 36 + 4 * k, kv0);
    if (child0 == 0) return 1;
    k = 0;
    while (k < 8) : (k += 1) wrU32(b, node + 64 + 4 * k, child0);
    return 1 + dagify(b, child0);
}

fn buildDag(alloc: std.mem.Allocator, nkeys: usize) !struct { mem: []align(4) u8, len: usize, height: usize } {
    const mem = try alloc.alignedAlloc(u8, .@"4", 64 * 1024 * 1024);
    var buf = try lite3.Buffer.initObj(mem);
    var kb: [16]u8 = undefined;
    for (0..nkeys) |i| {
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        try buf.setI64(lite3.root, k, @intCast(i));
    }
    const h = dagify(mem[0..buf.len], 0);
    return .{ .mem = mem, .len = buf.len, .height = h };
}

test "SEC-4: iterate() on a crafted DAG buffer must be bounded by buffer size" {
    const alloc = std.heap.page_allocator;
    const d = try buildDag(alloc, 20000);
    defer alloc.free(d.mem);
    const view = try lite3.Buffer.fromSerialized(d.mem, d.len);
    var it = view.iterate(lite3.root) catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    var items: usize = 0;
    while (true) {
        const e = it.next() catch |err| {
            try testing.expectEqual(lite3.Error.CorruptData, err);
            return;
        };
        if (e == null) break;
        items += 1;
    }
    const cnt = try view.count(lite3.root);
    try testing.expect(items <= d.len);
    try testing.expect(items == cnt);
}

test "SEC-4: jsonEncode on a crafted DAG buffer must not amplify unboundedly" {
    const alloc = std.heap.page_allocator;
    const d = try buildDag(alloc, 3000);
    defer alloc.free(d.mem);
    const view = try lite3.Buffer.fromSerialized(d.mem, d.len);
    const js = view.jsonEncode(lite3.root) catch |e| {
        try testing.expectEqual(lite3.Error.CorruptData, e);
        return;
    };
    defer js.deinit();
    try testing.expect(js.len <= 4 * d.len);
}
```

<details><summary>Output on b7cb2b9</summary>

```
SEC-4 buflen=971496 height=7 count()=20000 iterated=2097151 in 190 ms   (8^7-1 items from a 950 KB doc; count() disagrees)
error: 'SEC-4: iterate() ...' failed at `expect(items <= d.len)`
SEC-4 json: buflen=142564 height=6 output=1843444 bytes (12x)   (a 3000-key doc whose honest JSON is ~45 KB)
error: 'SEC-4: jsonEncode ...' failed at `expect(js.len <= 4 * d.len)`
Growth is 8^height. At height 9 (the LITE3_TREE_HEIGHT_MAX limit) this is ~1.3e8-1e9 items. Both tests still fail with upstream HEAD vendored. I did not reproduce the reviewer's hand-crafted 972-byte buffer. The mutated real tree shows the same mechanism.
```
</details>

**Fix sketch:** Root cause: lite3_iter_next (vendor/lite3/src/lite3.c:380-470) and _lite3_json_enc_obj/arr (json_enc.c:134-190) bound only the depth and each offset. They never check that child_ofs/kv_ofs form a tree, and count() reads the independent size field in size_kc. Fix: add `pub fn validate(self) Error!void` to SharedMethods (src/lite3.zig). It walks the tree once with an explicit stack (depth <= 9 per container, nesting <= 32) and keeps a visited bitset of size buflen/4. It rejects a node or kv offset seen twice, offsets that are unaligned or out of range, key_count>7, unsorted hashes, a mismatch between the sum of key_counts and the size field, key tags with no NUL at key_end-1 (SEC-3), and string size 0 (SEC-2). Return CorruptData. Call it optionally from fromSerialized/initFromBuf/importFromBuf (e.g. a `fromSerializedValidated`, or a `.validate = true` option), and document the trust boundary (SEC-16). Cheap interim guard in Iterator.next: count items and return CorruptData once items > buflen/min_entry_size. Blast radius: src/lite3.zig (new API, additive) and tests. No C change is needed if validate() is in Zig.

## SEC-5 — Vendored lite3 is pinned at upstream ac7fc19 plus an undocumented local patch, is missing 9 upstream fix commits, and has no provenance record or update procedure
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-8, BLD-2, OPS-6, MEM-7

```sh
#!/bin/sh
# repro/check-vendor.sh - fails today, passes once provenance is recorded and the pin is current.
set -e
cd /home/user/lite3-zig
# 1. A provenance record must exist
ls vendor/lite3 | grep -qiE '^(VENDOR|UPSTREAM)' || { echo 'FAIL: no provenance record in vendor/lite3'; exit 1; }
# 2. The recorded SHA must equal the vendored content (+ recorded patches)
SHA=$(sed -n 's/^commit: *//p' vendor/lite3/VENDOR.md)
T=$(mktemp -d); git -C ../fastserial/lite3 archive "$SHA" src include lib | tar -x -C "$T"
for p in vendor/patches/*.patch; do (cd "$T" && patch -p1 -s < "$OLDPWD/$p"); done
for d in src include lib; do diff -r "$T/$d" vendor/lite3/$d; done
# 3. Upstream fixes known to be reachable (da01893 alignment, 66bb52a, 7b62398) must be included
git -C ../fastserial/lite3 merge-base --is-ancestor da01893 "$SHA" || { echo 'FAIL: pin predates da01893'; exit 1; }
```

<details><summary>Output on b7cb2b9</summary>

```
$ ls vendor/lite3 | grep -iE 'vendor|upstream|patch|version'   -> (nothing), exit 1
$ grep -rn ac7fc19 .   -> no hits in the tree (recorded only in commit bdf2331's message)
$ diff -r <upstream ac7fc19 archive>/{src,include,lib} vendor/lite3/...
  include/lite3.h 184c184,186: `#define LITE3_PREFETCHING` -> wrapped in `#ifndef LITE3_DISABLE_PREFETCHING` (undocumented local patch); 3076: EOF newline. Nothing else differs.
$ git log --oneline ac7fc19..HEAD | wc -l  -> 13 (d9d2e06 ... 48ab0e9, incl. 7b62398, da01893, 66bb52a)
Justfile:39-40 update-vendor only echoes "Update manually from upstream."
Also: vendor/lite3/Makefile and lite3.pc are tracked, and there are stray untracked vendor/lite3/*.o in the working tree.
Bump experiment: replaced vendor/lite3/{src,include,lib} with upstream HEAD 48ab0e9 and re-applied the prefetch guard. `zig build test` gives 117/117 passed. SEC-6 repro tests now pass (nested ofs=104, mod4=0), including under C Debug + sanitize_c=full (2/2 passed, no UBSan panic). SEC-2/3/4/8 tests still fail at HEAD, as the finding states.
```
</details>

**Fix sketch:** 1) Bump vendor/lite3/{src,include,lib} to upstream 48ab0e9. Verified drop-in: all 117 existing tests pass and it fixes SEC-6. Keep the LITE3_DISABLE_PREFETCHING guard as vendor/patches/0001-prefetch-guard.patch, or drop the patch and inject the macro through a force-included header. 2) Add vendor/lite3/VENDOR.md with upstream URL, commit SHA, date, patch list, and yyjson (0.12.0) / nibble_base64 versions. 3) Replace Justfile update-vendor with scripts/update-vendor.sh <sha>: git archive the allow-listed dirs (src include lib LICENSE), apply patches, write the SHA, then run zig build test. Remove the tracked Makefile, lite3.pc, examples/, img/ and tests/ (or keep tests/ if TST-9 wires them up), and gitignore *.o. 4) Add a CI step that runs the check script above. 5) Upstream SEC-2/3/8 fixes as PRs. Blast radius: vendor/, Justfile, CI, README provenance note. No Zig API change.

## SEC-6 — Overwriting a long string value with setObj/setArr writes the node unaligned (UB); in ReleaseFast the alignment guard is optimized away (fixed upstream in da01893)
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-7

```zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "SEC-6: setObj over a long string value must place the node 4-byte aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const long = [_]u8{'x'} ** 127;
    try buf.setStr(lite3.root, "key", &long);
    const obj = try buf.setObj(lite3.root, "key");
    try buf.setI64(obj, "n", 3);
    try testing.expectEqual(@as(usize, 0), @intFromEnum(obj) % 4);
}

test "SEC-6: setArr over a long bytes value must place the node 4-byte aligned" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    const long = [_]u8{0xAB} ** 130;
    try buf.setBytes(lite3.root, "key", &long);
    const arr = try buf.setArr(lite3.root, "key");
    try testing.expectEqual(@as(usize, 0), @intFromEnum(arr) % 4);
}
// Optional sanitizer leg: build.zig option -Dc-debug that sets lite3_mod .optimize=.Debug,
// .sanitize_c=.full and addCMacro("LITE3_DISABLE_PREFETCHING","1").
```

<details><summary>Output on b7cb2b9</summary>

```
ReleaseFast C (current build): `SEC-6 len 234->246 nested ofs=101 mod4=1 get=3`, expected 0, found 1. setArr: `nested ofs=101 mod4=1`, expected 0, found 1. setI64/getI64 on the misaligned node still succeed, so the `& 3` alignment check is folded away.
C Debug + sanitize_c=full: `panic: member access within misaligned address 0x7ffc7f00517d for type 'struct node', which requires 4 byte alignment` at vendor/lite3/src/lite3.c:473 _lite3_init_impl <- lite3.c:800 lite3_set_obj_impl <- src/lite3_shim.c:137 <- src/lite3.zig:342 setObj.
With upstream HEAD 48ab0e9 vendored, both tests pass (ofs=104) in ReleaseFast and under UBSan.
```
</details>

**Fix sketch:** Re-vendor to upstream >= da01893 (see SEC-5); the in-place overwrite path in lite3_set_impl (vendor/lite3/src/lite3.c:691-716) then pads to alignment. Add both tests to src/tests.zig as regressions, and add a CI leg that builds the C library in Debug with sanitize_c=.full (and LITE3_DISABLE_PREFETCHING, because of the kv_ofs[7] prefetch UB) so this class of bug is caught. Separately, and upstream: move the `(uintptr_t)node & 3` check before __builtin_assume_aligned (lite3.c:250-256 and the other node walks) so crafted unaligned child offsets are rejected in release builds. Alternatively, the Zig validate() (SEC-4) can check alignment of every node offset. Blast radius: vendor/ bump, tests, build.zig/CI. No API change.

## SEC-8 — The JSON path bypasses the wrapper's NUL-in-key rejection: "a\u0000b" is silently truncated to "a" and overwrites the real key "a" (parser-differential key smuggling)
Reproduced: **True** · severity after repro: **high** · same root cause: CSH-18, MEM-11, API-8

```zig
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "SEC-8: JSON key with embedded NUL must be rejected, not truncated" {
    var mem: [4096]u8 align(4) = undefined;
    const r = lite3.Buffer.jsonDecode(&mem, "{\"a\\u0000b\":1}");
    if (r) |buf| {
        const js = try buf.jsonEncode(lite3.root);
        defer js.deinit();
        std.debug.print("SEC-8 decoded OK -> {s}\n", .{js.slice()});
        return error.TestExpectedError;
    } else |e| try testing.expectEqual(lite3.Error.InvalidArgument, e);
}

test "SEC-8: smuggled key \"a\\u0000b\" must not override real key \"a\"" {
    var mem: [4096]u8 align(4) = undefined;
    const buf = lite3.Buffer.jsonDecode(&mem, "{\"a\":2,\"a\\u0000b\":1}") catch return; // rejecting is fine
    try testing.expectEqual(@as(i64, 2), try buf.getI64(lite3.root, "a"));
}

test "SEC-8: a JSON-decoded key must be addressable through the Zig API (or rejected)" {
    var mem: [8192]u8 align(4) = undefined;
    var json: [300]u8 = undefined;
    const key = [_]u8{'k'} ** 256;
    const j = try std.fmt.bufPrint(&json, "{{\"{s}\":7}}", .{key});
    const buf = lite3.Buffer.jsonDecode(&mem, j) catch return;
    try testing.expectEqual(@as(i64, 7), try buf.getI64(lite3.root, &key));
}
```

<details><summary>Output on b7cb2b9</summary>

```
SEC-8 decoded OK -> {"a":1}          ("a\u0000b" silently stored as "a")
SEC-8 a=1 count=1                    ({"a":2,"a\u0000b":1}: the smuggled key overwrote the real "a"; expected 2, found 1)
SEC-8 256-byte key decoded (len=364) but getI64 -> InvalidArgument  (toKeyZ at src/lite3.zig:208-211 rejects >255 bytes)
All 3 fail on current code and with upstream HEAD 48ab0e9 vendored.
```
</details>

**Fix sketch:** Root cause: vendor/lite3/src/json_dec.c:48 passes yyjson_get_str(yy_key), which is NUL-terminated, to lite3_set_*, and those hash with strlen. Fix: local vendor patch (recorded per SEC-5) plus upstream PR. Take klen = yyjson_get_len(yy_key); if memchr(key,0,klen) finds a NUL, fail with EINVAL. Also enforce the same max key length the Zig API accepts. For the length half, pick one policy: raise max_key_len in src/lite3.zig:204 to lite3's real limit and use a heap/allocator path for long keys, or have json_dec reject keys over 255. Document the last-wins duplicate-key policy, or add a strict decode option. Blast radius: json_dec.c patch, src/lite3.zig toKeyZ (a changed limit is API-visible but additive), README docs, 3 new tests.

## SEC-16 — No threat model: fromSerialized/initFromBuf/importFromBuf accept arbitrary bytes with no validation and no documented trust boundary
Reproduced: **True** · severity after repro: **high** · same root cause: SEC-1, SEC-2, SEC-3, SEC-4, CSH-3, CSH-11, API-4, MEM-2, CSH-1, API-1

```zig
// src/sec16_test.zig (run by pointing build.zig test_mod root_source_file at it, or @import it from tests.zig)
const std = @import("std");
const testing = std.testing;
const lite3 = @import("lite3");

test "SEC-16: fromSerialized rejects a buffer shorter than one node" {
    var mem: [96]u8 align(4) = [_]u8{0} ** 96;
    try testing.expectError(lite3.Error.CorruptData, lite3.Buffer.fromSerialized(&mem, 1));
}

test "SEC-16: fromSerialized rejects garbage root type" {
    var mem: [96]u8 align(4) = [_]u8{0xFF} ** 96;
    try testing.expectError(lite3.Error.CorruptData, lite3.Buffer.fromSerialized(&mem, mem.len));
}

test "SEC-16: Context.initFromBuf rejects garbage" {
    var mem: [96]u8 align(4) = [_]u8{0xFF} ** 96;
    if (lite3.Context.initFromBuf(&mem)) |ctx_| {
        var ctx = ctx_;
        defer ctx.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "SEC-16: out-of-bounds offsets in a truncated doc report CorruptData, not Unexpected" {
    var mem: [4096]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    var i: usize = 0;
    var name: [8]u8 = undefined;
    while (i < 20) : (i += 1) {
        const k = try std.fmt.bufPrint(&name, "k{d}", .{i});
        try buf.setI64(lite3.root, k, @intCast(i));
    }
    const t = try lite3.Buffer.fromSerialized(&mem, 96); // truncated transfer
    try testing.expectError(lite3.Error.CorruptData, t.getI64(lite3.root, "k19"));
}

test "SEC-16: returned slices from untrusted bytes stay inside the buffer" {
    var mem: [1024]u8 align(4) = undefined;
    var buf = try lite3.Buffer.initObj(&mem);
    try buf.setStr(lite3.root, "k", "hello");
    const d = buf.data();
    const pos = std.mem.indexOf(u8, d, "hello\x00").?;
    @memset(mem[pos - 4 .. pos], 0); // stored string size 6 -> 0
    const t = try lite3.Buffer.fromSerialized(&mem, d.len);
    if (t.getStr(lite3.root, "k")) |s| {
        try testing.expect(@intFromPtr(s.ptr) + s.len <= @intFromPtr(&mem) + d.len);
    } else |e| {
        try testing.expect(e == lite3.Error.CorruptData);
    }
}
```

<details><summary>Output on b7cb2b9</summary>

```
zig build test (Zig 0.15.2, Debug wrapper, C lib ReleaseFast), scratch copy <scratch>/repro-5/repo:
+- run test 0/5 passed, 5 failed
error: '...fromSerialized rejects a buffer shorter than one node' failed: expected error.CorruptData, found .{ .buf = u8@7ffe664c9308, .len = 1, .capacity = 96 }
error: '...fromSerialized rejects garbage root type' failed: expected error.CorruptData, found .{ .buf = ..., .len = 96, .capacity = 96 }
error: '...Context.initFromBuf rejects garbage' failed: sec16_test.zig:23:9 return error.TestUnexpectedResult   (96 bytes of 0xFF accepted)
error: '...truncated doc report CorruptData, not Unexpected' failed: truncated getI64 -> error.Unexpected
  expected error.CorruptData, found error.Unexpected  (src/lite3.zig:80 mapErrno, .FAULT => Unexpected)
error: '...returned slices from untrusted bytes stay inside the buffer' failed: getStr len = 4294967295 (buffer len 110)
```
</details>

**Fix sketch:** Confirmed: Buffer.fromSerialized (src/lite3.zig:929-936) checks only 0 < used_len <= mem.len. A 1-byte document and a 96-byte 0xFF document are both accepted. Context.initFromBuf (src/lite3.zig:1055-1060) also accepts garbage. EFAULT, which lite3 uses for an out-of-bounds offset it detected (vendor/lite3/src/lite3.c:136,154,188,...), maps to Unexpected (src/lite3.zig:86). If one malicious byte changes, getStr returns a 4 GiB slice (this is the SEC-2 path). The README has only 'Safety notes' (README.md:255-276), which cover slice lifetime and threads; it says nothing about trust. Severity stays high: this is the root that enables SEC-1..4 on untrusted input, and it is easy to reach through the public constructors.

Fix:
(1) In fromSerialized, Context.initFromBuf, ManagedContext/ExternalContext.importFromBuf (src/lite3.zig:1259-1267 and the External twin) and Context.importFromBuf (src/lite3.zig:1107-1111), reject used_len < 96 (LITE3_NODE_SIZE) and a root type byte that is not object or array. Return CorruptData.
(2) Add `pub fn validate(self) Error!void`. It walks the tree iteratively and checks: every node and child offset is 4-aligned and in bounds; key tags and lengths are in bounds; keys are NUL-terminated; string size >= 1 and the slice ends <= len; there are no shared or cyclic child/kv offsets (track visited offsets with a bitset, or require strictly increasing offsets); tree height <= 9. This also bounds the work for SEC-4. Make the constructors call it by default, and add fromSerializedTrusted / initFromBufTrusted for callers that want zero-copy without checks.
(3) In the Zig getStr/getBytes/arrGet*/Iterator, check every returned slice against [buf, buf+len), so that an error comes back even when validate was skipped.
(4) Map .FAULT to CorruptData on read paths, or add a distinct Error.OutOfBounds. On write paths EFAULT can be a caller-bug offset.
(5) Add a README 'Security / trust boundary' section that states what is and is not guaranteed for untrusted buffers and for JSON input.

Blast radius: src/lite3.zig (constructors, mapErrno, slice getters, new validate), README.md, tests. The behaviour change in mapErrno (Unexpected -> CorruptData) is observable but is a 0.x change. Validating by default costs one O(n) pass per import.
