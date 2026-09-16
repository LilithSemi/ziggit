const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");

    const ziggit = b.addModule("ziggit", .{
        .root_source_file = b.path("lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, ziggit);
}

/// Adds a test run for `module` to `test_step`.
///
/// A build for a different target analyses every declaration and skips only
/// the run. `zig build test -Dtarget=aarch64-macos` therefore compiles each
/// module for Darwin instead of failing the whole build on the first module.
fn addModuleTests(b: *std.Build, test_step: *std.Build.Step, module: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    run.skip_foreign_checks = true;
    test_step.dependOn(&run.step);
}
