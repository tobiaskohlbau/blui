const std = @import("std");
const net = std.net;
const assert = std.debug.assert;

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Client = @This();

allocator: std.mem.Allocator,
tls_buffer_size: usize = std.crypto.tls.Client.min_buffer_len,
read_buffer_size: usize = 8192,
write_buffer_size: usize = 1024,
ssl_key_log: ?*std.crypto.tls.Client.SslKeyLog = null,
ca_bundle: ?std.crypto.Certificate.Bundle = null,

const Connection = struct {
    client: *Client,
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,
    port: u16,
    host_len: u8,
    tls_client: std.crypto.tls.Client,

    fn create(client: *Client, remote_host: []const u8, port: u16, stream: net.Stream) !*Connection {
        const gpa = client.allocator;
        const alloc_len = allocLen(client, remote_host.len);
        const base = try gpa.alignedAlloc(u8, .of(Connection), alloc_len);
        errdefer gpa.free(base);
        const host_buffer = base[@sizeOf(Connection)..][0..remote_host.len];
        const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
        const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
        const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..client.tls_buffer_size];
        const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..client.write_buffer_size];
        const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..client.tls_buffer_size];
        assert(base.ptr + alloc_len == socket_read_buffer.ptr + socket_read_buffer.len);
        @memcpy(host_buffer, remote_host);
        const connection: *Connection = @ptrCast(base);
        connection.* = .{
            .client = client,
            .stream_writer = stream.writer(tls_write_buffer),
            .stream_reader = stream.reader(socket_read_buffer),
            .port = port,
            .host_len = @intCast(remote_host.len),
            .tls_client = std.crypto.tls.Client.init(
                connection.stream_reader.interface(),
                &connection.stream_writer.interface,
                .{
                    .host = .no_verification,
                    .ca = if (client.ca_bundle) |bundle| .{ .bundle = bundle } else .no_verification,
                    .ssl_key_log = client.ssl_key_log,
                    .read_buffer = tls_read_buffer,
                    .write_buffer = socket_write_buffer,
                },
            ) catch return error.TlsInitializationFailed,
        };
        return connection;
    }

    pub fn writer(c: *Connection) *Writer {
        return &c.tls_client.writer;
    }

    pub fn reader(c: *Connection) *Reader {
        return &c.tls_client.reader;
    }

    pub fn flush(c: *Connection) Writer.Error!void {
        try c.tls_client.writer.flush();
        try c.stream_writer.interface.flush();
    }

    pub fn destroy(c: *Connection) void {
        const gpa = c.client.allocator;
        const base: [*]align(@alignOf(Connection)) u8 = @ptrCast(c);
        gpa.free(base[0..allocLen(c.client, c.host_len)]);
    }

    fn allocLen(client: *Client, host_len: usize) usize {
        const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
        return @sizeOf(Connection) + host_len + tls_read_buffer_len + client.tls_buffer_size +
            client.write_buffer_size + client.tls_buffer_size;
    }

    fn host(c: *Connection) []u8 {
        const base: [*]u8 = @ptrCast(c);
        return base[@sizeOf(Connection)..][0..c.host_len];
    }

    pub fn end(c: *Connection) Writer.Error!void {
        try c.tls_client.end();
        try c.stream_writer.interface.flush();
    }

    fn connect(c: *Connection, username: []const u8, password: []const u8) !void {
        const w = c.writer();

        try w.writeInt(u32, 0x40, .little);
        try w.writeInt(u32, 0x3000, .little);
        try w.writeInt(u32, 0x0, .little);
        try w.writeInt(u32, 0x0, .little);
        try w.writeSliceEndian(u8, username, .little);
        for (0..(32 - username.len)) |_| {
            try w.writeInt(u8, 0x0, .little);
        }
        try w.writeSliceEndian(u8, password, .little);
        for (0..(32 - password.len)) |_| {
            try w.writeInt(u8, 0x0, .little);
        }

        try c.flush();
    }
};

const Options = struct {
    username: []const u8,
    password: []const u8,
};

pub fn connect(client: *Client, host: []const u8, port: u16, options: Options) !*Connection {
    const stream = try std.net.tcpConnectToHost(client.allocator, host, port);
    const conn = try Connection.create(client, host, port, stream);
    try conn.connect(options.username, options.password);
    return conn;
}
