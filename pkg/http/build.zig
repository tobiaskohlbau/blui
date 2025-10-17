const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("http", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "http",
        .root_module = module,
    });

    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");

    const unit_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_test);
    test_step.dependOn(&run_unit_tests.step);
}
