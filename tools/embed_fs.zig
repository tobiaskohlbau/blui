const std = @import("std");
const builtin = @import("builtin");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var threaded = std.Io.Threaded.init(gpa);
    defer threaded.deinit();
    const threaded_io = threaded.io();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 3) fatal("wrong number of arguments", .{});

    const input_folder_path = args[1];
    const output_file_path = args[2];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    const input_dir = try std.fs.openDirAbsolute(input_folder_path, .{ .iterate = true });

    var out_buf: [8192]u8 = undefined;
    var in_buf: [8192]u8 = undefined;
    var output_writer = output_file.writer(&out_buf);

    try output_writer.interface.print(
        \\const std = @import("std");
        \\
        \\pub const fs = std.static_string_map.StaticStringMap([]u8).initComptime(.{{
        \\
    , .{});

    var directory_walker = try input_dir.walk(gpa);
    defer directory_walker.deinit();

    while (try directory_walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const normalized_path = try std.mem.replaceOwned(u8, gpa, entry.path, "\\", "/");
        defer gpa.free(normalized_path);

        try output_writer.interface.print(
            \\  .{{ "{s}", @constCast(&[_]u8{{
        , .{normalized_path});
        var f = try input_dir.openFile(entry.path, .{ .mode = .read_only });
        errdefer f.close();

        var fr = f.reader(threaded_io, &in_buf);
        while (true) {
            const data = fr.interface.takeByte() catch |err| {
                if (err == error.EndOfStream) {
                    break;
                }
                return err;
            };
            try output_writer.interface.print("0x{x}, ", .{data});
        }

        _ = try fr.interface.streamRemaining(&output_writer.interface);
        f.close();

        try output_writer.interface.writeAll("}) },\n");
    }

    try output_writer.interface.print(
        \\}});
        \\
    , .{});

    try output_writer.interface.flush();
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
