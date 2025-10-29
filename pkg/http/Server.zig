const std = @import("std");
const net = std.net;

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
port: u16,
handler: *Handler,

pub fn stop(s: *Server) !void {
    _ = s;
}

pub fn listen(s: *Server) !void {
    const addr = try std.net.Address.parseIp("0.0.0.0", s.port);
    var tcp_server = try addr.listen(.{
        .reuse_address = true,
    });

    while (true) {
        const conn = try tcp_server.accept();
        const t = try std.Thread.spawn(.{}, handleRequest, .{ s, conn });
        t.detach();
    }
}

fn handleRequest(s: *Server, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var stream_reader = conn.stream.reader(&read_buffer);
    var stream_writer = conn.stream.writer(&write_buffer);
    const reader = stream_reader.interface();
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
