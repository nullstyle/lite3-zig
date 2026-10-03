const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Options ---
    const enable_json = b.option(bool, "json", "Enable JSON conversion support (requires yyjson)") orelse true;
    const enable_error_messages = b.option(bool, "error-messages", "Print lite3 error messages to stderr (debugging aid)") orelse false;
    const enable_lto = b.option(bool, "lto", "Enable link-time optimization across Zig and C (lets calls into the shim inline)") orelse false;
    // The C code follows the Zig optimize mode by default, so Debug and
    // ReleaseSafe builds run the vendored C under UBSan.
    const c_optimize = b.option(
        std.builtin.OptimizeMode,
        "c-optimize",
        "Optimize mode for the lite3 C library (default: same as -Doptimize)",
    ) orelse optimize;

    const config: Config = .{
        .target = target,
        .optimize = optimize,
        .c_optimize = c_optimize,
        .json = enable_json,
        .error_messages = enable_error_messages,
        .lto = enable_lto,
    };

    const lite3 = addLite3(b, config, .public);
    b.installArtifact(lite3.lib);

    const check_step = b.step("check", "Compile tests, examples and benchmarks without running them");

    // --- Tests ---
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this (repeatable)") orelse &.{};
    const tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lite3", .module = lite3.module }},
        }),
    });
    if (enable_lto) enableLto(tests);
    check_step.dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run lite3-zig tests");
    test_step.dependOn(&run_tests.step);

    // Same tests under valgrind memcheck (needs valgrind on PATH; on x86_64
    // build with e.g. -Dcpu=x86_64_v3, as valgrind cannot decode AVX-512).
    const valgrind = b.addSystemCommand(&.{
        "valgrind",
        "--quiet",
        "--error-exitcode=1",
        "--leak-check=full",
        "--errors-for-leak-kinds=definite,indirect",
    });
    valgrind.addArtifactArg(tests);
    const valgrind_step = b.step("test-valgrind", "Run lite3-zig tests under valgrind");
    valgrind_step.dependOn(&valgrind.step);

    // --- Benchmarks ---
    // Benchmarks always measure optimized code, so they get their own
    // ReleaseFast build of the library regardless of -Doptimize.
    var bench_config = config;
    bench_config.optimize = .fast;
    bench_config.c_optimize = .fast;
    const bench_lite3 = addLite3(b, bench_config, .private);
    const bench_exe = b.addExecutable(.{
        .name = "lite3-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "lite3", .module = bench_lite3.module }},
        }),
    });
    // The same loops written against lite3's C API, for comparison.
    bench_exe.root_module.addCSourceFile(.{ .file = b.path("src/bench_raw.c"), .flags = &vendor_flags });
    bench_exe.root_module.addIncludePath(b.path("vendor/lite3/include"));
    if (enable_lto) enableLto(bench_exe);
    check_step.dependOn(&bench_exe.step);

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
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lite3", .module = lite3.module }},
            }),
        });
        if (enable_lto) enableLto(ex_exe);
        check_step.dependOn(&ex_exe.step);
        examples_step.dependOn(&b.addInstallArtifact(ex_exe, .{}).step);
    }

    // --- Upstream C tests ---
    // lite3's own test programs, built against the vendored (patched) sources
    // with the same configuration as the library. They expect to run from
    // the lite3 source root.
    const upstream_step = b.step("test-upstream", "Build and run lite3's upstream C tests");
    for (upstream_tests) |t| {
        if (t.needs_json and !enable_json) continue;
        const mod = b.createModule(.{ .target = target, .optimize = c_optimize, .link_libc = true });
        mod.addIncludePath(b.path("vendor/lite3/include"));
        mod.addCSourceFile(.{ .file = b.path(t.path), .flags = &vendor_flags });
        // lite3's C-heap context API is not part of the library (Document
        // replaces it), but its upstream tests still exercise it.
        mod.addCSourceFile(.{ .file = b.path("vendor/lite3/src/ctx_api.c"), .flags = &vendor_flags });
        mod.linkLibrary(lite3.lib);
        const exe = b.addExecutable(.{ .name = std.fs.path.stem(t.path), .root_module = mod });
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("vendor/lite3"));
        run.expectExitCode(0);
        upstream_step.dependOn(&run.step);
    }

    // --- C lint ---
    // The project's own C files must compile without warnings. (Zig only
    // shows C warnings when a compile fails, so they are promoted to errors
    // here; vendored upstream code is not held to this.)
    const lint_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    lint_mod.addIncludePath(b.path("vendor/lite3/include"));
    lint_mod.addIncludePath(b.path("src"));
    lint_mod.addCSourceFiles(.{
        .files = &.{ "src/lite3_shim.c", "src/lite3_json_disabled.c" },
        .flags = &(shim_flags ++ .{"-Werror"}),
    });
    const lint_lib = b.addLibrary(.{ .name = "lite3-lint", .linkage = .static, .root_module = lint_mod });
    const lint_step = b.step("lint-c", "Compile the project's own C sources with -Werror");
    lint_step.dependOn(&lint_lib.step);
}

const upstream_tests = [_]struct { path: []const u8, needs_json: bool }{
    .{ .path = "vendor/lite3/tests/alignment_zeroing.c", .needs_json = false },
    .{ .path = "vendor/lite3/tests/collisions.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/john_doe.c", .needs_json = false },
    .{ .path = "vendor/lite3/tests/nested_generations.c", .needs_json = false },
    .{ .path = "vendor/lite3/tests/type_queries.c", .needs_json = false },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_01_building_messages.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_02_reading_messages.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_03_strings.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_04_nesting.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_05_arrays.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_06_iterators.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/buffer_api_07_json_conversion.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_01_building_messages.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_02_reading_messages.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_03_strings.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_04_nesting.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_05_arrays.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_06_iterators.c", .needs_json = true },
    .{ .path = "vendor/lite3/tests/examples/context_api_07_json_conversion.c", .needs_json = true },
};

const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_optimize: std.builtin.OptimizeMode,
    json: bool,
    error_messages: bool,
    lto: bool,
};

const Lite3 = struct {
    lib: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

/// Flags for vendored upstream C sources.
const vendor_flags = [_][]const u8{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-Wpedantic",
    "-Wno-gnu-statement-expression",
    "-Wno-gnu-zero-variadic-macro-arguments",
};

/// Flags for this project's C sources. lite3's header macros rely on GNU
/// extensions, so -Wpedantic is off.
const shim_flags = [_][]const u8{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-Wno-pedantic",
    "-Wno-gnu-statement-expression",
    "-Wno-gnu-zero-variadic-macro-arguments",
};

/// Build the lite3 C library plus the Zig wrapper module that links it.
/// `.public` registers the module as this package's "lite3" export.
fn addLite3(b: *std.Build, config: Config, visibility: enum { public, private }) Lite3 {
    const target = config.target;

    const c_safe = isSafe(config.c_optimize);
    const lite3_mod = b.createModule(.{
        .target = target,
        .optimize = config.c_optimize,
        .link_libc = true,
        // A sanitized C library linked into an unsanitized (ReleaseFast/Small)
        // program has no UBSan runtime to report to, so trap instead.
        .sanitize_c = if (c_safe and !isSafe(config.optimize)) .trap else null,
    });
    lite3_mod.addIncludePath(b.path("vendor/lite3/include"));
    lite3_mod.addIncludePath(b.path("src"));

    lite3_mod.addCSourceFiles(.{
        .files = &.{
            "vendor/lite3/src/lite3.c",
            "vendor/lite3/src/debug.c",
        },
        .flags = &vendor_flags,
    });
    if (config.json) {
        // yyjson, base64 and lite3's JSON code as one translation unit with
        // the third-party symbols made private (see src/lite3_json.c).
        lite3_mod.addIncludePath(b.path("vendor/lite3/lib"));
        lite3_mod.addCSourceFile(.{
            .file = b.path("src/lite3_json.c"),
            .flags = &(vendor_flags ++ .{"-Wno-unused-function"}),
        });
    } else {
        // lite3 headers always declare JSON entry points. Provide explicit stubs
        // so `-Djson=false` links cleanly and JSON APIs return EINVAL.
        lite3_mod.addCSourceFile(.{ .file = b.path("src/lite3_json_disabled.c"), .flags = &shim_flags });
    }
    lite3_mod.addCSourceFile(.{ .file = b.path("src/lite3_shim.c"), .flags = &shim_flags });

    if (config.error_messages) lite3_mod.addCMacro("LITE3_ERROR_MESSAGES", "");
    // Upstream warns that prefetching can crash on non-x86 targets.
    const arch = target.result.cpu.arch;
    if (arch != .x86 and arch != .x86_64) lite3_mod.addCMacro("LITE3_DISABLE_PREFETCHING", "1");

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lite3",
        .root_module = lite3_mod,
    });
    if (config.lto) enableLto(lib);

    // The lite3 wire format is little-endian only. Fail with one clear message
    // instead of a page of C errors.
    if (arch.endian() == .big) {
        const fail = b.addFail("lite3 requires a little-endian target");
        lib.step.dependOn(&fail.step);
    }

    // Zig 0.17 removed @cImport; the shim header is translated here instead.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lite3_shim.h"),
        .target = target,
        .optimize = config.optimize,
    });
    translate_c.addIncludePath(b.path("vendor/lite3/include"));
    translate_c.addIncludePath(b.path("src"));

    const build_options = b.addOptions();
    build_options.addOption(bool, "json_enabled", config.json);

    const module_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/lite3.zig"),
        .target = target,
        .optimize = config.optimize,
        .imports = &.{.{ .name = "lite3_c", .module = translate_c.createModule() }},
    };
    const module = switch (visibility) {
        .public => b.addModule("lite3", module_options),
        .private => b.createModule(module_options),
    };
    module.addOptions("lite3_build_options", build_options);
    module.linkLibrary(lib);

    return .{ .lib = lib, .module = module };
}

fn isSafe(mode: std.builtin.OptimizeMode) bool {
    return mode == .debug or mode == .safe;
}

/// LTO needs the LLVM backend and LLD on every artifact that links the C
/// library, including Debug builds that would otherwise use the self-hosted
/// backend.
fn enableLto(compile: *std.Build.Step.Compile) void {
    compile.lto = .full;
    compile.use_llvm = true;
    compile.use_lld = true;
}
