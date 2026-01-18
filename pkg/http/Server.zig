const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const Options = struct {};

const Server = @This();

const ConnectionList = std.array_list.Aligned(std.net.Server.Connection, null);

pub const Handler = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (h: *Handler, req: *std.http.Server.Request) anyerror!void,
    };
};

allocator: std.mem.Allocator,
io: Io,
port: u16,
handler: *Handler,
shutdown: bool = false,

pub fn stop(s: *Server) !void {
    s.shutdown = true;
}

pub fn listen(s: *Server) !void {
    const addr = try net.IpAddress.parse("0.0.0.0", s.port);
    var tcp_server = try addr.listen(s.io, .{
        .reuse_address = true,
    });

    var group: std.Io.Group = .init;
    while (!s.shutdown) {
        const stream = try tcp_server.accept(s.io);
        group.async(s.io, handleRequest, .{ s, stream });
    }
    try group.await(s.io);
}

fn handleRequest(s: *Server, stream: net.Stream) void {
    defer stream.close(s.io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(s.io, &read_buffer);
    var stream_writer = stream.writer(s.io, &write_buffer);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    var http_server = std.http.Server.init(reader, writer);

    var req = http_server.receiveHead() catch |err| {
        std.log.debug("Failed to receive http head: {}", .{err});
        return;
    };

    s.handler.vtable.handle(s.handler, &req) catch |err| {
        std.log.debug("Failed to handle request for {s}: {}", .{ req.head.target, err });
        return;
    };
}
