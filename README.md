# lite3-zig

**WARNING: This library is fully vibe-coded;  it's just for me for now.  use at your own risk**

(Human's note: _aim's to be_) Idiomatic [Zig](https://ziglang.org/) wrapper for [Lite³](https://github.com/fastserial/lite3), a JSON-compatible zero-copy serialization format that encodes data as a B-tree inside a single contiguous buffer, allowing O(log n) access and mutation on any arbitrary field.

## Features

- **Three document types, one read API.** `Buffer` (caller-owned fixed memory), `Document` (growable; allocator passed per call, like `std.ArrayList`) and `ManagedDocument` (stores its allocator). All reads go through `View`.
- **Generic values.** `set(at, key, value)` stores null, bool, any integer, float, string or `lite3.bytes(...)`; `get(T, at, key)` reads into `i64`, `u16`, `f32`, `bool`, `[]const u8`, `lite3.Bytes`, `?T` or `lite3.Value`, with range checks.
- **Compile-time keys.** `lite3.key("name")` hashes at compile time; plain `[]const u8` keys need no NUL terminator.
- **Reads in Zig.** Lookups, iteration and JSON encoding are implemented in Zig on top of the format, with bounds checks on every access. Writes (B-tree insertion) go through lite3's C code.
- **Lifetime checks.** A `View` or iterator taken before a write returns `error.StaleView` instead of reading moved or overwritten memory.
- **Untrusted input.** Serialized bytes are validated before use; JSON input is bounded in depth and size. See [SECURITY.md](SECURITY.md).
- **JSON.** Encoding to any `std.Io.Writer` is always available and allocation-free; decoding uses the bundled yyjson with a Zig allocator and reports the error position.
- **Specific errors.** Separate error sets for reads, writes, growth, JSON decoding and encoding.

## Requirements

- **Zig 0.17.0** (pinned in `.mise.toml`)
- A C11-capable toolchain (provided by Zig)
- A little-endian target (the format is little-endian; big-endian builds fail with a clear message)

The C source for lite3 is vendored directly in `vendor/lite3/` — no submodules needed. `vendor/lite3/UPSTREAM` records the upstream commit, and local changes live as patches in `vendor/patches/`. Re-vendor with `scripts/update-vendor.sh` (or `just update-vendor`); never edit `vendor/lite3/` by hand.

## Quick start

```zig
const std = @import("std");
const lite3 = @import("lite3");
const root = lite3.root;

// Fixed memory: writes fail with error.NoSpaceLeft when it is full.
var mem: [4096]u8 align(4) = undefined;
var buf = try lite3.Buffer.init(&mem, .object);
try buf.set(root, "name", "Alice");
try buf.set(root, "age", 30);
const tags = try buf.setArray(root, "tags");
try buf.append(tags, "admin");

const v = buf.view();
const name = try v.get([]const u8, root, "name"); // "Alice"
const age = try v.get(u8, root, lite3.key("age")); // 30
std.debug.print("{s} {d} {f}\n", .{ name, age, v }); // {f}: compact JSON

// Growable memory.
const gpa = std.heap.smp_allocator;
var doc = try lite3.Document.init(gpa, .object);
defer doc.deinit(gpa);
try doc.set(gpa, root, "event", "login");

// Received bytes: validated before use.
const received = try lite3.View.fromBytes(doc.slice());
_ = try received.get([]const u8, root, "event");

// JSON (decoding needs the default -Djson=true).
var parsed = try lite3.Document.fromJson(gpa, "{\"a\":[1,2,3]}", .{});
defer parsed.deinit(gpa);
```

## Building

```bash
# Build the static library
zig build

# Run all tests
zig build test

# Build with specific optimization
zig build -Doptimize=ReleaseFast
```

### Build options

| Option             | Default | Description                                  |
|--------------------|---------|----------------------------------------------|
| `-Djson=false`     | `true`  | Leave out yyjson; JSON decoding functions become compile errors (encoding still works) |
| `-Derror-messages` | `false` | Print lite3 debug error messages to stderr   |
| `-Dlto=true`       | `false` | Link-time optimization across Zig and C (inlines shim calls; uses the LLVM backend for every artifact) |
| `-Dc-optimize=…`   | same as `-Doptimize` | Optimize mode for the C library. In Debug/ReleaseSafe the C code runs under UBSan |

Build steps: `test`, `test-upstream` (lite3's own C tests against the vendored sources), `test-valgrind` (needs valgrind; pass `-Dcpu=x86_64_v3`), `examples`, `bench` (always ReleaseFast; compares each operation with lite3's C API), `check` (compile everything without running), `lint-c` (project C sources with `-Werror`).

### Building examples

```bash
zig build examples
```

### Running benchmarks

```bash
zig build bench
```

## Using as a dependency

Add this package to your `build.zig.zon`:

```zig
.dependencies = .{
    .lite3 = .{
        .url = "https://github.com/<your-fork>/lite3-zig/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const lite3_dep = b.dependency("lite3", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("lite3", lite3_dep.module("lite3"));
```

## Examples

See the `examples/` directory:

- **`basic.zig`** — Buffer and Document, nested containers, typed reads, compile-time keys, iteration, sending bytes
- **`json_roundtrip.zig`** — JSON encoding (compact and indented), decoding, and error diagnostics

## API overview

### Concepts

- **`Offset`** names a container (object or array) inside a document; `lite3.root` is the root. `setObject`/`setArray`/`appendObject`/… return the new container's Offset. Offsets stay valid when a `Document` grows, but an Offset whose container was overwritten no longer refers to it.
- **`View`** is the read side: cheap to copy, obtained with `.view()` or from bytes with `View.fromBytes` (validates) / `View.fromBytesUnchecked`. Slices it returns point into the document and are valid until the next write; after a write the View returns `error.StaleView`, so take a new one.
- **Keys** are `[]const u8`, string literals, or `lite3.Key` (`lite3.key("k")` at compile time, `Key.init(str)` at run time). Keys must not contain NUL.

### Types

| Type | Description |
|---|---|
| `View` | Reads, iteration, JSON encoding |
| `Buffer` | Document in caller-owned, fixed-size, 4-aligned memory |
| `Document` | Growable document; takes `gpa` on each call that may allocate |
| `ManagedDocument` | `Document` that stores its allocator |
| `Offset`, `root` | Container handle (`enum(u32)`) and the root container |
| `Container` | `.object` or `.array` |
| `Type`, `Value` | Value kinds and a decoded value (strings/bytes point into the document) |
| `Key`, `key()` | Key with precomputed hash |
| `Bytes`, `bytes()` | Marks a slice as lite3 bytes rather than a string |
| `ObjectIterator`, `ArrayIterator` | Yield `{ key, value }` / `{ index, value }` in storage order |
| `ReadError`, `WriteError`, `GrowError`, `DecodeError`, `EncodeError`, `Error` | Error sets |
| `JsonOptions`, `JsonDiagnostics` | Encoder whitespace; decoder error position and message |

### View

| Method | Description |
|---|---|
| `get(T, at, key)` / `arrGet(T, arr, index)` | Typed read (`error.TypeMismatch`, `error.IntegerOverflow`) |
| `getValue` / `arrValue` | Read as `Value` |
| `getObject` / `getArray` / `arrGetObject` / `arrGetArray` | Nested container Offset |
| `typeOf`, `has`, `count`, `containerType`, `rootType` | Queries |
| `objectIterator` / `arrayIterator` | Iteration |
| `writeJson(at, writer, options)` / `jsonAlloc(gpa, at, options)` / `{f}` | JSON encoding |

### Writing (Buffer, Document, ManagedDocument)

The same methods on all three; `Document`'s take the allocator first.

| Method | Description |
|---|---|
| `set(at, key, value)` | Insert or replace a scalar |
| `setObject` / `setArray` | Insert or replace with an empty container; returns its Offset |
| `append(arr, value)` / `appendObject` / `appendArray` | Append to an array |
| `arrSet(arr, index, value)` / `arrSetObject` / `arrSetArray` | Replace element `index` (`index == count` appends) |
| `reset(root_type)` | Make the document an empty object or array |
| `slice()` / `capacity()` | Serialized bytes; capacity |

Constructors: `Buffer.init(mem, root_type)`, `Buffer.fromBytes(mem, len)`, `Buffer.fromJson(gpa, mem, json, diag)`; `Document.init(gpa, root_type)`, `initOptions(gpa, .{ .root, .initial_capacity, .max_capacity })`, `fromBytes(gpa, bytes)`, `fromJson(gpa, json, .{ .max_capacity, .diagnostics })`. Every constructor that takes bytes validates them unless its name ends in `Unchecked`.

`Document` also has `reserve`, `shrinkToFit`, `importBytes`, `decodeJson` (replaces the content; unchanged on error), `clone` and `compact` (rewrites the document without the space left by overwritten values — lite3 never reclaims it in place).

A write that fails leaves a valid document behind. For a `Document`, a failed allocation leaves the document as it was before the call.

## Project structure

```
lite3-zig/
├── build.zig, build.zig.zon, Justfile, .mise.toml
├── src/
│   ├── lite3.zig           # The module: View, Buffer, Document, JSON encoder
│   ├── validate.zig        # Document validation (validate, validateStrict)
│   ├── lite3_shim.{c,h}    # C shim: B-tree inserts, JSON decoding
│   ├── lite3_json.c        # yyjson + lite3 JSON decoder as one translation unit
│   ├── lite3_json_disabled.c
│   ├── *_tests.zig         # API, validation, regression, property and fuzz tests
│   ├── testdata/           # Golden fixtures
│   ├── bench.zig, bench_raw.c
├── examples/
├── scripts/update-vendor.sh
└── vendor/
    ├── lite3/              # Vendored upstream sources (github.com/fastserial/lite3)
    └── patches/            # Local fixes applied on top
```

## Development

```bash
# With mise and just installed:
mise install          # Install Zig 0.17.0
just test             # Run tests
just test-release     # Run tests with ReleaseSafe
just test-no-json     # Run tests with JSON backend disabled
just clean            # Remove build artifacts
just update-vendor    # Re-vendor lite3 and apply vendor/patches
just act-local        # Run local CI in act

```

### Local GitHub Actions (act)

To run CI locally, use the dedicated workflow in `.github/workflows/ci-local.yml`:

```bash
act workflow_dispatch -W .github/workflows/ci-local.yml
```

If you install act and want a short alias, use `just act-local` from the root of this repository.

The local workflow intentionally mirrors the existing CI commands on Linux so it can run in `act` consistently without requiring a macOS runner.

## Safety notes

### Untrusted input

Serialized documents and JSON from outside your program are supported input. Constructors that take serialized bytes run `lite3.validate` first; `lite3.validateStrict` additionally guarantees a document stays valid under writes. Bound memory with `Document.initOptions(gpa, .{ .max_capacity = n })` or `fromJson(.., .{ .max_capacity = n })`. See [SECURITY.md](SECURITY.md) for the exact guarantees and known limitations (hash flooding, lossy JSON round trips).

### Lifetimes

Strings, bytes and keys returned by reads point into the document. They are valid until the next write to that document (a write may overwrite them in place, and a `Document` may move its memory). Views and iterators detect this and return `error.StaleView`; slices you already hold cannot, so copy what you need to keep before writing.

Writing a value or key that was read from the same document is supported: it is copied aside first (for a `Buffer`, up to `Buffer.alias_scratch_len` bytes of value).

A `Document` must not be copied by value while both copies are used: they would share memory. Use `clone`.

### Thread safety

A document may be read from several threads at once; any write needs exclusive access (e.g. a `Mutex` or `RwLock`).

## Architecture notes

### Reads in Zig, writes in C

Reads (lookup with lite3's hash probing, iteration, JSON encoding) are written in Zig against the documented format, so they need no C calls and check every offset against the document's bounds. Writes need lite3's B-tree insertion and node splitting, which a small C shim (`src/lite3_shim.c`) exposes as two functions; it maps errors to status codes inside C, so the Zig side never reads `errno`. JSON decoding runs yyjson through the shim with a Zig allocator.

Performance (`zig build bench`): reads are faster than lite3's C getters; writes cost roughly 15–20% more instructions than calling lite3's C macros directly, from the type and lifetime checks.

### Build optimization

The C library follows `-Doptimize`, so Debug and ReleaseSafe builds run the vendored C code under UBSan; `-Dc-optimize` sets it separately (for example a ReleaseFast C library under a Debug build). The benchmark step always builds both in ReleaseFast.

## License

MIT License. See [LICENSE](LICENSE) for details.
