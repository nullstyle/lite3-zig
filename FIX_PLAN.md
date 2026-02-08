# Fix Plan for lite3-zig Quality Report

## Agent Assignment

Four parallel agents, each owning distinct files to avoid conflicts:

### Agent A — Zig Wrapper Fixes (`src/lite3.zig`)
1. **Fix `translateError` (Critical #1)**: Replace hardcoded errno integers with portable `std.posix.E` enum values. Map all 7 documented errno codes: `ENOENT`, `EINVAL`, `ENOBUFS`, `EIO`, `EFAULT`, `EBADMSG`, `EMSGSIZE` (plus `EOVERFLOW`).
2. **Fix `Context.jsonDecode` (Critical #2)**: Replace the broken implementation that calls `shim_lite3_json_dec` (Buffer-level) with a call to the new `shim_lite3_ctx_json_dec` (Context-level) shim that Agent B will create. The new shim calls `lite3_ctx_json_dec()` which properly updates `ctx->buflen`.
3. **Make `c` private**: Change `pub const c = @cImport(...)` to `const c = @cImport(...)`.
4. **Add `freeJson` helper**: Add a `pub fn freeJson(json: []const u8) void` free-standing function so callers don't need `std.c.free(@ptrCast(@constCast(...)))`.

### Agent B — C Shim Fixes (`src/lite3_shim.h`, `src/lite3_shim.c`)
1. **Add `shim_lite3_ctx_json_dec`**: New shim function wrapping `lite3_ctx_json_dec(ctx, json_str, json_len)` — this is what `Context.jsonDecode` needs.
2. **Fix `shim_lite3_count` const-correctness**: Change parameter from `unsigned char *buf` to `const unsigned char *buf`.
3. **Remove dead code**: Delete unused `lite3_str s; (void)s;` in `shim_lite3_get_bool`.

### Agent C — Test Improvements (`src/tests.zig`)
1. **Context error tests**: Key not found, type mismatch (mirrors Buffer error tests).
2. **Test untested methods**: `Context.bufPtr`, `Context.data`, `Context.jsonDecode` (after fix), `Context.arrGetStr`, `Context.arrGetBytes`.
3. **Edge case tests**: Unicode strings, empty string keys, empty containers, OOB array access error.
4. **Update JSON free calls**: Use new `lite3.freeJson()` helper in existing and new tests.

### Agent D — Project Infrastructure (new files + `README.md`)
1. **Add root LICENSE**: Copy MIT license from `vendor/lite3/LICENSE`, add wrapper copyright.
2. **Fix README.md**: Fix stale "Zig 0.14.0" reference → "Zig 0.15.2", add submodule clone instructions, update JSON free examples to use `freeJson`.
3. **Add GitHub Actions CI**: Create `.github/workflows/ci.yml` with `zig build test` on Ubuntu + macOS.

## Execution Order

All four agents run **in parallel** (they touch disjoint file sets). After all complete, run `zig build test` to verify everything compiles and passes.

## Not Addressed (Deferred to future work)

- Comptime mixin to reduce Buffer/Context duplication (high risk, large refactor)
- Accept `[]const u8` keys (API-breaking change)
- Make `Offset` a newtype (API-breaking change)
- Fuzz testing (requires `std.testing.fuzz` which may not be stable)
- Fix package distribution (requires removing git submodule — the `.paths` in `build.zig.zon` already lists the vendor directories, so this may already work if the files are committed directly)
