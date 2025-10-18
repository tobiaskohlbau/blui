const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const node_modules_exists = blk: {
        var dir = std.fs.cwd().openDir("ui/node_modules", .{}) catch break :blk false;
        defer dir.close();
        break :blk true;
    };

    const pnpm_install = if (!node_modules_exists) b.addSystemCommand(&[_][]const u8{ "pnpm", "install" }) else null;
    if (pnpm_install) |install| {
        install.cwd = b.path("ui");
    }

    const ui_build_step = b.addSystemCommand(&[_][]const u8{ "pnpm", "build" });
    ui_build_step.cwd = b.path("ui");
    if (pnpm_install) |install| {
        ui_build_step.step.dependOn(&install.step);
    }

    const embed_files = b.addExecutable(.{
        .name = "embed_fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_fs.zig"),
            .target = b.graph.host,
        }),
    });

    const tool_step = b.addRunArtifact(embed_files);
    tool_step.step.dependOn(&ui_build_step.step);
    tool_step.addDirectoryArg(b.path("ui/build/"));
    const output = tool_step.addOutputFileArg("ui.zig");

    const module = b.addModule("blUI", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "blUI",
        .root_module = module,
    });

    const http = b.dependency("http", .{});
    const mqtt = b.dependency("mqtt", .{});
    const ftp = b.dependency("ftp", .{});

    exe.root_module.addImport("http", http.module("http"));
    exe.root_module.addImport("mqtt", mqtt.module("mqtt"));
    exe.root_module.addImport("ftp", ftp.module("ftp"));

    exe.root_module.addAnonymousImport("ui", .{
        .root_source_file = output,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
