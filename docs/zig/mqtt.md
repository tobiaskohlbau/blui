# MQTT Module (pkg/mqtt)

Public API:

- **types**:
  - `QoS`: enum(u2) with `at_most_once`
  - `Message { topic: []const u8, message: []const u8 }`
  - `Topic { filter: []const u8, qos: QoS }`
  - `Subscription { topics: []const Topic }`
- **Connection** (returned by `connect`):
  - `readPacket(self: *Connection) !Packet` — reads next packet (`connack`, `publish`, `suback`, etc.)
  - `publish(self: *Connection, message: Message) !void`
  - `subscribe(self: *Connection, subscription: Subscription) !u16`
  - `flush(self: *Connection) !void`
  - `disconnect(self: *Connection) !void`
  - `destroy(self: *Connection) void`
- **connect(client: *Client, host, port, protocol, options) !*Connection**
  - `options`:
    - `username: ?[]const u8 = null`
    - `password: ?[]const u8 = null`
    - `client_id: ?[]const u8 = null`
    - `keepalive_sec: u16`

Usage example:

```zig
const mqtt = @import("mqtt");
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var client = mqtt.Client{ .allocator = allocator };
    const conn = try client.connect("broker", 8883, .tls, .{
        .username = "user",
        .password = "pass",
        .client_id = "example",
        .keepalive_sec = 60,
    });
    defer conn.destroy();

    _ = try conn.subscribe(.{ .topics = &.{.{ .filter = "sensors/#", .qos = .at_most_once }} });

    _ = try conn.publish(.{ .topic = "sensors/hello", .message = "world" });

    while (true) {
        const pkt = try conn.readPacket();
        switch (pkt) {
            .publish => |m| std.debug.print("{s}: {s}\n", .{ m.topic, m.message }),
            else => {},
        }
    }
}
```
