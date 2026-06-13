const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const readline = b.dependency("readline", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_readline = b.addTranslateC(.{
        .root_source_file = b.path("include/readline.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_readline.addIncludePath(readline.path("."));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "readline", .module = translate_readline.createModule() },
        },
    });
    mod.linkLibrary(readline.artifact("readline"));

    const exe = b.addExecutable(.{
        .name = "shellu",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run shellu");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_exe_tests.step);
}
