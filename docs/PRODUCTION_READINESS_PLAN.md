# lite3-zig — Production-Readiness Review & Plan

Review date: 2026-10-01 · Reviewed commit: `b7cb2b9` · Toolchain reviewed: Zig 0.15.2 (also probed 0.16.0) · Target toolchain: Zig 0.17.0 via mise

## 1. Verdict

**Not production-ready yet.** The current suite passes all 117 tests with JSON on and off, and `zig fmt` is clean. Even so, the review found real bugs:

- **Data corruption.** The allocator-backed contexts corrupt or reject documents during ordinary growth. `ManagedContext` and `ExternalContext` cannot hold a 5,000-element nested array, or 7 keys plus one large value.
- **Out-of-bounds reads.** The iterator returns every object key with the wrong length. A single flipped byte in a received buffer makes `getStr` return a 4 GiB slice.
- **Use-after-free.** Copying a value from one field of a document into another field of the same document reads freed memory once the document grows.

The test suite does not catch these bugs. In mutation testing it caught 4 of 21 injected bugs. Several tests encode the buggy behaviour. CI never builds the C code with sanitizers.

The good news is that most fixes are small and local. The C library's own bounds checks are mostly sound. The architecture (a thin C shim plus a Zig façade) is the right one. The work is mostly sequencing.

## 2. Method

There were nine independent reviewers, one per dimension, each working in its own scratch copy so it could build, run, valgrind, cross-compile and mutate the code:

1. memory safety and lifetimes
2. C shim and hidden undefined behaviour (UB)
3. allocator-backed contexts
4. API and error model
5. tests and fuzzing
6. build, packaging and portability
7. CI and docs
8. vendored-code drift and untrusted-input security
9. performance

Each reviewer's batch then went to an adversarial verifier. Every critical or high finding was independently reproduced a second time as a failing test. A completeness critic then looked for gaps. The 158 raw findings were all confirmed or rated plausible, and none were refuted. They collapse to about 60 distinct issues, listed in §8.

Tools used: Zig 0.15.2 and 0.16.0, valgrind, Debug-C with UBSan, clang/gcc with ASan and UBSan, a git clone of upstream `fastserial/lite3` at `48ab0e9`, mutation testing, and `std.testing.checkAllAllocationFailures`.

## 3. What is sound (do not "fix")

- **Bounds checks on offsets.** The C library bounds-checks start offsets, child offsets and key/value extents. 3,000 forged-offset trials and 5,000 random buffers produced no invalid reads under valgrind, apart from the iterator and string-length bugs below.
- **Key handling.** `toKeyZ` rejects keys with an embedded NUL, makes a bounded stack copy, and is safe when the key aliases the document. Values use the length-taking `*_n` setters, so values with embedded NULs round-trip.
- **Lifecycle.** `deinit` is idempotent. A use after `deinit` returns `InvalidState`. Returning a context by value from `init` is sound. `grow()` updates state only after `realloc` succeeds.
- **Alignment and conversions.**
  - Alignment is enforced at the type level (`[]align(4) u8`).
  - `mapErrno` uses `std.math.cast`.
  - The size of `shim_lite3_iter` is checked with a `_Static_assert`.
  - The `-Djson=false` stubs are type-checked against `lite3.h`.
- **No leaks on the happy path.** Valgrind reports 207 allocations and 207 frees. JSON nesting is capped at 32, so hostile JSON cannot exhaust the stack.
- **The core library builds and runs on more targets than CI checks.** It builds on Zig 0.16.0 unchanged, and it cross-compiles to musl, arm, riscv64, macOS and wasm32-wasi.

## 4. Root-cause clusters (deduplicated, severity after verification)

Reviewer IDs in brackets; full register in §8.

### Critical

| # | Issue | Evidence | IDs |
|---|---|---|---|
| C1 | **`saveLen`/`restoreLen` rolls back `len` after lite3 has already split a node.** The tree then points at orphaned nodes past `len`. `callWithGrowth` hits this on almost every growth: the retry walks into the orphan and returns `Unexpected`. A test (`tests.zig:1377`) locks the bug in. | Re-verified in this session. A Buffer probe found 468 unreadable keys. Managed: 5,000 `arrAppendI64` into a nested array fail. External: 7 keys plus a 2 KB string fail. | MEM-1, CSH-2, ALC-1, TST-1 |
| C2 | **The iterator key length is the raw key tag minus 1**, about 4× too long. This is an upstream bug in `lite3_iter_next` (`lite3.c:403`), still present at upstream HEAD. Every `Entry.key` carries trailing garbage, and near the end of the buffer it reads out of bounds on the heap. The tests only check `key != null`. | Re-verified: `"x"` comes back with length 7. | CSH-1, MEM-2, API-1, SEC-1, TST-2 |
| C3 | **A string with a stored size of 0 underflows to `len = 0xFFFFFFFF`** in `_lite3_get_str_impl` and `_lite3_arr_get_str`. `getStr` and `arrGetStr` then return a 4 GiB slice from an untrusted buffer. Still present upstream. | A one-byte flip of a valid document reproduces it. | SEC-2, CSH-3 |
| C4 | **A value that aliases the same document causes use-after-free or silent zeroing.** For example, `setStr(root,"b", try getStr(root,"a"))`: the source is freed by realloc during the retry, or zeroed by `LITE3_ZERO_MEM_DELETED` before the `memcpy`. | Segfault in Managed. Valgrind invalid read in Context. Zeroed value in Buffer. | MEM-4, CSH-5 |

### High

| # | Issue | IDs |
|---|---|---|
| H1 | The vendored lite3 has no recorded provenance. Its files match upstream from `874d89e` to `218c262` (2026-01-07 to 2026-03-02), plus an undocumented local prefetch guard. It is missing upstream fixes `3cdbc2c`, `69d8461`, `8a4fca6`, `7b62398`, `da01893` and `66bb52a`. One consequence: `setObj`/`setArr` over a long string writes an unaligned node (UB, upstream `da01893`). Another: `{"":null}` cannot be read back (upstream `7b62398`). | BLD-2, SEC-5, MEM-7, CSH-7, SEC-6, SEC-7, CSH-8, OPS-6 |
| H2 | `shim_lite3_iter_next` reads an uninitialised `lite3_str`, so array iterators can report a stale key. Valgrind confirms it. | MEM-3, CSH-4, SEC-10, OPS-1 |
| H3 | An iterator captures the raw buffer pointer, so `next()` after growth reads freed memory. `StaleReference` is dead code, and borrowed slices have no lifetime docs. | MEM-5, API-5, MEM-6, SEC-9 |
| H4 | When `Context.importFromBuf` fails to allocate, it has already freed the old buffer (upstream `ctx_api.c`). Later reads use freed memory and `deinit` double-frees. | ALC-3, CSH-9, MEM-10 |
| H5 | `jsonDecode` is not atomic. A failure leaves Managed/External with a stale `len` over a reset root, and Context silently loses its old contents. A scalar root reports success. | ALC-2, API-15, MEM-9, CSH-15, SEC-11, TST-6 |
| H6 | The error model hides failures: <ul><li>`getType`, `arrGetType` and `exists` turn corruption into `NotFound`/`false`.</li><li>Corrupt data and all JSON-encode failures, including a too-small `jsonEncodeBuf` output, become `Unexpected`.</li><li>`InvalidArgument` covers at least 9 different conditions.</li></ul> | API-3, CSH-13, API-4, CSH-14, API-2 |
| H7 | Untrusted-input posture: <ul><li>There is no threat model and no `validate()`.</li><li>A crafted 1 KB buffer that reuses child offsets makes `iterate()` yield millions of entries and `jsonEncode` produce 12× more output than the honest document.</li><li>`jsonEncode` reads keys with `strlen`, so an unterminated key causes an over-read.</li><li>The JSON path silently truncates `"a\u0000b"` to `"a"`, bypassing the wrapper's NUL-in-key rejection.</li></ul> | SEC-16, SEC-4, SEC-3, CSH-11, SEC-8, CSH-18 |
| H8 | Overwriting a value never reclaims the old bytes, and nothing documents this. A frequently updated key fills a Buffer (and then triggers C1) or grows a context without bound. | CRT-1, API-13 |

### Medium (themes)

- **The build hides UB.** The C library is always built ReleaseFast, and the `build.zig` comment gives the wrong reason. There is a real off-by-one in the `kv_ofs[7]` prefetch index. Alignment checks after `__builtin_assume_aligned` are optimised out. C warnings are silently dropped. [BLD-1, CSH-6, MEM-8, CSH-12, CSH-16, SEC-13, PRF-10, PRF-11]
- **Tests:**
  - 17 of 21 mutants survive.
  - There are no allocation-failure tests or model-based property tests.
  - Managed/External are 80% untested.
  - With `json=false`, about 20 tests return early and count as passed.
  - The tests fail on 32-bit.
  - The upstream C tests never run.

  [TST-3..13, ALC-9, CSH-23]
- **CI and portability:**
  - The cross-compile job never compiles the Zig wrapper.
  - There are no 32-bit, musl, sanitizer, valgrind or consumer-package jobs.
  - The examples and bench do not build on Zig 0.16.0.
  - Big-endian and Windows rejections are noisy or wrongly justified.

  [BLD-3..7, OPS-1..3, OPS-9]
- **Allocator contracts:**
  - The JSON paths use libc malloc despite the "all memory through the allocator" claim.
  - There is no growth cap, so untrusted JSON can force multi-GiB allocations.
  - Growth over-allocates and decode re-parses the whole JSON on each growth step.
  - Copying a context by value means double free.
  - Nothing checks that ExternalContext gets the same allocator each call.

  [ALC-4..14, PRF-4/5/9, MEM-12/13/17, TST-7]
- **API shape:**
  - About 700 lines of alias lists and hand-written forwarders, which have already drifted.
  - The four document types differ in method names, lifecycle and error behaviour.
  - The iterator yields only an offset.
  - There is no `std.Io.Writer` JSON output and no array overwrite by index.
  - A 255-byte key limit makes some JSON-decoded documents unreadable.

  [API-8..14, ALC-8, ALC-7, MEM-11]
- **Performance:**
  - Hot key paths are 30–55% slower than raw lite3 because of the shim hop and `toKeyZ`.
  - lite3's comptime-hashed key feature is unreachable.
  - LTO is hard-disabled, although it works.

  [PRF-1..3]
- **Interop:**
  - The static library exports all yyjson and base64 symbols, so a consumer that also links yyjson gets clashes.
  - "JSON round-trip" loses data (bytes come back as a string, u64 becomes f64).
  - `jsonDecode` throws away yyjson's error position.
  - There is no wire-format contract.

  [CRT-2/3/5/7]
- **Docs and operations:**
  - The README dependency section is wrong.
  - The README contains a non-existent `Buffer.Iterator`.
  - There is no SECURITY.md, CHANGELOG or third-party notices.
  - `FIX_PLAN.md` is stale.
  - Workflows lack `permissions`, `concurrency` and SHA pins.
  - `just act-local` runs nothing.

  [OPS-4..15, API-18/19, BLD-8..13]

## 5. Plan

The maintainer's decisions (§7) shape the plan:

- **No users yet.** The plan does not fix the four current document types and then replace them. It fixes the C layer once, builds the new design directly on top of it, and ships a single `v0.1.0` release with no deprecation shims.
- **Zig 0.17.0, installed with mise.** This was originally "track master"; the project now pins 0.17.0 because it was released. `std.Io`-era APIs are the baseline.
- **Untrusted buffers are supported.** Validation is the default path, not an opt-in.

The guiding rule is red→green: each fix lands together with the failing test that proves the bug. The review already wrote those tests for every critical and high item; they are in [`REVIEW_REPRO_TESTS.md`](REVIEW_REPRO_TESTS.md). Tests written against the old types get ported to the new API in Phase 3. Their scenarios (growth across node splits, self-aliasing values, a failed decode, iteration after a mutation) carry over unchanged.

### Phase 0 — Toolchain on Zig 0.17.0 · ✅ done (2026-10-03)

Zig 0.17.0 was released after the decision to track master, so the project pins that release instead. It gets master's `std.Io` APIs without master's churn.

- `.mise.toml` pins `zig = "0.17.0"`, and `build.zig.zon` has `minimum_zig_version = "0.17.0"`. CI installs Zig through mise, so it follows automatically.
- `@cImport` was removed in 0.17. The shim header is now translated by `b.addTranslateC` in `build.zig` and imported as the private module `lite3_c`. This also removes the redundant per-module include and link calls (BLD-9).
- The examples and bench use the `main(init: std.process.Init)` entry point and `std.Io.File`. The bench uses `std.Io.Timestamp` in place of the removed `std.time.Timer`.
- The tests use a comptime `repeat` helper in place of the removed `**` operator.
- `zig fmt` migrated `@enumFromInt`/`@intFromEnum` to `@fromBackingInt`/`@backingInt`.
- Verified: 117/117 tests pass in Debug, ReleaseSafe and ReleaseFast with JSON on and off. The examples run. The bench runs. Cross-compiling to aarch64/x86_64 Linux and macOS works. `zig fmt --check` is clean.
- Optional follow-up: a non-blocking nightly job against Zig master, as an early warning for 0.18.

### Phase 1 — C layer: re-vendor, patches, safety net · ✅ done (2026-10-03)

All of this is independent of the Zig API, so it lands first.

**Status.** Implemented as planned, with these specifics and deviations:

- **Vendoring:** re-vendored at `48ab0e9` with 8 patches in `vendor/patches/`. The vendored tree keeps upstream's CRLF line endings; `.gitattributes` marks `vendor/**` as binary-safe.
- **Prefetching:** stays enabled in sanitized builds. Patch 0006 fixes the out-of-bounds index, and the suite is clean under UBSan with prefetching on; without the patch, UBSan traps at `lite3.c:487`.
- **Sanitizer mismatch:** a sanitized C library inside a ReleaseFast/ReleaseSmall program uses trap-mode UBSan, because those programs have no UBSan runtime.
- **Benchmarks:** the bench builds its own ReleaseFast library.
- **Out-of-range array index:** reports `InvalidArgument`, matching upstream's `EINVAL` and the typed getters. A dedicated error is part of Phase 2.4.
- **JSON syntax errors:** still map to `InvalidArgument`. The new `jsonDecodeDiagnostics` variants carry the yyjson position and message.
- **Not unit-tested:** patch 0005's OOM path and patch 0007's limit, which would need fault injection or a value over 512 MiB.
- **Verified:**
  - 137 tests pass in Debug, ReleaseSafe and ReleaseFast, with JSON on and off, and with LTO.
  - The 19 upstream C programs pass.
  - Valgrind reports zero errors.
  - Each regression test fails, or traps, when its patch is removed.

1. **Re-vendor upstream `48ab0e9`.**
   - Put local changes in `vendor/patches/*.patch`: the prefetch guard, plus the fixes below.
   - Record provenance in `vendor/lite3/UPSTREAM` (URL, SHA, date, yyjson version).
   - Replace the `update-vendor` placeholder with a script.
   - Trim `img/`, `examples/` and `Makefile` from the vendored tree.
   - Keep `tests/` for step 6.

   [H1]
2. **Local C patches**, each with a test and an upstream report (§6):
   - Iterator key length: `(tag >> KEY_SIZE_SHIFT) - 1`, plus a NUL check. [C2]
   - Reject a stored string size of 0. [C3]
   - `json_enc`: use `yyjson_mut_strn` with the decoded length. [SEC-3]
   - `json_dec`: reject NUL in keys, and reject a scalar root. [SEC-8, SEC-11]
   - Malloc before free in `lite3_ctx_import_from_buf`. This only matters if any `ctx_api` is kept; see Phase 3.1. [H4]
   - Clamp the `kv_ofs[7]` prefetch index. [PRF-11]
   - Guard the nibble_base64 `int` overflow. [CSH-10]
   - Send error messages to stderr, not stdout. [CSH-20]
3. **Shim rework.**
   - Each shim function returns a stable `LITE3ZIG_E_*` status code, translated from `errno` inside C right after the call. Zig never reads `errno`.
   - Initialise the iterator's `lite3_str`.
   - `getType`/`exists` propagate real errors.
   - JSON functions pass yyjson error codes and positions through, calling `yyjson_read_opts` and then `_lite3_json_dec_doc`.

   [H2, H6, API-7, CRT-5]
4. **Symbol hygiene.** Use a unity C translation unit with `#define yyjson_api static`, so only `shim_*` and `lite3_*` are exported. [CRT-3]
5. **Build modes.**
   - `-Dc-optimize` defaults to the user's `optimize`, with prefetching disabled outside ReleaseFast, so Debug runs under UBSan.
   - Add a `-Werror` lint step for the project's own C.
   - Make LTO opt-in (`-Dlto` sets `want_lto`).
   - Make big-endian rejection a single clear `@compileError`.

   [BLD-1, CSH-6, CSH-16, PRF-3, BLD-6]
6. **`zig build test-upstream`** compiles and runs `vendor/lite3/tests/*.c` normally and under UBSan. [TST-9]

Exit criteria: the C-level reproduction tests (iterator key, size-0 string, unterminated key, NUL key in JSON, misaligned overwrite, `{"":null}`) pass under UBSan and valgrind.

### Phase 2 — Untrusted-input core · ✅ done (2026-10-03)

**Status.** Implemented against the current types; the Phase 3 names (`View`, `Document`) don't exist yet. Specifics and deviations:

- **Two validation levels.**
  - `lite3.validate(bytes)` is allocation-free and uses about 6 KiB of stack. It guarantees in-bounds, bounded work and consistent reads and writes.
  - `lite3.validateStrict(gpa, bytes)` additionally proves no byte is used twice, so the document stays valid under writes.
  - Why two: the planned visited bitset needs memory, and the allocation-free byte budget cannot see sharing that fits inside dead space. A fuzzer-found case showed such a document can turn `CorruptData` after a legitimate write, though it stays memory-safe.
- **What `validate` checks** goes beyond the original list:
  - Each key's stored hash must be where lite3's probing finds it: every earlier probe slot must hold a different key. This also rules out duplicate keys.
  - Leaves must have all eight child slots zero. A stray child pointer would become live after an insert.
  - Nesting is capped at `max_nesting_depth` = 64.
- **Constructors** (`Buffer.fromSerialized`, `initFromBuf`, `importFromBuf` on all four types) validate first and leave the document untouched on rejection. `*Unchecked` variants skip validation.
- **Always-on checks:**
  - container `Offset` alignment and range → `InvalidArgument`
  - returned slices must lie inside the document → `CorruptData`
  - iteration is capped at the element count → `CorruptData`
- **Limits:**
  - `initWithOptions(.{ .initial_capacity, .max_capacity })` on Managed/External.
  - Patch 0009 makes probe exhaustion `ENOSPC` on insert, surfaced as the new `error.KeyCollision`, and `ENOENT` on lookup.
  - `lite3.max_key_len` is public.
- **Fuzzing:**
  - Four `std.testing.fuzz` targets (`src/fuzz_tests.zig`) plus a deterministic 3,000-iteration mutation sweep that runs on every `zig build test`.
  - Coverage instrumentation needs the LLVM backend, so fuzzing runs in ReleaseSafe.
  - CI fuzzes each target for 200K iterations on every push and 20M nightly.
  - `-Dtest-filter` was added to select targets.
- **Bug found by fuzzing:** `lite3_set_obj`/`set_arr` and their ctx variants are macros with an early `return`, which bypassed the Phase 1 status translation, so validation failures surfaced as `NotFound`. Fixed with helper functions and a regression test.
- **Threat model:** `SECURITY.md`.
- **Fuzz results (2026-10-03).** Each target ran 20M iterations in ReleaseSafe, with the C library under UBSan, and none failed:

  | Target | Unique paths | Coverage points |
  |---|---|---|
  | Mutated documents | 734 | 709 |
  | Arbitrary bytes | 401 | 56 |
  | JSON | 64 | 466 |
  | Write sequences | 201 | 559 |

  - That took about 15 minutes per target, short of the planned hour. The nightly CI job (20M per target) carries the long runs from here.
  - Coverage feedback sees only Zig code, because the C library is not instrumented. The JSON and raw-byte searches are therefore close to random over yyjson and lite3's C paths.
  - Valgrind is clean (0 errors) over the suite, seed corpora and mutation sweep, with JSON on and off.
  - 160 tests pass in every optimize mode × JSON setting, the upstream C tests pass, and LTO, lint and the cross `check` build are green.

Untrusted buffers are a supported use case. The wrapper's contract becomes: **no API reachable from safe-looking code reads or writes outside the document, loops without bound, or crashes, whatever bytes it is given.**

1. **`validate(bytes) error{CorruptData}!void`** is written in Zig, so it can be fuzzed and has no recursion. It walks the whole document once with an explicit stack (tree height ≤ 9 per container, nesting ≤ 32) and keeps a visited bitset of `len/4` bits. It rejects:
   - shared or cyclic node or kv offsets
   - misaligned or out-of-range offsets
   - `key_count > 7` and unsorted hashes
   - a `size` field that doesn't match the walked count
   - key tags that don't decode, and keys with no NUL terminator
   - zero-size strings
   - unknown type tags and non-0/1 booleans

   [SEC-4, SEC-16, CSH-21]
2. **Constructors that take foreign bytes validate by default.** That covers `View.fromBytes`, `Buffer.fromBytes`, `Document.initFromBytes` and `importBytes`. A clearly named `fromBytesUnchecked` exists for data the program itself produced, with documentation stating it gives up the guarantee.
3. **Defence in depth that is always on:**
   - Every slice-returning read goes through `checkedSlice`: bounds plus NUL check, returning `CorruptData`. [C3]
   - Container `Offset` arguments are range- and alignment-checked. [CSH-12, CRT-8]
   - The iterator caps its yield count at the validated entry count.
4. **Resource limits.**
   - `max_capacity` on growable documents. [ALC-5]
   - A JSON input size and expansion cap. [ALC-5]
   - A distinct error for hash-probe exhaustion: an attacker can still block the insertion of colliding keys, and that limitation is documented. [SEC-12, CSH-17]
5. **Fuzzing.**
   - `std.testing.fuzz` targets for `validate` + read APIs over mutated documents, for JSON decode, and for random operation sequences.
   - A seed corpus is checked in.
   - A short `--fuzz` run goes in nightly CI. The deterministic PRNG model test (Phase 3.6) runs on every PR.

   [TST-4, CSH-23]
6. **`SECURITY.md`.** Write the threat model:
   - what is guaranteed for untrusted lite3 bytes and for untrusted JSON
   - known limitations: the hash collision limit, bytes that come back as strings after a JSON round-trip, and nesting depth 32
   - how to report a vulnerability

   [SEC-16]

Exit criteria:

- The SEC-2/3/4 reproduction tests pass.
- A one-hour local `--fuzz` run on each target finds nothing.
- Valgrind and UBSan are clean on the fuzz corpus.

### Phase 3 — New API (single release) · ✅ done (2026-10-03)

There are no users, so this replaces the four current types outright: no aliases, no deprecations.

**Status.** Implemented, with these specifics and deviations:

- **Reads are pure Zig.** `View` implements lookup (lite3's hash probing), iteration and JSON encoding directly on the format, bounds-checking every access, so reads make no C calls. They are faster than lite3's own C getters. The C shim shrank to two insert functions plus JSON decoding.
- **`View` takes `[]const u8`**, not `[]align(4) const u8`: reads don't need alignment, so received bytes can be viewed in place. Writable documents (`Buffer`, `Document`) are 4-aligned.
- **Lifetimes.** One mutation epoch per document; `View`s and iterators return `error.StaleView` (the plan's `StaleIterator`) after any write, including growth. **By-value copies of a `Document` are not detected**: a self-pointer check would forbid returning a `Document` from `init`. The README and SECURITY.md document this; `clone` is the supported copy.
- **Keys.** `lite3.key("k")` hashes at compile time; `Key.init` hashes once at run time. Any key length lite3 supports can be read. A `Buffer` copies keys without a NUL terminator into a 1 KiB stack buffer (`max_stack_key_len`); longer ones must be `[:0]const u8`. `Document` copies them to the heap.
- **Aliasing.** Values and keys that lie in the document are copied aside before a write (for a `Buffer`, values up to `alias_scratch_len` = 4 KiB, else `error.ValueAliasesDocument`). The copy is out of line, so the common write path stays small.
- **Growth.** `Document` reserves an upper bound for one entry plus two split nodes before writing, and retries with more room if lite3 still runs out (cascading splits). A failed write leaves a valid document; a failed allocation leaves it unchanged (tested with `FailingAllocator`).
- **JSON.** Encoding is pure Zig and works with `-Djson=false`; floats always carry a `.` or exponent, bytes are base64. Decoding uses yyjson with the caller's allocator. A pre-pass rejects nesting deeper than 32, NUL in keys and scalar roots, each with its own error. With `-Djson=false` the decoding functions are compile errors, not runtime errors.
- **`ctx_api.c`** is no longer compiled into the library; only the upstream test programs build it.
- **Upstream bug found:** node splits left alignment padding uninitialised, which leaked caller memory into documents. Fixed in patch 0010, with a test that builds documents in memory pre-filled with 0x00 and with 0xff and requires identical bytes.
- **Tests:** 67 tests:
  - API tests, generic over all three document types.
  - Ported regression tests.
  - Validation tests.
  - A model-based property test (seed printed on failure).
  - `checkAllAllocationFailures` for Document operations and JSON decoding.
  - A golden fixture (`src/testdata/sample.lite3`, regenerate with `LITE3_UPDATE_GOLDEN=1`).
  - Four fuzz targets.
- **Mutation testing:** `scripts/mutate.py` (`just mutate`) applies 47 hand-written mutants across the Zig reader, writer, validator, shim and JSON precheck. It kills 44 (94%); the 3 survivors are equivalent mutants and are listed in the script. Mutation testing also drove the tests for control-character escapes, the encoder and decoder nesting limits, partly overlapping values, keys inside the document, stale views after `reserve`/`compact`, and four validator checks.
- **Performance:** the target was benchmark overhead ≤ 15% against raw lite3. Measured with callgrind, since wall-clock time on the shared machine varied by up to 60% between runs:
  - Writes run about 17% more instructions than the equivalent lite3 C macros (`set`: 429 vs 366 per op; append: +9%). The extra goes on the container-type check, the stale-view epoch, and the shim call.
  - Reads and iteration are faster than C.
  - The write overhead is above the 15% target. Closing it would mean dropping checks, so it is documented instead.
- **Verified:**
  - 67/67 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall (JSON-only tests skip with `-Djson=false`).
  - The upstream C tests pass.
  - Valgrind is clean.
  - 20M coverage-guided fuzz runs (5M per target, ReleaseSafe) found nothing after the write-sequence target was taught that `InvalidOffset` is the correct error for an Offset whose container was overwritten.

1. **Types:**
   - **`View`:** read-only, over `[]align(4) const u8`. It implements every read, iteration, JSON output and `format()` once.
   - **`Buffer`:** fixed capacity, caller-owned memory.
   - **`Document`:** unmanaged and growable. `gpa` is passed per call, on the `ArrayList` model. In safe builds it checks that the allocator matches. [MEM-17]
   - **`ManagedDocument`:** a thin wrapper that stores `gpa`.
   - **No C-heap `Context`:** it is dropped. `Document` covers its use cases with an explicit allocator, and dropping it removes `ctx_api.c` along with H4's upstream path.

   This removes about 700 lines of forwarders and the drift that comes with them. [API-9/10, ALC-7/8]
2. **Mutation semantics are designed in rather than patched:**
   - No `restoreLen`: lite3 owns `len`, and a failed write may leave grown but valid split nodes. [C1]
   - Values that alias the document are copied aside before any write or growth. [C4]
   - Growth pre-reserves from the known value size. [PRF-5]
   - Growth retries are correct across node splits. [C1]
   - `decodeJson` decodes into a fresh allocation and swaps it in on success, giving the strong guarantee. [H5]
   - `importBytes` validates, then copies with overlap handling. [TST-7]
   - `compact()` and `clone()` rebuild the document to reclaim space left by overwrites. [H8]
3. **Lifetimes:**
   - Iterators hold a pointer to their document and check a mutation epoch, returning `error.StaleIterator`.
   - Every borrowing method documents "valid until the next mutating call".
   - `StaleReference` is removed.
   - By-value copies of documents are caught in safe builds by a self-pointer check, or the type is made non-copyable through a pinned-handle pattern.

   [H3, MEM-12]
4. **Errors:**
   - Per-operation error sets: `ReadError`, `WriteError`, `DecodeError`, `EncodeError`.
   - `CorruptData` is distinct from `NotFound`, and there is a `TypeMismatch` error.
   - No catch-all `InvalidArgument`.

   [H6, API-2]
5. **Ergonomics and performance:**
   - Typed `ObjectIterator` yields `{ key, value }`; `ArrayIterator` yields `{ index, value }`. [API-11]
   - `arrSet(index, value)` and `rootType()`. [API-13]
   - Generic `set(at, key, value: anytype)` / `get(T, at, key)`, plus optional comptime struct (de)serialization. [API-14]
   - Comptime keys: `lite3.key("name")` precomputes the hash, and a shim entry point accepts key data, so the hot path skips `toKeyZ`. The 255-byte key limit goes. [PRF-1/2, API-8]
   - A pure-Zig `writeJson(*std.Io.Writer)` and `jsonAlloc(gpa)` that work with `json=false`. Decoding goes through a `yyjson_alc` bridge to the Zig allocator. [API-12, ALC-4]
6. **Tests for the new API:**
   - Port every reproduction test.
   - Backend-generic tests over `Buffer`, `Document` and `ManagedDocument`.
   - A deterministic model-based property test that prints its seed.
   - `checkAllAllocationFailures` on every growable operation.
   - Golden-byte fixtures that lock the wire format.
   - Exact-value assertions, including f64 compared bit for bit.

   [TST-3..13, CRT-7]

   Re-run the mutation test and aim for at least 90% of mutants killed.

Exit criteria:

- All reproduction tests ported and green.
- Mutation kill rate ≥ 90%.
- `checkAllAllocationFailures` is clean.
- Benchmark overhead against raw lite3 is ≤ 15% on comptime-key paths.

### Phase 4 — CI, packaging, docs, release · ✅ done except the tag (2026-10-03)

**Status.** CI is green on PR #1. Specifics and deviations:

- **Found while preparing CI:**
  - The library did not compile for 32-bit targets: `validateStrict`'s bitmap loop ranged over `u64`. The bench had the same problem.
  - The examples did not build for wasm32-wasi because `smp_allocator` needs threads. They now use `std.process.Init.gpa`.
- **CI:**
  - Actions are pinned to the latest release of the major version already in use. Dependabot proposes major upgrades.
  - Windows is not in the matrix: the library deliberately rejects it at compile time.
  - The Zig master canary runs nightly and on manual dispatch, never on PRs.
- **Snippets:** the README quick start is a complete program that `zig build run-examples` extracts and runs. The other README snippets are fragments: the dependency snippet is covered by `scripts/consumer-test.sh`, and the API tables are not code.
- **Upstream reports** are drafted in `docs/upstream-issues.md`, not filed: filing needs the maintainer's own account.
- **Left for the maintainer:**
  - merging PR #1
  - tagging `v0.1.0` on `main`
  - deciding whether to remove the README's "vibe-coded" warning


1. **CI matrix:** every job installs the pinned Zig (0.17.0) through mise.
   - Linux and macOS × Debug, ReleaseSafe and ReleaseFast × json on/off.
   - Native `x86-linux-musl` and `x86_64-linux-musl` test runs, after fixing the test that assumes a 64-bit `usize`. [BLD-4, TST-10]
   - A sanitized-C Debug job.
   - A valgrind job (`-Dcpu=x86_64_v3`).
   - A cross `check` job for arm, aarch64, riscv64, aarch64-macos and wasm32-wasi.
   - A consumer-package job (`git archive` → `zig fetch` → build with `.json = false`).
   - The nightly fuzz job from Phase 2, plus an optional non-blocking Zig master canary.

   [OPS-1..3, BLD-3]
2. **Workflow hygiene:**
   - Add `permissions: contents: read`, `concurrency` and `timeout-minutes`.
   - Pin actions by SHA and add Dependabot for actions.
   - Delete `ci-local.yml`.
   - Cache `~/.cache/zig`.
   - Make the fmt check cover the whole tree.
   - Add `fmt`, `docs`, `check` and `run-examples` build steps.

   [OPS-4/5/14, BLD-9/12]
3. **Docs:**
   - Rewrite the README for the new API.
   - Fix the dependency section (`zig fetch --save git+…#v0.1.0`, `b.dependency("lite3_zig", .{ .json = … })`).
   - Add a supported-platforms table, a JSON mapping table and the wire-format contract.
   - Compile-test every snippet in CI.
   - Add `SECURITY.md` (Phase 2), `CHANGELOG.md` and `CONTRIBUTING.md`.
   - Add third-party notices and LICENSE files to `.paths`.
   - Delete `FIX_PLAN.md`.
   - Examples assert their results.
   - Remove the "vibe-coded" warning once all of the above is green.

   [OPS-7..13, CRT-2/7, TST-14]
4. **Release:** tag `v0.1.0` and state that it was tested with Zig 0.17.0.

## 6. Upstream contributions

Ready-to-file drafts for all of these, plus the Phase 3 finding (patch 0010), are in [`upstream-issues.md`](upstream-issues.md), with a column to record the issue links.

These bugs are still present at upstream HEAD `48ab0e9`. Each one should be carried as a local patch and also filed upstream:

- the iterator key length bug (C2)
- the stored-size-0 string underflow (C3)
- `strlen` on keys in `json_enc` (SEC-3)
- free-before-malloc in `lite3_ctx_import_from_buf` (H4)
- the `kv_ofs[7]` prefetch index (PRF-11)
- NUL characters in JSON keys (SEC-8)
- the nibble_base64 `int` overflow for values of 1 GiB or more (CSH-10)
- `printf` to stdout under `LITE3_ERROR_MESSAGES` (CSH-20)
- the upper bound check in `_verify_key` (SEC-7, partially fixed upstream)
- the `lite3_get` macro precedence bug (CSH-13)

## 7. Decisions (resolved 2026-10-01)

1. **Zig version:** use **Zig 0.17.0**, installed with mise. The project tracked master until 0.17.0 was released. Phase 0 is done.
2. **Untrusted buffers:** **supported**. Validation is on by default, and Phase 2 covers it.
3. **Release strategy:** **one release** (`v0.1.0`) with the new design. There are no users yet, so there are no deprecation shims or staged releases.
4. **The C-heap `Context` type:** **dropped**. This follows from decision 3: `Document` covers its use cases with an explicit allocator. Revisit only if lite3 C-API interop (handing a `lite3_ctx*` to C code) becomes a requirement.

## 8. Findings register (deduplicated)

| Cluster | Severity | IDs |
|---|---|---|
| C1 restoreLen corruption | critical | MEM-1, CSH-2, ALC-1, TST-1 |
| C2 iterator key length | critical | CSH-1, MEM-2, API-1, SEC-1, TST-2 |
| C3 str size-0 underflow | critical | SEC-2, CSH-3 |
| C4 self-aliasing values | critical | MEM-4, CSH-5, TST-7, ALC-10, MEM-13 |
| H1 vendor drift / provenance / alignment | high | BLD-2, SEC-5, MEM-7, CSH-7, SEC-6, SEC-7, CSH-8, OPS-6, CRT-4, SEC-14, BLD-14 |
| H2 uninitialised iterator key | high | MEM-3, CSH-4, SEC-10, OPS-1 |
| H3 iterator/slice lifetime | high | MEM-5, API-5, MEM-6, SEC-9, SEC-18 |
| H4 importFromBuf OOM | high | ALC-3, CSH-9, MEM-10 |
| H5 jsonDecode atomicity | high | ALC-2, API-15, MEM-9, CSH-15, SEC-11, TST-6 |
| H6 error model | high | API-3, CSH-13, API-4, CSH-14, API-2, API-6, CSH-19, MEM-16, API-7 |
| H7 untrusted input | high | SEC-16, SEC-4, SEC-3, CSH-11, SEC-8, CSH-18, SEC-12, CSH-17, CSH-21, CSH-10 |
| H8 space reclamation | high | CRT-1, API-13 |
| Hidden UB in build | medium | BLD-1, CSH-6, MEM-8, CSH-12, CSH-16, SEC-13, PRF-10, PRF-11, CRT-8 |
| Test suite | medium | TST-3..15, ALC-9, CSH-23 |
| CI / portability | medium | BLD-3..7, OPS-1..3, OPS-9 |
| Allocator contracts | medium | ALC-4..17, PRF-4, PRF-5, PRF-9, MEM-12, MEM-14, MEM-17, PRF-12 |
| API shape | medium | API-8..14, API-16, API-17, ALC-7, ALC-8, MEM-11, MEM-15 |
| Performance | medium | PRF-1..3, PRF-6..8 |
| Interop | medium | CRT-2, CRT-3, CRT-5, CRT-6, CRT-7, CSH-22 |
| Docs / ops | low | OPS-4..15, API-18, API-19, BLD-8..13, CSH-20, SEC-15, SEC-17, MEM-18, ALC-15, ALC-16 |
