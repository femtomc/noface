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

    // Link SQLite for transcript storage
    lib_mod.link_libc = true;
    lib_mod.linkSystemLibrary("sqlite3", .{});

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

    // Serve step (shortcut for `zig build serve`)
    const serve_step = b.step("serve", "Run the web dashboard");
    const serve_cmd = b.addRunArtifact(exe);
    serve_cmd.addArg("serve");
    serve_step.dependOn(&serve_cmd.step);
    serve_cmd.step.dependOn(b.getInstallStep());

    // Test step - only run lib_tests since exe_tests duplicates them via the noface import
    // (exe.root_module imports noface which is lib_mod, so all tests run through lib_tests)
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    // Run exe_tests after lib_tests to avoid parallel test conflicts
    run_exe_tests.step.dependOn(&run_lib_tests.step);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
