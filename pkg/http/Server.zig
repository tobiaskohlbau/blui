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

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;
    var thread_pool = try ConnectionList.initCapacity(s.allocator, 100 * num_threads);
    var mutex = std.Thread.Mutex{};
    var cond = std.Thread.Condition{};

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ s, &thread_pool, &mutex, &cond });
    }

    while (true) {
        const conn = try tcp_server.accept();

        mutex.lock();
        try thread_pool.append(s.allocator, conn);
        cond.signal();
        mutex.unlock();
    }
}

fn worker(s: *Server, pool: *ConnectionList, mutex: *std.Thread.Mutex, cond: *std.Thread.Condition) void {
    while (true) {
        mutex.lock();
        while (pool.items.len == 0) {
            cond.wait(mutex);
        }
        const conn = pool.pop();
        mutex.unlock();

        if (conn == null) {
            continue;
        }

        handleRequest(s, conn.?) catch |err| {
            std.log.err("Error handling request: {}", .{err});
        };
    }
}

fn handleRequest(s: *Server, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var stream_reader = conn.stream.reader(&read_buffer);
    var stream_writer = conn.stream.writer(&write_buffer);
    const reader = stream_reader.interface();
    const writer = &stream_writer.interface;

    var http_server = std.http.Server.init(reader, writer);

    // Support keep-alive for HTTP/1.1
    while (true) {
        var req = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) break; // Connection closed by client
            return err;
        };

        try s.handler.vtable.handle(s.handler, &req);

        // Drop connection if keep alive is not requested
        if (!req.head.keep_alive) {
            break;
        }
    }
}
