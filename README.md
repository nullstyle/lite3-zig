# lite3-zig

**WARNING: This library is fully vibe-coded;  it's just for me for now.  use at your own risk**

(Human's note: _aim's to be_) Idiomatic [Zig](https://ziglang.org/) wrapper for [Lite³](https://github.com/fastserial/lite3), a JSON-compatible zero-copy serialization format that encodes data as a B-tree inside a single contiguous buffer, allowing O(log n) access and mutation on any arbitrary field.

## Features

- **Buffer API** — fixed-size, caller-managed memory; ideal for embedded, real-time, or arena-based workflows.
- **Context API** — heap-allocated, auto-growing buffer; convenient for general-purpose use.
- **Full type support** — null, bool, i64, f64, string, bytes, nested objects, and arrays.
- **JSON round-trip** — encode to / decode from JSON via the bundled yyjson backend.
- **Iteration** — iterate over object keys or array elements.
- **Proper error handling** — all C error codes are translated to Zig error unions.
- **Flexible keys** — accepts `[]const u8` keys (no sentinel terminator required; embedded `\0` is rejected).
- **Zero `@cImport` issues** — a thin C shim wraps the inline functions that Zig's translate-c cannot handle (alignment casts, flexible array members, GNU statement expressions).

## Requirements

- **Zig ≥ 0.15.2**
- A C11-capable toolchain (provided by Zig)

The C source for lite3 is vendored directly in `vendor/lite3/` — no submodules needed.

## Quick start

```zig
const lite3 = @import("lite3");

// Using the Context API (auto-growing buffer)
var ctx = try lite3.Context.create();
defer ctx.destroy();

try ctx.initObj();
try ctx.setStr(lite3.root, "name", "Alice");
try ctx.setI64(lite3.root, "age", 30);

const name = try ctx.getStr(lite3.root, "name");
// name == "Alice"

// Encode to JSON
const json = try ctx.jsonEncode(lite3.root);
defer json.deinit();
```

```zig
// Using the Buffer API (fixed-size, caller-managed memory)
var mem: [4096]u8 align(4) = undefined;
var buf = try lite3.Buffer.initObj(&mem);

try buf.setI64(lite3.root, "answer", 42);
const val = try buf.getI64(lite3.root, "answer");
// val == 42
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
| `-Djson=false`     | `true`  | Disable JSON backend; JSON APIs return `error.InvalidArgument` |
| `-Derror-messages` | `false` | Enable lite3 debug error messages to stdout  |
| `-Dlto=true`       | `false` | Currently unsupported (build fails fast with a clear message) |

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

See the `examples/` directory for standalone example programs:

- **`basic.zig`** --- Creating documents, setting/getting values, nested objects and arrays, iteration
- **`json_roundtrip.zig`** --- JSON encode/decode round-trips with both Buffer and Context APIs

## API overview

### Types

| Zig type          | Description                                          |
|-------------------|------------------------------------------------------|
| `Buffer`          | Fixed-size buffer with caller-managed memory         |
| `Context`         | Heap-allocated, auto-growing buffer                  |
| `Type`            | Enum of value types (null, bool_, i64_, f64_, etc.)  |
| `Offset`          | Typed offset handle into the buffer (`enum(usize)`)  |
| `Error`           | Error set (NotFound, InvalidArgument, etc.)          |
| `Value`           | Tagged union for dynamic access (null, bool_, i64_, etc.) |
| `JsonString`      | Opaque handle to C-allocated JSON; freed via `.deinit()` |
| `Buffer.Iterator` | Iterator over object/array entries                   |

### Buffer API

| Method                | Description                                |
|-----------------------|--------------------------------------------|
| `initObj` / `initArr` | Initialize as object or array              |
| `setNull/Bool/I64/F64/Str/Bytes/Obj/Arr` | Set a value by key      |
| `getBool/I64/F64/Str/Bytes/Obj/Arr`       | Get a value by key      |
| `getType` / `exists`  | Query type or existence of a key (`Error!`) |
| `getValue`            | Get value as a `Value` tagged union        |
| `getStrCopy` / `getBytesCopy` | Copy string/bytes into caller buffer (safe) |
| `arrAppend*`          | Append values to an array                  |
| `arrGet*`             | Get values from an array by index          |
| `arrGetStrCopy` / `arrGetBytesCopy` | Copy array string/bytes into caller buffer |
| `count`               | Count entries in an object or array        |
| `iterate`             | Create an iterator                         |
| `jsonDecode`          | Decode JSON into a buffer                  |
| `jsonEncode`          | Encode buffer contents to JSON (`JsonString`) |
| `jsonEncodePretty`    | Encode to pretty-printed JSON (`JsonString`) |
| `jsonEncodeBuf`       | Encode JSON into a caller-supplied buffer  |

### Context API

The Context API mirrors the Buffer API but manages memory automatically. All methods from the Buffer API are available with the same names.

## Project structure

```
lite3-zig/
├── build.zig           # Zig build system
├── build.zig.zon       # Package metadata
├── Justfile            # Task automation
├── .mise.toml          # Dev environment (Zig 0.15.2)
├── src/
│   ├── lite3.zig       # Zig wrapper module
│   ├── lite3_shim.c    # C shim for inline functions
│   ├── lite3_shim.h    # C shim header
│   ├── lite3_json_disabled.c # JSON stubs for -Djson=false
│   ├── bench.zig       # Benchmarks
│   └── tests.zig       # Comprehensive test suite
├── examples/
│   ├── basic.zig          # Basic usage example
│   └── json_roundtrip.zig # JSON encode/decode example
└── vendor/
    └── lite3/          # Vendored upstream sources (github.com/fastserial/lite3)
```

## Development

```bash
# With mise and just installed:
mise install          # Install Zig 0.15.2
just test             # Run tests
just test-release     # Run tests with ReleaseSafe
just test-no-json     # Run tests with JSON backend disabled
just clean            # Remove build artifacts
just update-vendor    # Update vendored lite3 sources
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

### Dangling pointers

Methods that return string or byte slices (`getStr`, `getBytes`, `arrGetStr`, `arrGetBytes`) return pointers **directly into the underlying buffer**. These slices are invalidated by:

- **Any mutation** to the same buffer (Buffer API)
- **Any mutation** to the context (Context API), since the context may reallocate its internal buffer

To safely retain a value across mutations, use the copy variants:

```zig
var dest: [256]u8 = undefined;
const safe = try buf.getStrCopy(lite3.root, "key", &dest);
// safe remains valid after mutations
```

The copy variants are: `getStrCopy`, `getBytesCopy`, `arrGetStrCopy`, `arrGetBytesCopy`.

### Thread safety

Buffer and Context are **not thread-safe**. Concurrent reads and writes require external synchronization (e.g. a `Mutex`). Iterators are also invalidated by any mutation.

## Architecture notes

### C shim layer

Lite³ makes heavy use of GNU C extensions (statement expressions, `__builtin_prefetch`) and C patterns (flexible array members, `volatile` casts) that Zig's `translate-c` cannot handle. Rather than patching the upstream library, a thin C shim (`src/lite3_shim.c`) wraps every inline function as a proper `extern` function, giving Zig clean function pointers to call.

### Build optimization

The C library is always compiled with `-OReleaseFast` regardless of the Zig optimization level. This is because lite3 uses intentional out-of-bounds `__builtin_prefetch` hints for performance that would trigger false positives under Zig's Debug-mode bounds checking. The Zig wrapper code itself respects the user's chosen optimization level.

## License

MIT License. See [LICENSE](LICENSE) for details.
