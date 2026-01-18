const std = @import("std");
const net = std.Io.net;
const assert = std.debug.assert;

const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.Reader;
const Client = @This();

allocator: std.mem.Allocator,
io: Io,
tls_buffer_size: usize = std.crypto.tls.Client.min_buffer_len,
read_buffer_size: usize = 8192,
write_buffer_size: usize = 1024,
ssl_key_log: ?*std.crypto.tls.Client.SslKeyLog = null,
ca_bundle: ?std.crypto.Certificate.Bundle = null,
now: ?Io.Timestamp = null,

const Options = struct {
    username: []const u8,
    password: []const u8,
};

const Protocol = enum {
    plain,
    tls,
};

const Connection = struct {
    client: *Client,
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,
    port: u16,
    host_len: u8,
    protocol: Protocol,

    const Plain = struct {
        connection: Connection,
        fn create(client: *Client, remote_host: []const u8, port: u16, stream: net.Stream) !*Plain {
            const gpa = client.allocator;
            const alloc_len = allocLen(client, remote_host.len);
            const base = try gpa.alignedAlloc(u8, .of(Plain), alloc_len);
            errdefer gpa.free(base);
            const host_buffer = base[@sizeOf(Plain)..][0..remote_host.len];
            const socket_read_buffer = host_buffer.ptr[host_buffer.len..][0..client.read_buffer_size];
            const socket_write_buffer = socket_read_buffer.ptr[socket_read_buffer.len..][0..client.write_buffer_size];
            assert(base.ptr + alloc_len == socket_write_buffer.ptr + socket_write_buffer.len);
            @memcpy(host_buffer, remote_host);
            const plain: *Plain = @ptrCast(base);
            plain.* = .{
                .connection = .{
                    .client = client,
                    .stream_writer = stream.writer(client.io, socket_write_buffer),
                    .stream_reader = stream.reader(client.io, socket_read_buffer),
                    .port = port,
                    .host_len = @intCast(remote_host.len),
                    .protocol = .plain,
                },
            };
            return plain;
        }

        fn destroy(plain: *Plain) void {
            const c = &plain.connection;
            const gpa = c.client.allocator;
            const base: [*]align(@alignOf(Plain)) u8 = @ptrCast(plain);
            gpa.free(base[0..allocLen(c.client, c.host_len)]);
        }

        fn allocLen(client: *Client, host_len: usize) usize {
            return @sizeOf(Plain) + host_len + client.read_buffer_size + client.write_buffer_size;
        }

        fn host(plain: *Plain) []u8 {
            const base: [*]u8 = @ptrCast(plain);
            return base[@sizeOf(Plain)..][0..plain.connection.host_len];
        }
    };

    const Tls = struct {
        client: std.crypto.tls.Client,
        connection: Connection,

        fn create(client: *Client, remote_host: []const u8, port: u16, stream: net.Stream) !*Tls {
            const gpa = client.allocator;
            const alloc_len = allocLen(client, remote_host.len);
            const base = try gpa.alignedAlloc(u8, .of(Tls), alloc_len);
            errdefer gpa.free(base);
            const host_buffer = base[@sizeOf(Tls)..][0..remote_host.len];
            const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
            const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
            const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..client.tls_buffer_size];
            const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..client.write_buffer_size];
            const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..client.tls_buffer_size];
            assert(base.ptr + alloc_len == socket_read_buffer.ptr + socket_read_buffer.len);
            @memcpy(host_buffer, remote_host);
            const tls: *Tls = @ptrCast(base);
            var random_buffer: [240]u8 = undefined;
            std.Io.random(client.io, &random_buffer);
            const now = client.now orelse try Io.Clock.real.now(client.io);
            tls.* = .{
                .connection = .{
                    .client = client,
                    .stream_writer = stream.writer(client.io, tls_write_buffer),
                    .stream_reader = stream.reader(client.io, socket_read_buffer),
                    .port = port,
                    .host_len = @intCast(remote_host.len),
                    .protocol = .tls,
                },
                .client = std.crypto.tls.Client.init(
                    &tls.connection.stream_reader.interface,
                    &tls.connection.stream_writer.interface,
                    .{
                        .host = .no_verification,
                        .ca = if (client.ca_bundle) |bundle| .{ .bundle = bundle } else .no_verification,
                        .ssl_key_log = client.ssl_key_log,
                        .read_buffer = tls_read_buffer,
                        .write_buffer = socket_write_buffer,
                        .entropy = &random_buffer,
                        .realtime_now_seconds = now.toSeconds(),
                    },
                ) catch return error.TlsInitializationFailed,
            };
            return tls;
        }

        fn destroy(tls: *Tls) void {
            const c = &tls.connection;
            const gpa = c.client.allocator;
            const base: [*]align(@alignOf(Tls)) u8 = @ptrCast(tls);
            gpa.free(base[0..allocLen(c.client, c.host_len)]);
        }

        fn allocLen(client: *Client, host_len: usize) usize {
            const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
            return @sizeOf(Tls) + host_len + tls_read_buffer_len + client.tls_buffer_size +
                client.write_buffer_size + client.tls_buffer_size;
        }

        fn host(tls: *Tls) []u8 {
            const base: [*]u8 = @ptrCast(tls);
            return base[@sizeOf(Tls)..][0..tls.connection.host_len];
        }
    };

    pub fn uploadFile(c: *Connection, filename: []const u8, data: []const u8) !void {
        const w = c.writer();
        const r = c.reader();

        try w.writeSliceEndian(u8, "PASV\r\n", .big);
        try c.flush();

        var line = try r.takeDelimiterExclusive('\n');
        std.log.debug("FTP-Data: {s}", .{line});

        const open_index = std.mem.indexOf(u8, line, "(") orelse return error.ParseFailed;
        const close_index = std.mem.indexOf(u8, line, ")") orelse return error.ParseFailed;
        const inside = line[open_index + 1 .. close_index];
        var parts = std.mem.splitScalar(u8, inside, ',');
        var comps: [2]u8 = undefined;
        var i: usize = 0;
        while (parts.next()) |part| : (i += 1) {
            if (i < 4) continue;
            if (i >= 6) break;
            // trim spaces
            const t = std.mem.trim(u8, part, " ");
            const num = try std.fmt.parseInt(u8, t, 10);
            comps[i - 4] = num;
        }
        if (i != 6) return error.ParseFailed;
        const p1 = comps[0];
        const p2 = comps[1];
        const port_val: u16 = (@as(u16, p1) << 8) + @as(u16, p2);

        std.log.debug("data host: {s}", .{c.host()});

        const data_conn = try c.client.connectData(c.host(), port_val, .tls);

        try w.print("STOR {s}\r\n", .{filename});
        try c.flush();
        line = try r.takeDelimiterExclusive('\n');
        std.log.debug("FTP-Data: {s}", .{line});

        try data_conn.writer().writeAll(data);
        try data_conn.end();
        data_conn.destroy(c.client.io);

        line = try r.takeDelimiterExclusive('\n');
        std.log.debug("FTP-Data: {s}", .{line});
    }

    fn getStream(c: *Connection) Io.net.Stream {
        return c.stream_reader.stream;
    }

    pub fn host(c: *Connection) []u8 {
        return switch (c.protocol) {
            .tls => {
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return tls.host();
            },
            .plain => {
                const plain: *Plain = @alignCast(@fieldParentPtr("connection", c));
                return plain.host();
            },
        };
    }

    pub fn destroy(c: *Connection, io: Io) void {
        c.getStream().close(io);
        switch (c.protocol) {
            .tls => {
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                tls.destroy();
            },
            .plain => {
                const plain: *Plain = @alignCast(@fieldParentPtr("connection", c));
                plain.destroy();
            },
        }
    }

    fn reader(c: *Connection) *Reader {
        return switch (c.protocol) {
            .tls => {
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return &tls.client.reader;
            },
            .plain => &c.stream_reader.interface,
        };
    }

    fn writer(c: *Connection) *Writer {
        return switch (c.protocol) {
            .tls => {
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return &tls.client.writer;
            },
            .plain => &c.stream_writer.interface,
        };
    }

    pub fn flush(c: *Connection) Writer.Error!void {
        if (c.protocol == .tls) {
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.writer.flush();
        }
        try c.stream_writer.interface.flush();
    }

    pub fn end(c: *Connection) Writer.Error!void {
        if (c.protocol == .tls) {
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.end();
        }
        try c.stream_writer.interface.flush();
    }

    fn connect(c: *Connection, username: []const u8, password: []const u8) !void {
        const r = c.reader();
        const w = c.writer();

        var ftp_data = try r.takeDelimiter('\n');
        std.log.debug("FTP-Data: {?s}", .{ftp_data});

        try w.print("USER {s}\r\n", .{username});
        try c.flush();
        ftp_data = try r.takeDelimiter('\n');
        std.log.debug("FTP-Data: {?s}", .{ftp_data});

        try w.print("PASS {s}\r\n", .{password});
        try c.flush();
        ftp_data = try r.takeDelimiter('\n');
        std.log.debug("FTP-Data: {?s}", .{ftp_data});

        try w.writeAll("TYPE I\r\n");
        try c.flush();
        ftp_data = try r.takeDelimiter('\n');
        std.log.debug("FTP-Data: {?s}", .{ftp_data});
    }
};

pub fn connect(client: *Client, host: []const u8, port: u16, protocol: Protocol, options: Options) !*Connection {
    const host_name = try net.HostName.init(host);
    const stream = try host_name.connect(client.io, port, .{ .mode = .stream, .protocol = .tcp });
    const conn = switch (protocol) {
        .tls => blk: {
            const conn = try Connection.Tls.create(client, host, port, stream);
            break :blk &conn.connection;
        },
        .plain => blk: {
            const conn = try Connection.Plain.create(client, host, port, stream);
            break :blk &conn.connection;
        },
    };

    try conn.connect(options.username, options.password);
    return conn;
}

pub fn connectData(client: *Client, host: []const u8, port: u16, protocol: Protocol) !*Connection {
    const host_name = try net.HostName.init(host);
    const stream = try host_name.connect(client.io, port, .{ .mode = .stream, .protocol = .tcp });
    switch (protocol) {
        .tls => {
            const conn = try Connection.Tls.create(client, host, port, stream);
            return &conn.connection;
        },
        .plain => {
            const conn = try Connection.Plain.create(client, host, port, stream);
            return &conn.connection;
        },
    }
}
