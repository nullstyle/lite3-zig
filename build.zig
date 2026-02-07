const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Options ---
    const enable_json = b.option(bool, "json", "Enable JSON conversion support (requires yyjson)") orelse true;
    const enable_error_messages = b.option(bool, "error-messages", "Enable lite3 error messages for debugging") orelse false;

    // --- Compile the lite3 C library ---
    // The C library is always compiled with ReleaseFast because:
    //   1. It is a vendored dependency whose correctness is tested upstream.
    //   2. lite3 uses intentional out-of-bounds prefetch hints (__builtin_prefetch)
    //      that trigger false positives under Zig's Debug-mode bounds checks.
    const lite3_lib = b.addStaticLibrary(.{
        .name = "lite3",
        .target = target,
        .optimize = .ReleaseFast,
    });

    const lite3_include_path = b.path("vendor/lite3/include");
    const shim_include_path = b.path("src");

    // Core source files
    const core_sources: []const []const u8 = &.{
        "vendor/lite3/src/lite3.c",
        "vendor/lite3/src/ctx_api.c",
        "vendor/lite3/src/debug.c",
    };

    // JSON-related source files
    const json_sources: []const []const u8 = &.{
        "vendor/lite3/src/json_enc.c",
        "vendor/lite3/src/json_dec.c",
        "vendor/lite3/lib/yyjson/yyjson.c",
        "vendor/lite3/lib/nibble_base64/base64.c",
    };

    const c_flags: []const []const u8 = &.{
        "-std=gnu11",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
        "-Wno-gnu-statement-expression",
        "-Wno-gnu-zero-variadic-macro-arguments",
    };

    for (core_sources) |src| {
        lite3_lib.addCSourceFile(.{
            .file = b.path(src),
            .flags = c_flags,
        });
    }

    if (enable_json) {
        for (json_sources) |src| {
            lite3_lib.addCSourceFile(.{
                .file = b.path(src),
                .flags = c_flags,
            });
        }
        lite3_lib.addIncludePath(b.path("vendor/lite3/lib"));
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
    lite3_lib.addCSourceFile(.{
        .file = b.path("src/lite3_shim.c"),
        .flags = shim_flags,
    });

    lite3_lib.addIncludePath(lite3_include_path);
    lite3_lib.addIncludePath(shim_include_path);
    lite3_lib.linkLibC();

    if (enable_error_messages) {
        lite3_lib.root_module.addCMacro("LITE3_ERROR_MESSAGES", "");
    }

    b.installArtifact(lite3_lib);

    // --- Zig module ---
    const lite3_mod = b.addModule("lite3", .{
        .root_source_file = b.path("src/lite3.zig"),
        .target = target,
        .optimize = optimize,
    });
    lite3_mod.addIncludePath(shim_include_path);
    lite3_mod.linkLibrary(lite3_lib);

    // --- Tests ---
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("lite3", lite3_mod);
    tests.addIncludePath(shim_include_path);
    tests.linkLibrary(lite3_lib);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run lite3-zig tests");
    test_step.dependOn(&run_tests.step);
}
