const std = @import("std");
const curl = @import("zigcurl/curl.zig");
const zlib = @import("zigcurl/zlib.zig");
const mbedtls = @import("zigcurl/mbedtls.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z = zlib.create(b, target);
    const tls = mbedtls.create(b, target);
    const libcurl = curl.create(b, target, optimize);
    libcurl.linkLibrary(z);
    libcurl.linkLibrary(tls);

    const tgz = b.addStaticLibrary(.{
        .name = "tgz",
        .root_source_file = .{ .path = "src/bot.zig" },
        .target = target,
        .optimize = optimize,
    });
    tgz.addIncludePath("src");
    tgz.addCSourceFile("src/jsmn.c", &.{"-std=c89"});
    tgz.installHeader("src/jsmn.h", "jsmn.h");
    tgz.linkLibrary(libcurl);
    b.installArtifact(tgz);

    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(tgz);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run example");
    run_step.dependOn(&run.step);
}
