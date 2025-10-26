const std = @import("std");
const ui = @import("ui");

allocator: std.mem.Allocator,

const Self = @This();

pub fn notFound(self: *Self, req: *std.http.Server.Request) !void {
    var headers: [1]std.http.Header = undefined;
    headers[0].name = "content-type";
    headers[0].value = "text/html";

    const path = req.head.target;

    if (path.len > 3 and std.mem.eql(u8, path[path.len - 3 ..], ".js")) {
        headers[0].value = "text/javascript";
    } else if (path.len > 4 and std.mem.eql(u8, path[path.len - 4 ..], ".css")) {
        headers[0].value = "text/css";
    }

    const response_options: std.http.Server.Request.RespondOptions = .{
        .extra_headers = &headers,
    };

    const read_buf = try self.allocator.alloc(u8, 8192);
    var write_buf: [8192 * 1024]u8 = undefined;
    defer self.allocator.free(read_buf);

    if (ui.fs.get(req.head.target[1..])) |data| {
        var body_writer = try req.respondStreaming(&write_buf, .{
            .content_length = data.len,
            .respond_options = response_options,
        });
        try body_writer.flush();
        var writer = &body_writer.writer;
        try writer.writeAll(data);
        try writer.flush();
        try body_writer.flush();
    } else if (ui.fs.get("200.html")) |data| {
        var body_writer = try req.respondStreaming(&write_buf, .{
            .content_length = data.len,
            .respond_options = response_options,
        });
        try body_writer.flush();
        var writer = &body_writer.writer;
        try writer.writeAll(data);
        try writer.flush();
        try body_writer.flush();
    } else {
        return error.BadRequest;
    }
}
