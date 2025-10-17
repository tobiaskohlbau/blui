const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_files = b.addExecutable(.{
        .name = "embed_fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/embed_fs.zig"),
            .target = b.graph.host,
        }),
    });

    const tool_step = b.addRunArtifact(embed_files);
    tool_step.addDirectoryArg(b.path("ui/build/"));
    const output = tool_step.addOutputFileArg("ui.zig");

    const module = b.addModule("blui", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "blui",
        .root_module = module,
    });

    const http = b.dependency("http", .{});
    const mqtt = b.dependency("mqtt", .{});
    const ftp = b.dependency("ftp", .{});

    const http_module = http.module("http");
    const mqtt_module = mqtt.module("mqtt");
    const ftp_module = ftp.module("ftp");

    exe.root_module.addImport("http", http_module);
    exe.root_module.addImport("mqtt", mqtt_module);
    exe.root_module.addImport("ftp", ftp_module);

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

    const exe_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Copy documentation to prefix path");
    docs_step.dependOn(&exe_docs.step);
    docs_step.dependOn(&(moduleDocs(b, http_module, "httpz").step));
    docs_step.dependOn(&(moduleDocs(b, mqtt_module, "mqttz").step));
    docs_step.dependOn(&(moduleDocs(b, ftp_module, "mqttz").step));
}

fn moduleDocs(b: *std.Build, module: *std.Build.Module, name: []const u8) *std.Build.Step.InstallDir {
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = module,
    });

    const install_dir = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    return install_dir;
}
