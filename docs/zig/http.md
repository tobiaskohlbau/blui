# HTTP Module (pkg/http)

Public API:

- **Server(T: type) -> type**: Generic HTTP server factory. Produces a server type with:
  - `Handler`: `*const fn (context: T, request: *std.http.Server.Request) anyerror!void`
  - `listen(self: *Self) !void`: Starts accepting connections and dispatching by exact path match using `router`.
  - `stop(self: *Self) !void`: Placeholder for graceful shutdown.
  - Fields: `allocator`, `context`, `port`, `router: *std.StringArrayHashMapUnmanaged(Handler)`, `not_found_handler: Handler`.

- **Form**: Multipart/form-data utilities
  - `parse(allocator, data: []const u8, boundary: []const u8) !Form`
  - `getPart(form: *Form, name: []const u8) ?Part`
  - `partIterator(form: *Form) PartIterator`
  - `deinit(form: *Form, allocator) void`

Usage example (server):

```zig
const http = @import("http");
const std = @import("std");

const Handlers = struct {
    pub fn hello(_: *Handlers, req: *std.http.Server.Request) !void {
        try req.respond("hello", .{ .status = .ok });
    }
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Server = http.Server(*Handlers);
    var router = std.StringArrayHashMapUnmanaged(Server.Handler).empty;

    var handlers: Handlers = .{};
    var server = Server{ .allocator = gpa, .context = &handlers, .port = 3080, .router = &router, .not_found_handler = Handlers.hello };

    try router.put(gpa, "/hello", Handlers.hello);
    try server.listen();
}
```

Usage example (multipart parse):

```zig
const http = @import("http");
const std = @import("std");

fn handleUpload(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) !void {
    var form = try http.Form.parse(allocator, body, boundary);
    defer form.deinit(allocator);

    if (form.getPart("file")) |file| {
        if (file.data) |bytes| {
            std.log.info("received {d} bytes", .{bytes.len});
        }
    }
}
```
