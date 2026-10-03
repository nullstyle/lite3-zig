# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's
[security advisory form](https://github.com/nullstyle/lite3-zig/security/advisories/new)
rather than a public issue. Include a reproducer (a document or JSON input and
the calls that misbehave) if you can. Issues in the lite3 C library itself are
also welcome here; we carry fixes as patches in `vendor/patches/` and report
them upstream.

Only the latest release is supported.

## Threat model

lite3 documents are a wire format, so lite3-zig treats **serialized documents
and JSON text as potentially hostile input**. The guarantees below hold for
every supported target and optimize mode.

### Untrusted lite3 bytes

The constructors that take serialized bytes — `Buffer.fromSerialized`,
`Context.initFromBuf`/`importFromBuf`, `ManagedContext.initFromBuf`/
`importFromBuf`, `ExternalContext.initFromBuf`/`importFromBuf` — run
`lite3.validate` first and return `error.CorruptData` if it fails. A rejected
import leaves the existing document unchanged.

For a document that passed `validate`, **reading and writing it through the
public API**:

- never reads or writes outside the document's buffer,
- does work bounded by the document size (no cycles, no exponential
  revisiting of shared subtrees, iteration capped by element counts),
- sees every entry exactly as iteration lists it: each key can be found by
  lookup, element counts match, strings and keys are terminated.

`validate` allocates nothing and runs in linear time (each key stored at hash
probe attempt *k* costs *k* extra lookups, *k* < 128). It does **not** detect
structure sharing that fits inside a document's dead space (bytes left behind
by overwrites). Such a document is still safe in the sense above, but a later
write may make parts of it read as `error.CorruptData`. If you will *modify*
documents from untrusted sources, call `lite3.validateStrict(gpa, bytes)`,
which also proves no byte is used twice; a document that passes stays valid
under any sequence of writes. It needs `len / 8` bytes of scratch memory.

The `*Unchecked` constructors (`fromSerializedUnchecked`,
`initFromBufUnchecked`, `importFromBufUnchecked`) skip validation and are
**only for bytes your program produced itself**. They are not covered by the
guarantee above, although the wrapper still bounds-checks offsets, returned
slices and iteration counts, and the lite3 C library bounds-checks its own
reads.

### Untrusted JSON

JSON is parsed by the bundled yyjson (strict RFC 8259: UTF-8 validated, no
comments or trailing commas) and converted by lite3's decoder. Every document
the decoder produces passes `validate` (this is fuzzed). In addition:

- Nesting deeper than 32 levels is rejected (`error.InvalidArgument`), so
  decoding cannot exhaust the stack.
- Keys containing `\u0000` are rejected rather than silently truncated.
- A root that is not an object or array is rejected.
- Duplicate keys: the last one wins.
- Growth is bounded only by `max_capacity`. For untrusted input use
  `ManagedContext.initWithOptions` / `ExternalContext.initWithOptions` with a
  `max_capacity`; decoding past it fails with `error.NoBufferSpace`. (The
  C-heap `Context` has no such limit and grows to 4 GiB.)
- `jsonDecodeDiagnostics` reports the position of a syntax error.

### Known limitations

- **Hash flooding.** lite3 hashes keys with unseeded DJB2 and probes at most
  128 slots per key. An attacker who controls key names can create keys that
  collide, so that a later insert of a colliding key fails with
  `error.KeyCollision` (lookups of absent keys correctly return `NotFound`).
  Each colliding lookup costs up to 128 probes. A seeded hash would change the
  wire format and has to happen upstream.
- **Keys longer than `lite3.max_key_len` (255 bytes)** are valid in documents
  but can only be reached through iteration, not through the get/set methods.
- **JSON round-trips are lossy**: bytes values become base64 strings, integers
  above `maxInt(i64)` become floats, and NaN/±Inf cannot be encoded.
- **Borrowed data.** Slices returned by getters and iterators, and `Offset`
  values, point into the document and are invalidated by any write that
  grows or rearranges it. Using a stale slice is a use-after-free in your
  program, not something validation can prevent. The upcoming 0.1.0 API
  redesign addresses this.
- **Thread safety.** A document may be read from several threads at once;
  any write requires exclusive access.

## How this is tested

- Regression tests for every memory-safety bug found in review, each shown to
  fail without its fix (`src/regression_tests.zig`).
- `validate` tests including every single-byte corruption of a sample document
  (`src/validate_tests.zig`).
- Coverage-guided fuzz targets for mutated documents, arbitrary bytes, JSON
  decoding and random write sequences (`src/fuzz_tests.zig`); their seed
  corpus and a deterministic mutation sweep run in every `zig build test`.
  Run them with `zig build test --fuzz=1M -Doptimize=ReleaseSafe
  -Dtest-filter=fuzz:`.
- CI builds the C library under UBSan (Debug and ReleaseSafe), runs the suite
  under valgrind, and runs lite3's own C tests against the vendored sources.
