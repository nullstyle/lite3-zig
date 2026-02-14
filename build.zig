const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Options ---
    const enable_json = b.option(bool, "json", "Enable JSON conversion support (requires yyjson)") orelse true;
    const enable_error_messages = b.option(bool, "error-messages", "Enable lite3 error messages for debugging") orelse false;
    const enable_lto = b.option(bool, "lto", "Enable link-time optimization for the C library (currently unsupported)") orelse false;

    if (enable_lto) {
        std.log.err("`-Dlto=true` is currently unsupported in lite3-zig; remove the flag.", .{});
        std.process.exit(1);
    }

    // --- Paths ---
    const lite3_include_path = b.path("vendor/lite3/include");
    const lite3_lib_path = b.path("vendor/lite3/lib");
    const shim_include_path = b.path("src");

    // --- Compile the lite3 C library ---
    // The C library is always compiled with ReleaseFast because:
    //   1. It is a vendored dependency whose correctness is tested upstream.
    //   2. lite3 uses intentional out-of-bounds prefetch hints (__builtin_prefetch)
    //      that trigger false positives under Zig's Debug-mode bounds checks.
    const lite3_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "json_enabled", enable_json);

    const c_flags: []const []const u8 = &.{
        "-std=gnu11",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
        "-Wno-gnu-statement-expression",
        "-Wno-gnu-zero-variadic-macro-arguments",
    };

    // Core source files
    const core_sources: []const []const u8 = &.{
        "vendor/lite3/src/lite3.c",
        "vendor/lite3/src/ctx_api.c",
        "vendor/lite3/src/debug.c",
    };

    for (core_sources) |src| {
        lite3_mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = c_flags,
        });
    }

    // JSON-related source files
    if (enable_json) {
        const json_sources: []const []const u8 = &.{
            "vendor/lite3/src/json_enc.c",
            "vendor/lite3/src/json_dec.c",
            "vendor/lite3/lib/yyjson/yyjson.c",
            "vendor/lite3/lib/nibble_base64/base64.c",
        };
        for (json_sources) |src| {
            lite3_mod.addCSourceFile(.{
                .file = b.path(src),
                .flags = c_flags,
            });
        }
        lite3_mod.addIncludePath(lite3_lib_path);
    } else {
        // lite3 headers always declare JSON entry points. Provide explicit stubs
        // so `-Djson=false` links cleanly and JSON APIs return EINVAL.
        lite3_mod.addCSourceFile(.{
            .file = b.path("src/lite3_json_disabled.c"),
            .flags = c_flags,
        });
    }

    // Add the C shim file (with relaxed warnings for lite3 header quirks)
    const shim_flags: []const []const u8 = &.{
        "-std=gnu11",
        "-Wall",
        "-Wextra",
        "-Wno-pedantic",
        "-Wno-gnu-statement-expression",
        "-Wno-gnu-zero-variadic-macro-arguments",
    };
    lite3_mod.addCSourceFile(.{
        .file = b.path("src/lite3_shim.c"),
        .flags = shim_flags,
    });

    lite3_mod.addIncludePath(lite3_include_path);
    lite3_mod.addIncludePath(shim_include_path);

    if (enable_error_messages) {
        lite3_mod.addCMacro("LITE3_ERROR_MESSAGES", "");
    }

    const lite3_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lite3",
        .root_module = lite3_mod,
    });

    b.installArtifact(lite3_lib);

    // --- Public Zig module ---
    const zig_mod = b.addModule("lite3", .{
        .root_source_file = b.path("src/lite3.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_mod.addOptions("lite3_build_options", build_options);
    zig_mod.addIncludePath(shim_include_path);
    zig_mod.linkLibrary(lite3_lib);

    // --- Tests ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lite3", .module = zig_mod },
        },
    });
    test_mod.addIncludePath(shim_include_path);
    test_mod.linkLibrary(lite3_lib);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run lite3-zig tests");
    test_step.dependOn(&run_tests.step);

    // --- Benchmarks ---
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "lite3", .module = zig_mod },
        },
    });
    bench_mod.addIncludePath(shim_include_path);
    bench_mod.linkLibrary(lite3_lib);

    const bench_exe = b.addExecutable(.{
        .name = "lite3-bench",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run lite3-zig benchmarks");
    bench_step.dependOn(&run_bench.step);

    // --- Examples ---
    const example_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "basic", .path = "examples/basic.zig" },
        .{ .name = "json_roundtrip", .path = "examples/json_roundtrip.zig" },
    };

    const examples_step = b.step("examples", "Build example programs");

    for (example_files) |ex| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lite3", .module = zig_mod },
            },
        });
        ex_mod.addIncludePath(shim_include_path);
        ex_mod.linkLibrary(lite3_lib);

        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = ex_mod,
        });

        examples_step.dependOn(&b.addInstallArtifact(ex_exe, .{}).step);
    }
}
