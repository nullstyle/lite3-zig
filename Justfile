# lite3-zig task automation

# Build the library
build:
    zig build

# Run all tests (Debug mode)
test:
    zig build test

# Run tests with ReleaseSafe optimization
test-release:
    zig build test -Doptimize=ReleaseSafe

# Run tests with ReleaseFast optimization
test-fast:
    zig build test -Doptimize=ReleaseFast

# Run tests with JSON support disabled
test-no-json:
    zig build test -Djson=false

# Run lite3's upstream C tests against the vendored sources
test-upstream:
    zig build test-upstream

# Run the tests under valgrind (valgrind cannot decode AVX-512, hence the CPU pin)
test-valgrind:
    zig build test-valgrind -Dcpu=x86_64_v3

# Coverage-guided fuzzing (LLVM backend needed, hence ReleaseSafe). Example: just fuzz 5M "fuzz: JSON"
fuzz limit="1M" filter="fuzz:":
    zig build test -Doptimize=ReleaseSafe "-Dtest-filter={{filter}}" --fuzz={{limit}}

# Compile the project's own C sources with -Werror
lint-c:
    zig build lint-c

# Run all test variants
test-all: test test-release test-fast test-no-json test-upstream

# Run the local GitHub Actions CI workflow with act
act-local:
    act -W .github/workflows/ci-local.yml

# Build example programs
examples:
    zig build examples

# Clean build artifacts
clean:
    rm -rf .zig-cache zig-out

# Re-vendor lite3 (pinned commit in vendor/lite3/UPSTREAM, or pass one) and apply vendor/patches
update-vendor commit="":
    scripts/update-vendor.sh {{commit}}

# Run benchmarks
bench:
    zig build bench

# Check source formatting
fmt-check:
    zig fmt --check build.zig build.zig.zon src examples

# Format source files
fmt:
    zig fmt build.zig build.zig.zon src examples
