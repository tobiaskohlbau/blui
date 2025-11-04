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

const Packet = union(enum) {
    const ConnectReturnCode = enum(u8) {
        accepted = 0,
        unacceptable_protoc_version = 1,
        identifier_rejected = 2,
        server_unavailable = 3,
        bad_username_password = 4,
        unauthorized = 5,
    };

    const Reasons = enum(u8) {
        success,
        normal,
    };

    const Disconnect = struct {
        reason: Reasons,
    };

    const ConnAck = struct {
        code: ConnectReturnCode,
    };

    const SubAck = struct {
        status: u8,
        packet_identifier: u16,
    };

    unknown,
    disconnect: Disconnect,
    connack: ConnAck,
    suback: SubAck,
    publish: Message,
};

const ControlPacketTypes = enum(u4) { CONNECT = 1, CONNACK = 2, PUBLISH = 3, PUBACK = 4, PUBREC = 5, PUBREL = 6, PUBCOMP = 7, SUBSCRIBE = 8, SUBACK = 9, UNSUBSCRIBE = 10, UNSUBACK = 11, PINGREQ = 12, PINPINGRESP = 13, DISCONNECT = 14, _ };

pub const QoS = enum(u2) {
    at_most_once = 0,
};

pub const Message = struct {
    topic: []const u8,
    message: []const u8,
};

pub const Topic = struct {
    filter: []const u8,
    qos: QoS,
};

pub const Subscription = struct {
    topics: []const Topic,
};

const Protocol = enum {
    plain,
    tls,
};

pub const Connection = struct {
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
            var random_buffer: [176]u8 = undefined;
            std.crypto.random.bytes(&random_buffer);
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
    };

    fn getStream(c: *Connection) net.Stream {
        return c.stream_reader.getStream();
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

    pub fn readPacket(c: *Connection) !Packet {
        const r = c.reader();
        const raw_byte = try r.takeByte();
        const packet_type: ControlPacketTypes = @enumFromInt(@as(u4, @intCast(raw_byte >> 4)));

        const length = try readVarInt(r);

        std.log.debug("Packet type: {} and length {d}", .{ packet_type, length });

        return switch (packet_type) {
            .CONNACK => blk: {
                // todo read this
                _ = try r.discardShort(1);
                break :blk .{
                    .connack = .{
                        .code = @enumFromInt(try r.takeInt(u8, .big)),
                    },
                };
            },
            .PUBLISH => blk: {
                const topic_size = try r.takeInt(u16, .big);
                const topic = try r.readAlloc(c.client.allocator, topic_size);

                const Flags = packed struct {
                    dup: u1,
                    qos: QoS,
                    retain: u1,
                };

                // substract 2 bytes for the topic size fields
                var message_size: u32 = length - topic_size - 2;
                const flags = @as(Flags, @bitCast(@as(u4, @truncate(raw_byte))));

                if (flags.qos != .at_most_once) {
                    _ = try r.takeInt(u16, .big);
                    message_size -= 2;
                }

                const message = try r.readAlloc(c.client.allocator, message_size);

                break :blk .{
                    .publish = .{
                        .topic = topic,
                        .message = message,
                    },
                };
            },
            .SUBACK => blk: {
                break :blk .{
                    .suback = .{
                        .packet_identifier = try r.takeInt(u16, .big),
                        .status = try r.takeInt(u8, .big),
                    },
                };
            },
            else => error.UnsupportedPacket,
        };
    }

    pub fn publish(c: *Connection, message: Message) !void {
        var content_buffer: [8192]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&content_buffer);
        const cw = &fixed_writer;

        try writeString(cw, message.topic);
        try cw.writeAll(message.message);

        std.log.debug("Publishing to topic {s}\n{s}", .{ message.topic, message.message });

        const packet_type: u8 = 3;
        const packet_flags: u8 = 0;
        const w = c.writer();
        try w.writeByte((packet_type << 4) | packet_flags);

        const content = cw.buffered();
        try writeVarInt(w, @intCast(content.len));
        try w.writeAll(content);
        try c.flush();
    }

    pub fn subscribe(c: *Connection, subscription: Subscription) !u16 {
        for (subscription.topics) |topic| {
            std.log.debug("Subscribing to topic {s}", .{topic.filter});
        }

        var content_buffer: [8192]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&content_buffer);
        const cw = &fixed_writer;

        const id = 10;
        try cw.writeInt(u16, id, .big);
        for (subscription.topics) |topic| {
            try writeString(cw, topic.filter);
            try cw.writeByte(@intFromEnum(topic.qos));
        }

        const packet_type: u8 = 8;
        const packet_flags: u8 = 1 << 1;
        const w = c.writer();
        try w.writeByte((packet_type << 4) | packet_flags);

        const content = cw.buffered();
        try writeVarInt(w, @intCast(content.len));
        try w.writeAll(content);
        try c.flush();

        return id;
    }

    pub fn flush(c: *Connection) Writer.Error!void {
        if (c.protocol == .tls) {
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.writer.flush();
        }
        try c.stream_writer.interface.flush();
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

    fn reader(c: *Connection) *Reader {
        return switch (c.protocol) {
            .tls => {
                const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
                return &tls.client.reader;
            },
            .plain => &c.stream_reader.interface,
        };
    }

    fn readVarInt(r: *std.Io.Reader) !u32 {
        var multiplier: u32 = 1;
        var value: u32 = 0;
        var encodedByte: u8 = 0;
        while (true) {
            encodedByte = try r.takeByte();
            value += (encodedByte & 0x7f) * multiplier;
            multiplier *= 0x80;

            if (multiplier > 0x200000) {
                return error.MalformedRemainingLength;
            }

            if (encodedByte & 0x80 == 0) {
                break;
            }
        }

        return value;
    }

    fn writeVarInt(w: *std.Io.Writer, size: u32) !void {
        var data = size;
        while (true) {
            var byte = data % 128;
            data = data / 128;
            if (data > 0) {
                byte = byte | 0x80;
            }
            try w.writeByte(@intCast(byte));
            if (data == 0) {
                break;
            }
        }
    }

    fn writeString(w: *std.Io.Writer, data: []const u8) !void {
        try w.writeInt(u16, @intCast(data.len), .big);
        try w.writeSliceEndian(u8, data, .big);
    }

    fn connect(c: *Connection, client_id: []const u8, username: ?[]const u8, password: ?[]const u8) !void {
        var content_buffer: [8192]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&content_buffer);
        const cw = &fixed_writer;

        try writeString(cw, "MQTT");
        try cw.writeByte(0x04);

        const connect_flags = packed struct {
            _reserved: bool = false,
            clean_start: bool = true,
            will: bool = false,
            will_qos: QoS = .at_most_once,
            will_retain: bool = false,
            username: bool,
            password: bool,
        }{
            .username = username != null,
            .password = password != null,
        };

        try cw.writeByte(@bitCast(connect_flags));
        try cw.writeInt(u16, 300, .big);

        try writeString(cw, client_id);
        if (username) |u| {
            try writeString(cw, u);
        }
        if (password) |p| {
            try writeString(cw, p);
        }

        const w = c.writer();
        const packet_type: u8 = 1;
        const packet_flags: u8 = 0;
        try w.writeByte((packet_type << 4) | packet_flags);
        const content = cw.buffered();
        try writeVarInt(w, @intCast(content.len));
        try w.writeAll(content);
        try c.flush();
    }

    pub fn disconnect(c: *Connection) !void {
        const packet_type: u8 = 14;
        const packet_flags: u8 = 0;
        const w = c.writer();
        try w.writeByte((packet_type << 4) | packet_flags);
        try w.writeByte(0x0);
        try w.flush();

        if (c.protocol == .tls) {
            const tls: *Tls = @alignCast(@fieldParentPtr("connection", c));
            try tls.client.end();
        }
        try c.stream_writer.interface.flush();
    }
};

const Options = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    keepalive_sec: u16,
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

    try conn.connect("blUI", options.username, options.password);
    return conn;
}
