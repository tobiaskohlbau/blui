# FTP Module (pkg/ftp)

Public API:

- **connect(client: *Client, host, port, protocol, options) !*Connection**
  - `protocol`: `.plain | .tls`
  - `options`: `{ username: []const u8, password: []const u8 }`
- **connectData(client: *Client, host, port, protocol) !*Connection** — auxiliary for data channel
- **Connection** methods:
  - `uploadFile(self: *Connection, filename: []const u8, data: []const u8) !void`
  - `host(self: *Connection) []u8`
  - `flush(self: *Connection) !void`
  - `end(self: *Connection) !void`
  - `destroy(self: *Connection) void`

Usage example:

```zig
const ftp = @import("ftp");
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var client = ftp.Client{ .allocator = allocator };
    const conn = try client.connect("example.com", 21, .plain, .{ .username = "u", .password = "p" });
    defer {
        conn.end() catch {}; // ignore for example
        conn.destroy();
    }

    try conn.uploadFile("hello.txt", "Hello, FTP!\n");
}
```
