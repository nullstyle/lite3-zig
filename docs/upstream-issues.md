# Upstream lite3 issues

Bugs found in [fastserial/lite3](https://github.com/fastserial/lite3) at commit
`48ab0e9` while building lite3-zig. Each is carried here as a patch in
`vendor/patches/`. The drafts below are ready to file upstream; the patch file
can be attached or turned into a pull request. Mark each one with its issue
link once filed.

| # | Title | Severity | Patch | Filed |
|---|---|---|---|---|
| 1 | Iterator reports key length ~4x too long | memory safety (over-read) | 0002 | — |
| 2 | String with stored size 0 is read as a 4 GiB slice | memory safety (over-read) | 0003 | — |
| 3 | Non-0/1 bool byte is undefined behaviour | UB | 0003 | — |
| 4 | Unterminated keys are accepted; JSON encoder uses `strlen` on them | memory safety (over-read) | 0002 | — |
| 5 | JSON keys containing `\u0000` are truncated and can overwrite other keys | correctness | 0004 | — |
| 6 | Scalar JSON root returns success with an uninitialised buffer | correctness | 0004 | — |
| 7 | `lite3_ctx_import_from_buf` frees before allocating (use-after-free / double free on OOM) | memory safety | 0005 | — |
| 8 | Iterator prefetch reads `kv_ofs[7]` (out of bounds) | UB | 0006 | — |
| 9 | base64 length overflows `int` for values ≥ 512 MiB (heap overflow) | memory safety | 0007 | — |
| 10 | `LITE3_ERROR_MESSAGES` prints to stdout; `%lu` for `size_t` | robustness | 0008 | — |
| 11 | Hash-probe exhaustion is reported as `EINVAL` | API | 0009 | — |
| 12 | Split-node alignment padding is not zeroed (memory leaks into documents) | information leak | 0010 | — |
| 13 | Prefetching cannot be disabled on targets where it faults | portability | 0001 | — |

---

## 1. `lite3_iter_next()` reports key length ~4x too long

`lite3_iter_next()` copies the raw key tag into `out_key->len` and subtracts 1,
but never shifts out the 2 tag-size bits. Every key is reported roughly 4x its
real length, so callers that use `len` read past the key, and for the last
entry in a buffer, past the end of the buffer.

**Reproduce:** insert key `"x"`, iterate, and compare `out_key.len` to 1.

**Fix:** report `(tag >> LITE3_KEY_TAG_KEY_SIZE_SHIFT) - 1` (patch 0002).

## 2. String with stored size 0 becomes a 4 GiB slice

String values store their size including the NUL terminator, and every reader
subtracts 1. A corrupted or hostile size of 0 wraps to `0xFFFFFFFF`, so a
1-byte corruption turns into a 4 GiB read. `_verify_val()` does not reject it.

**Fix:** require size ≥ 1 and a NUL at the end (patch 0003, `EBADMSG`).

## 3. Bool values other than 0/1

Bools are loaded as C `_Bool`; any other byte value is undefined behaviour.
**Fix:** reject in `_verify_val()` (patch 0003).

## 4. Unterminated keys

`_verify_key()` accepts key entries with stored size 0 or without a trailing
NUL, and the JSON encoder passes keys to yyjson with `strlen`, which reads past
the entry. **Fix:** reject both in `_verify_key()`; use `yyjson_mut_strn()`
with the decoded length (patch 0002).

## 5. JSON keys containing `\u0000`

`{"a\u0000b":1,"a":2}` decodes to `{"a":2}`: the key is passed to the setters
as a C string, truncated to `"a"`, and overwrites another key.
**Fix:** reject such keys with `EINVAL` (patch 0004).

## 6. Scalar JSON root

Decoding `42` sets `errno = EINVAL` but returns 0, because `ret` is never
assigned on that path; callers see success with an uninitialised buffer.
**Fix:** return -1 (patch 0004).

## 7. `lite3_ctx_import_from_buf()` frees before allocating

The old buffer is freed before `malloc()`. On allocation failure the context
keeps a dangling pointer: later reads use freed memory and
`lite3_ctx_destroy()` frees it twice. Importing a slice of the context's own
buffer also reads freed memory when it has to grow, and uses an overlapping
`memcpy()` when it does not.
**Fix:** allocate and copy first, free on success, `memmove()` in place, set
`errno = ENOMEM` (patch 0005).

## 8. Prefetch index reaches `kv_ofs[7]`

`kv_ofs[]` has 7 elements, but the iterator's prefetch hints mask the index
with `LITE3_NODE_KEY_COUNT_MASK` (7), allowing index 7. UBSan reports it.
**Fix:** reduce modulo `LITE3_NODE_KEY_COUNT_MAX` (patch 0006).

## 9. base64 `int` overflow

`nibble_base64()` takes an `int` length and computes `4 * (len + pad)` in
`int`, which overflows for bytes values above ~512 MiB and under-allocates the
output buffer (heap overflow). Library code also calls `puts()`.
**Fix:** reject such values with `EMSGSIZE`; set `errno = ENOMEM` on
allocation failure; remove `puts()` (patch 0007).

## 10. Error messages on stdout

With `LITE3_ERROR_MESSAGES` the library prints diagnostics to stdout, which
corrupts programs that use stdout for data; a `size_t` is printed with `%lu`
(wrong on 32-bit and LLP64). **Fix:** stderr and `%zu` (patch 0008).

## 11. Hash-probe exhaustion is `EINVAL`

When all `LITE3_HASH_PROBE_MAX` slots for a key hold other keys, lookups and
inserts return `EINVAL`, indistinguishable from bad arguments. Because DJB2 is
unseeded, an attacker can cause this on purpose.
**Fix:** lookups return `ENOENT`, inserts `ENOSPC` (patch 0009). A seeded hash
would be the real fix, but changes the format.

## 12. Split-node alignment padding not zeroed

With `LITE3_ZERO_MEM_EXTRA` (on by default, documented as keeping
uninitialised memory out of messages) entry padding is zeroed, but the up to 3
bytes skipped to align a new node during a split are not. Documents built in
uninitialised memory carry stale bytes from it.

**Reproduce:** build the same document in memory filled with 0x00 and in memory
filled with 0xFF; the outputs differ.

**Fix:** zero the padding (patch 0010).

## 13. Prefetching cannot be disabled

Prefetch hints may fault on some non-x86 targets, and there is no switch to
turn them off without editing the header.
**Fix:** `LITE3_DISABLE_PREFETCHING` (patch 0001).
