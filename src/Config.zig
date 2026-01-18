const std = @import("std");
const builtin = @import("builtin");

const Config = @This();

dev: bool,
access_code: []const u8,
ip: []const u8,
serial: []const u8,
ca_bundle: ?std.crypto.Certificate.Bundle,

const File = struct {
    access_code: []const u8,
    ip: []const u8,
    serial: []const u8,
};

fn getConfigPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    switch (builtin.target.os.tag) {
        .macos, .linux => {
            const config_folder = environ.getAlloc(allocator, "XDG_CONFIG_HOME") catch return error.NoXdgConfigHome;
            defer allocator.free(config_folder);
            return try std.fs.path.join(allocator, &.{ config_folder, "blui", "config.zon" });
        },
        .windows => {
            const appdata = std.environ.getAlloc(allocator, "APPDATA") catch return error.NoAppData;
            defer allocator.free(appdata);
            return try std.fs.path.join(allocator, &.{ appdata, "blui", "config.zon" });
        },
        else => return error.UnsupportedOS,
    }
}

pub fn save(c: *Config, allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const path = try getConfigPath(allocator, environ);
    defer allocator.free(path);

    const config_dir = std.fs.path.dirname(path);
    if (config_dir) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);

    const config_file: File = .{
        .access_code = c.access_code,
        .ip = c.ip,
        .serial = c.serial,
    };
    try std.zon.stringify.serialize(config_file, .{}, &writer.interface);

    try writer.interface.flush();
}

pub fn load(c: *Config, allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const path = try getConfigPath(allocator, environ);
    defer allocator.free(path);

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try c.save(allocator, io, environ);
            const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
            break :blk f;
        },
        else => return err,
    };
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);

    const stat = try file.stat(io);
    const data = try allocator.alloc(u8, stat.size + 1);
    defer allocator.free(data);
    data[stat.size] = 0;

    try reader.interface.readSliceAll(data[0..stat.size]);

    const config_file = try std.zon.parse.fromSliceAlloc(File, allocator, data[0..stat.size :0], null, .{});

    c.* = .{
        .dev = c.dev,
        .access_code = try allocator.dupe(u8, config_file.access_code),
        .ip = try allocator.dupe(u8, config_file.ip),
        .serial = try allocator.dupe(u8, config_file.serial),
        .ca_bundle = c.ca_bundle,
    };
}
