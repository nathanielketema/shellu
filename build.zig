const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const readline = b.dependency("readline", .{
        .target = target,
        .optimize = optimize,
    });
    const readline_artifact = readline.artifact("readline");

    const translate_readline = b.addTranslateC(.{
        .root_source_file = b.path("src/readline.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_readline.addIncludePath(readline_artifact.getEmittedIncludeTree());

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "readline", .module = translate_readline.createModule() },
        },
        .link_libc = true,
    });
    mod.linkLibrary(readline_artifact);

    const exe = b.addExecutable(.{
        .name = "shellu",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run shellu 2");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_exe_tests.step);
}
