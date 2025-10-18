# Webcam Module (src/webcam)

Public API:

- **connect(client: *Client, host: []const u8, port: u16, options) !*Connection**
  - `options`: `{ username: []const u8, password: []const u8 }`
- **Connection** methods:
  - `reader(self: *Connection) *std.Io.Reader`
  - `writer(self: *Connection) *std.Io.Writer`
  - `flush(self: *Connection) !void`
  - `end(self: *Connection) !void`
  - `destroy(self: *Connection) void`

Usage example (reading frame stream):

```zig
const webcam = @import("webcam");
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = webcam.Client{ .allocator = allocator };
    const conn = try client.connect("192.168.1.10", 6000, .{ .username = "u", .password = "p" });
    defer {
        conn.end() catch {}; 
        conn.destroy();
    }

    const reader = conn.reader();
    while (true) {
        const image_length = try reader.takeInt(u32, .little);
        try reader.discardAll(12); // skip three u32s
        const image = try reader.readAlloc(allocator, image_length);
        defer allocator.free(image);
        std.log.info("got image of {d} bytes", .{image.len});
    }
}
```
