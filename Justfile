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

# Clean build artifacts
clean:
    rm -rf .zig-cache zig-out

# Update the lite3 submodule to latest
update-vendor:
    git submodule update --remote vendor/lite3
