const std = @import("std");

const Server = @import("Server.zig");

pub fn Router(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const HandleFn = *const fn (ctx: *T, request: *std.http.Server.Request) anyerror!void;

        context: *T,
        routes: std.StringArrayHashMapUnmanaged(HandleFn) = .empty,
        sub_routers: std.StringArrayHashMapUnmanaged(*Server.Handler) = .empty,
        not_found_handle_fn: ?HandleFn = defaultNotFoundHandler,

        serverHandler: Server.Handler = .{
            .vtable = &.{
                .handle = Self.handle,
            },
        },

        pub fn handle(h: *Server.Handler, req: *std.http.Server.Request) !void {
            const self: *Self = @alignCast(@fieldParentPtr("serverHandler", h));

            var path = req.head.target;
            if (std.mem.findAnyPos(u8, req.head.target, 0, &.{ '?', '#' })) |pos| {
                path = path[0..pos];
            }

            var it = self.sub_routers.iterator();
            while (it.next()) |sub_router| {
                if (std.mem.startsWith(u8, path, sub_router.key_ptr.*)) {
                    var handler = sub_router.value_ptr.*;
                    var prefix = sub_router.key_ptr.*;
                    req.head.target = req.head.target[prefix.len..];
                    try handler.vtable.handle(handler, req);
                    return;
                }
            }

            if (self.routes.get(path)) |handler| {
                try handler(self.context, req);
                return;
            } else {
                if (self.not_found_handle_fn) |handleFn| {
                    handleFn(self.context, req) catch |err| {
                        std.log.debug("error in not found handler: {}", .{err});
                    };
                }
            }
        }

        fn defaultNotFoundHandler(_: *T, request: *std.http.Server.Request) !void {
            try request.respond("not found", .{
                .status = .not_found,
            });
        }

        pub fn register(self: *Self, allocator: std.mem.Allocator, path: []const u8, route: HandleFn) !void {
            try self.routes.put(allocator, path, route);
        }

        pub fn registerSubRouter(self: *Self, allocator: std.mem.Allocator, prefix: []const u8, handler: *Server.Handler) !void {
            try self.sub_routers.put(allocator, prefix, handler);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.routes.deinit(allocator);
            self.sub_routers.deinit(allocator);
        }
    };
}
