# lite3-zig — Production-Readiness Review & Plan

Review date: 2026-10-01 · Reviewed commit: `b7cb2b9` · Toolchain: Zig 0.15.2 (also probed 0.16.0)

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

The guiding rule is red→green: each fix lands together with the failing test that proves the bug. The review already wrote those tests for every critical and high item; they are in [`REVIEW_REPRO_TESTS.md`](REVIEW_REPRO_TESTS.md). Phases 1–3 are non-breaking and can ship as `0.1.x`. Phase 4 is the deliberate `0.2.0` API break.

### Phase 0 — Safety net (do first; makes everything else verifiable) · ~1–2 days

1. **`-Dc-optimize` option.** It defaults to the user's `optimize`. Define `LITE3_DISABLE_PREFETCHING` for Debug and ReleaseSafe, and keep ReleaseFast with prefetching as opt-in. Fix the `build.zig` comment. [BLD-1, CSH-6]
2. **Local vendor patch for the prefetch `kv_ofs[7]` index**, so a UBSan build runs clean. [PRF-11]
3. **`check` step:** compile tests, examples and bench without running them. Set `skip_foreign_checks` so `-Dtarget=` works as a compile check. [BLD-3, OPS-3]
4. **Backend-generic test harness:** `inline for` over Buffer (large), Context, Managed, External (through an adapter). [TST-5]
5. **Deterministic model-based property test** in the normal `test` step:
   - Apply random operations to each backend and to a `StringHashMap`/`ArrayList` model, then compare.
   - Seed it from `std.testing.random_seed` and print the seed on failure.
   - Read the iteration count from a build option.

   [TST-4]
6. **`checkAllAllocationFailures` tests** for Managed and External, plus `std.testing.allocator` leak checks everywhere. [TST-8, ALC-9]

Expected outcome: the new tests go red on C1–C4, H2 and H5. That is the point of this phase.

### Phase 1 — Correctness hotfixes (P0) · ~2–3 days

| Step | Change | Files | Closes |
|---|---|---|---|
| 1.1 | Delete `saveLen`/`restoreLen` and let lite3 own `len`; the upstream contract allows `len` to grow on `ENOBUFS`. Rewrite the test at `tests.zig:1377` to assert that committed keys stay readable. | `lite3.zig`, `tests.zig` | C1 |
| 1.2 | Fix the iterator key length. Add a local patch to `lite3.c:403` (`len = (tag >> KEY_SIZE_SHIFT) - 1`, plus a NUL check) and a defensive bounded `strnlen` in the shim. Report it upstream. Add byte-exact key tests (1-byte, 63- and 64-byte tag boundary, key at the end of the buffer). | `vendor/…/lite3.c`, `lite3_shim.c` | C2, SEC-3, CSH-11 |
| 1.3 | Initialise `lite3_str key = {0}` in the shim. Decide object versus array once, at `iterate()` time. | `lite3_shim.c` | H2 |
| 1.4 | Add a `checkedSlice` helper in SharedMethods. Every slice-returning getter and the iterator key go through it: bounds plus NUL check, returning `CorruptData`. Also patch lite3 locally to reject a stored string size of 0. | `lite3.zig`, vendor | C3 |
| 1.5 | Overlap detection in `setStr`/`setBytes`/`arrAppendStr`/`arrAppendBytes`: copy the value aside before any growth. Do it in the Managed/External forwarders, before `callWithGrowth`. Also handle `importFromBuf(self.data())` with a memmove or no-op. | `lite3.zig` | C4, TST-7, ALC-10 |
| 1.6 | `Context.importFromBuf`: create a new context from the buffer, then swap it in, so failure is OOM-safe. Add a malloc-before-free vendor patch and report it upstream. | `lite3.zig`/shim | H4 |
| 1.7 | `jsonDecode` strong guarantee. Managed/External decode into a fresh allocation and swap it in on success. Context decodes into a new ctx and swaps. Buffer documents that `mem` is clobbered on failure. A scalar root becomes an error. | `lite3.zig`, shim | H5 |
| 1.8 | **Re-vendor upstream `48ab0e9`**, applying the patches from 1.2, 1.4, 1.6 and Phase 0 step 2 plus the prefetch guard. Each patch lives under `vendor/patches/*.patch`. Record the source in `vendor/lite3/UPSTREAM` (URL, SHA, date, yyjson version). Replace the `update-vendor` placeholder with a script. Trim `img/`, `examples/` and `tests/` from the tree; they are about 1.2 MB, and `tests/` moves to a build step (Phase 3). | `vendor/`, `Justfile` | H1 |
| 1.9 | Wrapper-side checks on container `Offset` arguments: reject anything misaligned or `> maxInt(u32)` with `InvalidArgument`. Assert that the offsets `setObj`/`setArr` return are 4-aligned. | `lite3.zig` | CSH-12, CRT-8 |

Exit criteria:

- Every reproduction test from the review passes.
- The full suite passes with `-Dc-optimize=Debug` (UBSan) and under valgrind.
- Mutation re-run: 18 or more of the 21 mutants are killed.

### Phase 2 — Error model & safety contract (non-breaking where possible) · ~3–4 days

1. **Shim returns stable status codes.** The shim translates `errno` inside C, right after each call, into a small `LITE3ZIG_E_*` enum. Zig then does a pure integer switch: no thread-local errno, and the same behaviour on every target. This unblocks Windows. [API-7, CSH-19, MEM-16, BLD-7]
2. **Getters propagate errors.** `getType`, `arrGetType` and `exists` return errors; only a truly absent key gives `NotFound`/`false`. `EFAULT` on read paths becomes `CorruptData`. JSON-encode failures get specific errors (`NoSpaceLeft`, `NonFiniteNumber`, `InvalidUtf8`). Note the behaviour change in the CHANGELOG. [H6]
3. **Iterator safety.** The iterator re-reads its owner's buffer on each `next()` and checks a wrapper-side mutation epoch, returning `error.StaleIterator`. Either make `StaleReference` real or deprecate it. Add a lifetime doc comment ("valid until the next mutating call") to every borrowing method. [H3]
4. **Untrusted input:**
   - `pub fn validate()` walks the document once with an explicit stack and a visited bitset. It rejects shared or cyclic offsets, misalignment, `key_count > 7`, a size-field mismatch, unterminated keys and zero-size strings.
   - Add `fromSerializedValidated` (or an options flag).
   - The JSON decode path rejects NUL in keys; this is a vendor patch.
   - Write a SECURITY.md threat model.

   [H7, SEC-12, CSH-17]
5. **Keys.** Raise or remove the 255-byte key limit: keep a stack fast path and fall back to `std.heap.c_allocator`. Add a zero-copy `[:0]const u8` key path and expose `max_key_len`. [API-8, MEM-11]
6. **Growth policy:**
   - Add `max_capacity` through `initWithOptions`.
   - Pre-reserve from the known value size.
   - `jsonDecode` pre-sizes from `json.len` and retries with free+alloc rather than realloc.
   - Add `reserve()`, `shrinkToFit()` and `capacity()` on all types.

   [ALC-5, PRF-4/5/9, ALC-12..14]
7. **Space reclamation.** Add `compact()`/`clone()` by re-emitting the document through the fixed iterator, and document the append-only overwrite cost. [H8]
8. **JSON:**
   - `jsonEncodeBuf` returns `NoSpaceLeft` and runs `ensureUsable`.
   - Add a `jsonDecode` diagnostic with byte position by calling `yyjson_read_opts` from the shim and then `_lite3_json_dec_doc`.
   - Write a JSON mapping table to the README: bytes become base64 one-way, u64 above `maxInt(i64)` becomes f64, NaN/Inf are rejected, nesting depth is limited to 32.

   [CSH-14, CRT-2, CRT-5, PRF-8]

### Phase 3 — Build, CI, portability, packaging · ~2 days (can run in parallel with Phase 2)

1. **CI matrix:**
   - Linux and macOS × Debug, ReleaseSafe and ReleaseFast × json on/off (existing).
   - `x86-linux-musl` and `x86_64-linux-musl` test runs (native).
   - A sanitized-C Debug job.
   - A valgrind job (`-Dcpu=x86_64_v3`).
   - A cross `check` job for arm, aarch64, riscv64, aarch64-macos and wasm32-wasi.
   - A consumer-package job (`git archive` → `zig fetch` → build with `.json = false`).
   - A non-blocking Zig 0.16 canary.

   [OPS-1..3, BLD-3/4]
2. **Fix the 32-bit test** (it assumes a 64-bit `usize`). Pre-validate `initWithSize > maxInt(u32)` in Zig. [BLD-4, TST-10]
3. **`zig build test-upstream`** compiles and runs `vendor/lite3/tests/*.c` with the same flags and macros, including a UBSan variant. [TST-9]
4. **Make LTO opt-in.** `-Dlto` sets `want_lto` and forces LLVM in Debug; document the consumer requirement. Flip the CI assertion so LTO must pass. [PRF-3, BLD-8]
5. **Symbol hygiene.** Use a unity C translation unit with `#define yyjson_api static`, so that only `shim_*` and `lite3_*` are exported. [CRT-3]
6. **Build cleanup:**
   - Surface C warnings with a `-Werror` lint step for the project's own C.
   - Drop redundant include and link calls.
   - Add `fmt`, `docs` and `run-examples` steps.
   - Make big-endian rejection a single clear `@compileError`.

   [CSH-16, BLD-6/9/10/12]
7. **Workflow hygiene:**
   - Add `permissions: contents: read`, `concurrency` and `timeout-minutes`.
   - Pin actions by SHA and add Dependabot for actions.
   - Delete `ci-local.yml`, or fix `just act-local` with `-e workflow_dispatch`.
   - Cache `~/.cache/zig`.
   - Make the fmt check cover the whole tree.

   [OPS-4/5/14]

### Phase 4 — API redesign → `0.2.0` (breaking; after Phases 1–2) · ~1–2 weeks

1. **One generic implementation.**
   - `View` (read-only, over `[]align(4) const u8`) implements every read, iteration, JSON output and `format()` once.
   - `Buffer` is fixed-capacity.
   - `Document` is an unmanaged growable type taking `gpa`, with `ManagedDocument` as a thin wrapper, following the `ArrayList` pattern.
   - Either deprecate the C-heap `Context` or keep it as an alias.

   This removes about 700 lines of forwarders and makes drift impossible by construction. [API-9/10, ALC-8, ALC-7]
2. **Typed iteration.** `ObjectIterator` yields `{ key, value: Value }` and `ArrayIterator` yields `{ index, value }`. Add `arrGetValue` and `arrSet(index, value)`. [API-11, API-13]
3. **Per-operation error sets** (`ReadError`, `WriteError`, `JsonDecodeError`), keeping an `Error` superset for one release. [API-2]
4. **Comptime keys.** `lite3.key("name")` precomputes the DJB2 hash and size, and the keyed methods accept `anytype`. Add a test that the comptime hash matches `lite3_get_key_data` at lengths 0, 1, 63, 64 and 255. Add a middle-step shim entry point that takes the key data and skips `toKeyZ`. Target: close most of the 30–55% overhead. [PRF-1/2]
5. **Pure-Zig JSON writer** on `std.Io.Writer` (`writeJson`, `jsonAlloc`, `std.json` stringify interop). It works with `json=false` and its allocator is explicit. Bridge yyjson to a `yyjson_alc` that forwards to the Zig allocator for decoding. [API-12, ALC-4]
6. **Optional comptime struct (de)serialization:** `set(T)` and `get(T)`. [API-14]
7. **Idiomatic naming:** `Value` tags without trailing underscores, private invariant-bearing fields, and `//!` module docs. [API-16/17, MEM-15]

### Phase 5 — Docs & release · ~1 day (ongoing)

- **README:**
  - Fix the dependency section: `zig fetch --save git+…#v0.1.1`, `b.dependency("lite3_zig", .{ .json = … })`.
  - Remove `Buffer.Iterator`.
  - Add a supported-platforms table and a JSON mapping table.
  - State the wire-format contract and add golden-byte fixture tests.
  - Compile-test every README snippet in CI.

  [OPS-7/8/12, CRT-7, BLD-13]
- **Repository files:**
  - Add `SECURITY.md` (the threat model from Phase 2), `CHANGELOG.md` and `CONTRIBUTING.md`.
  - Add third-party notices for yyjson and nibble_base64, and add their LICENSE files to `.paths`.
  - Retire `FIX_PLAN.md`.

  [OPS-11/13, API-19]
- **Examples assert their results.** Add an allocator-context example and an iteration example. [OPS-10, TST-14]
- **Releases:** tag `v0.1.1` after Phase 1, `v0.1.2` after Phases 2–3, and `v0.2.0` after Phase 4. Write a semver policy for 0.x.

## 6. Upstream contributions

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

## 7. Decisions needed from the maintainer

1. **Zig version policy.** Option A: stay on 0.15.2 and run a 0.16 canary. Option B: move to 0.16. Moving costs about 4 lines per example and about 12 in bench; the library itself needs no changes. Recommendation: A for `0.1.x`, B for `0.2.0`.
2. **Untrusted buffers.** Option A: support them, via `validate()` plus the hardening in Phase 2.4. Option B: document them as "trusted input only". Recommendation: A, because lite3 is a wire format.
3. **The C-heap `Context` type.** Keep it, or deprecate it in favour of `Document(gpa)`. Recommendation: deprecate it in 0.2.0.
4. **Breaking-change appetite.** Should Phase 4 ship as one `0.2.0`, or be staged behind deprecations?

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
