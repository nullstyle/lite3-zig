# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org); before 1.0, minor versions may
break the API. A change to the bytes the library writes (see "Wire format" in
the README) is always called out.

## 0.1.0 — 2026-10-03

First release. Tested with Zig 0.17.0.

### API

- `View` for reads, iteration and JSON encoding; `Buffer` (fixed, caller-owned
  memory), `Document` (growable, allocator passed per call) and
  `ManagedDocument` (stores its allocator) for writes. These replace the
  earlier `Buffer`/`Context`/`ManagedContext`/`ExternalContext` types; there
  are no compatibility aliases.
- Generic `set(at, key, value)` and `get(T, at, key)`; `lite3.key("k")`
  hashes keys at compile time.
- Views and iterators return `error.StaleView` after a write instead of
  reading moved memory.
- Separate error sets for reading, writing, growing, JSON decoding and JSON
  encoding.
- JSON encoding is pure Zig and always available; decoding uses yyjson with
  your allocator and reports the error position. `-Djson=false` leaves out
  yyjson.
- `Document.clone` and `Document.compact` (reclaims space left by
  overwrites).

### Safety

- Serialized bytes are validated before use (`validate`, `validateStrict`);
  JSON input is bounded in depth and size. See `SECURITY.md`.
- Ten local patches to lite3 fix memory-safety and correctness bugs found in
  review (`vendor/patches/`).

### Wire format

- Byte-compatible with lite3 at upstream commit 48ab0e9. Patch 0010 zeroes
  alignment padding that upstream left uninitialised; documents are otherwise
  identical.
