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

The functions that take serialized bytes — `View.fromBytes`,
`Buffer.fromBytes`, `Document.fromBytes`/`importBytes` and their
`ManagedDocument` equivalents — run `lite3.validate` first and return
`error.CorruptData` if it fails. A rejected import leaves the existing
document unchanged.

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

The `*Unchecked` variants skip validation and are **only for bytes your
program produced itself**. They are not covered by the guarantee above. Reads
still never leave the document's bytes (the Zig reader bounds-checks every
offset, slice and iteration count and returns `error.CorruptData`), but
writes to an unvalidated document go through lite3's C insertion code, which
trusts the structure it is given.

### Untrusted JSON

JSON is parsed by the bundled yyjson (strict RFC 8259: UTF-8 validated, no
comments or trailing commas) and converted by lite3's decoder. Every document
the decoder produces passes `validate` (this is fuzzed). In addition:

- Nesting deeper than 32 levels is rejected (`error.NestingTooDeep`), so
  decoding cannot exhaust the stack.
- Keys containing `\u0000` are rejected (`error.InvalidKey`) rather than
  silently truncated.
- A root that is not an object or array is rejected (`error.InvalidRoot`).
- Duplicate keys: the last one wins.
- The parse tree is allocated with your allocator, so its memory is yours to
  bound. The decoded document is bounded by the Buffer's size or by
  `fromJson(.., .{ .max_capacity = n })`; past it, decoding fails with
  `error.NoSpaceLeft`.
- `JsonDiagnostics` reports the position and reason of a syntax error.
- `Document.decodeJson` leaves the document unchanged if decoding fails.

### Known limitations

- **Hash flooding.** lite3 hashes keys with unseeded DJB2 and probes at most
  128 slots per key. An attacker who controls key names can create keys that
  collide, so that a later insert of a colliding key fails with
  `error.KeyCollision` (lookups of absent keys correctly return `NotFound`).
  Each colliding lookup costs up to 128 probes. A seeded hash would change the
  wire format and has to happen upstream.
- **Long keys.** Any key length lite3 supports can be read. A `Buffer`
  writes keys longer than `lite3.max_stack_key_len` (1023 bytes) only when
  they are NUL-terminated (`[:0]const u8` or `lite3.Key`) and not inside the
  document; otherwise it returns `error.KeyTooLong`. `Document` copies such
  keys to the heap.
- **JSON round-trips are lossy**: bytes values become base64 strings, integers
  above `maxInt(i64)` become floats, and NaN/±Inf cannot be encoded.
- **Borrowed data.** Slices returned by reads point into the document and
  are invalid after the next write to it. `View`s and iterators detect this
  (`error.StaleView`); a slice you kept does not, and using it is a
  use-after-free in your program. Copying a `Document` struct by value
  shares its memory between the copies and is not detected either; use
  `clone`.
- **Encoding unvalidated content.** `validate` checks structure, not
  content: a string may hold invalid UTF-8 and a float may be NaN. The JSON
  encoder reports these as `error.InvalidUtf8` / `error.NonFiniteNumber`.
- **Thread safety.** A document may be read from several threads at once;
  any write requires exclusive access.

## How this is tested

- Regression tests for every memory-safety bug found in review
  (`src/regression_tests.zig`, `src/api_tests.zig`).
- A model-based test that checks random write sequences against a reference
  model on every document type, allocation-failure tests for every
  allocating operation, and a byte-exact golden fixture
  (`src/property_tests.zig`).
- `validate` tests including every single-byte corruption of a sample document
  (`src/validate_tests.zig`).
- Coverage-guided fuzz targets for mutated documents, arbitrary bytes, JSON
  decoding and random write sequences (`src/fuzz_tests.zig`); their seed
  corpus and a deterministic mutation sweep run in every `zig build test`.
  Run them with `zig build test --fuzz=1M -Doptimize=ReleaseSafe
  -Dtest-filter=fuzz:`.
- CI builds the C library under UBSan (Debug and ReleaseSafe), runs the suite
  under valgrind, and runs lite3's own C tests against the vendored sources.
