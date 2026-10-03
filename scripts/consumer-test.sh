#!/bin/sh
# Build a throwaway project that depends on lite3-zig as a package, the way a
# user would: from a `git archive` tarball (so only committed files listed in
# build.zig.zon's .paths are available), with JSON both on and off.
#
# Usage: scripts/consumer-test.sh   (from anywhere inside the repository)
set -eu

repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$repo" archive --format=tar.gz --prefix=lite3-zig/ -o "$work/lite3-zig.tar.gz" HEAD

mkdir "$work/app" "$work/app/src"
cd "$work/app"

cat > build.zig.zon <<'ZON'
.{
    .name = .consumer,
    .version = "0.0.0",
    .fingerprint = 0x705b3727ff5a87e9,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{},
    .paths = .{""},
}
ZON

cat > build.zig <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const json = b.option(bool, "json", "Build lite3-zig with JSON decoding") orelse true;
    const lite3 = b.dependency("lite3_zig", .{ .target = target, .optimize = optimize, .json = json });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lite3", .module = lite3.module("lite3") }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.expectExitCode(0);
    b.getInstallStep().dependOn(&run.step);
}
ZIG

cat > src/main.zig <<'ZIG'
const std = @import("std");
const lite3 = @import("lite3");

pub fn main(init: std.process.Init) !void {
    var doc = try lite3.Document.init(init.gpa, .object);
    defer doc.deinit(init.gpa);
    try doc.set(init.gpa, lite3.root, "ok", true);
    if (!try doc.view().get(bool, lite3.root, "ok")) return error.Unexpected;
    if (lite3.json_enabled) {
        var parsed = try lite3.Document.fromJson(init.gpa, "[1,2,3]", .{});
        defer parsed.deinit(init.gpa);
        if (try parsed.view().count(lite3.root) != 3) return error.Unexpected;
    }
}
ZIG

zig fetch --save=lite3_zig "$work/lite3-zig.tar.gz"
# A fingerprint mismatch only warns; this run would show it.
zig build -Djson=true
zig build -Djson=false
echo "consumer build OK (json on and off)"
