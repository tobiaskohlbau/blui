const std = @import("std");

const UiBuildStep = struct {
    step: std.Build.Step,
    ui_path: std.Build.LazyPath,

    pub fn create(b: *std.Build, ui_path: std.Build.LazyPath) *UiBuildStep {
        const self = b.allocator.create(UiBuildStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "ui-build",
                .owner = b,
                .makeFn = make,
            }),
            .ui_path = ui_path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *UiBuildStep = @fieldParentPtr("step", step);
        const b = self.step.owner;

        const graph = b.graph;
        const io = graph.io;

        const ui_dir_path = self.ui_path.getPath3(b, step);
        const ui_dir = ui_dir_path.sub_path;

        // Create cache manifest for pnpm install
        var install_man = b.graph.cache.obtain();
        defer install_man.deinit();

        // Add package files to install manifest
        _ = try install_man.addFilePath(self.ui_path.path(b, "package.json").getPath3(b, step), null);
        _ = try install_man.addFilePath(self.ui_path.path(b, "pnpm-lock.yaml").getPath3(b, step), null);

        const install_cache_hit = try step.cacheHitAndWatch(&install_man);
        if (!install_cache_hit) {
            var child = try std.process.spawn(io, .{
                .argv = &.{ "pnpm", "install" },
                .cwd = ui_dir,
            });

            const term = try child.wait(io);
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        return error.PnpmInstallFailed;
                    }
                },
                .signal => {
                    return error.ProcessTerminated;
                },
                .stopped, .unknown => {
                    return error.ProcessTerminated;
                },
            }

            const node_modules_path = try std.fs.path.join(b.allocator, &.{ ui_dir, "node_modules" });
            defer b.allocator.free(node_modules_path);

            const node_modules_dir = try b.build_root.handle.openDir(io, node_modules_path, .{ .iterate = true });
            var walker = try node_modules_dir.walk(b.allocator);
            while (try walker.next(io)) |entry| {
                switch (entry.kind) {
                    .file => {
                        const sub = try std.fs.path.join(b.allocator, &.{ node_modules_path, entry.path });
                        defer b.allocator.free(sub);
                        _ = try install_man.addFilePost(sub);
                    },
                    else => {},
                }
            }

            try step.writeManifestAndWatch(&install_man);
        }

        // Create cache manifest for UI build
        var build_man = b.graph.cache.obtain();
        defer build_man.deinit();

        // Add ui sources to manifest
        var dir = try b.build_root.handle.openDir(io, ui_dir, .{ .iterate = true, .follow_symlinks = false });

        var walker = try dir.walk(b.allocator);
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    const sub = try std.fs.path.join(b.allocator, &.{ ui_dir, entry.path });
                    defer b.allocator.free(sub);
                    _ = try build_man.addFilePath(.{ .root_dir = b.build_root, .sub_path = sub }, null);
                    try step.addWatchInput(b.path(sub));
                },
                .directory => {
                    if (std.mem.eql(u8, entry.path, "build") or std.mem.eql(u8, entry.path, ".svelte-kit")) {
                        walker.leave(io);
                        continue;
                    }
                },
                else => {},
            }
        }

        const build_cache_hit = try step.cacheHitAndWatch(&build_man);
        if (!build_cache_hit) {
            var child = try std.process.spawn(io, .{
                .argv = &.{ "pnpm", "run", "build" },
                .cwd = ui_dir,
            });

            const term = try child.wait(io);
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        return error.UiBuildFailed;
                    }
                },
                .signal => {
                    return error.ProcessTerminated;
                },
                .stopped, .unknown => {
                    return error.ProcessTerminated;
                },
            }
            try step.writeManifestAndWatch(&build_man);
        }
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ui_path = b.path("ui");
    const ui_build_step = UiBuildStep.create(b, ui_path);

    const embed_files = b.addExecutable(.{
        .name = "embed_fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_fs.zig"),
            .target = b.graph.host,
        }),
    });

    const tool_step = b.addRunArtifact(embed_files);
    tool_step.step.dependOn(&ui_build_step.step);
    tool_step.addDirectoryArg(ui_path.path(b, "build"));
    tool_step.has_side_effects = true;

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
