const std = @import("std");
const net = std.net;

const Options = struct {};

pub fn Server(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Handler = *const fn (context: T, request: *std.http.Server.Request) anyerror!void;

        allocator: std.mem.Allocator,
        context: T,
        port: u16,
        router: *std.StringArrayHashMapUnmanaged(Handler),
        not_found_handler: Handler = defaultNotFoundHandler,

        fn defaultNotFoundHandler(_: T, request: *std.http.Server.Request) !void {
            try request.respond("not found", .{
                .status = .not_found,
            });
        }

        pub fn stop(s: *Self) !void {
            _ = s;
        }

        pub fn listen(s: *Self) !void {
            const addr = try std.net.Address.parseIp("0.0.0.0", s.port);
            var tcp_server = try addr.listen(.{
                .reuse_address = true,
            });

            while (true) {
                const conn = try tcp_server.accept();

                var read_buffer: [8192]u8 = undefined;
                var write_buffer: [8192]u8 = undefined;
                var stream_reader = conn.stream.reader(&read_buffer);
                var stream_writer = conn.stream.writer(&write_buffer);
                const reader = stream_reader.interface();
                const writer = &stream_writer.interface;

                var http_server = std.http.Server.init(reader, writer);

                var req = try http_server.receiveHead();
                errdefer {
                    conn.stream.close();
                }

                var path = req.head.target;
                if (std.mem.findAnyPos(u8, req.head.target, 0, &.{ '?', '#' })) |pos| {
                    path = path[0..pos];
                }
                if (s.router.get(path)) |handler| {
                    try handler(s.context, &req);
                } else {
                    s.not_found_handler(s.context, &req) catch |err| {
                        std.log.debug("error in not found handler: {}", .{err});
                        try Self.defaultNotFoundHandler(s.context, &req);
                    };
                }
                conn.stream.close();
            }
        }
    };
}
