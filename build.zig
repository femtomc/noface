const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module
    const lib_mod = b.addModule("noface", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main CLI executable
    const exe = b.addExecutable(.{
        .name = "noface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noface", .module = lib_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the agent loop");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
