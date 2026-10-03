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

# Run all test variants
test-all: test test-release test-fast test-no-json

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
    zig fmt --check src/lite3.zig src/tests.zig src/bench.zig

# Format source files
fmt:
    zig fmt src/lite3.zig src/tests.zig src/bench.zig
