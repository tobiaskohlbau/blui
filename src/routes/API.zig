const std = @import("std");

const ftp = @import("ftp");
const http = @import("http");
const mqtt = @import("mqtt");

const printer = @import("../printer.zig");

const Config = @import("../Config.zig");
const Self = @This();

allocator: std.mem.Allocator,
mqtt_conn: *mqtt.Client.Connection,
config: *Config,
printer_status: *printer.Status,

pub fn version(self: *Self, req: *std.http.Server.Request) !void {
    _ = self;

    var buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    var writer = &fixed_writer;

    try std.json.fmt(.{
        .api = "0.1",
        .server = "1.3.10",
        .text = "OctoPrint 1.3.10",
    }, .{
        .whitespace = .indent_1,
    }).format(writer);

    try req.respond(writer.buffered(), .{
        .status = std.http.Status.ok,
    });
}

pub fn printerStatus(self: *Self, req: *std.http.Server.Request) !void {
    var buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    var writer = &fixed_writer;

    const response = struct {
        temperature: printer.Status.Temperature,
        fan: printer.Status.Fan,
        print_percent: f64,
        print_remaining_time: f64,
    }{
        .temperature = self.printer_status.temperature,
        .fan = self.printer_status.fan,
        .print_percent = self.printer_status.print_percent,
        .print_remaining_time = self.printer_status.print_remaining_time,
    };

    try std.json.fmt(response, .{
        .whitespace = .indent_1,
    }).format(writer);

    try req.respond(writer.buffered(), .{
        .status = std.http.Status.ok,
    });
}

pub fn printerPause(self: *Self, req: *std.http.Server.Request) !void {
    const message = .{
        .print = .{
            .sequence_id = "0",
            .command = "pause",
        },
    };

    var json_buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&json_buffer);
    try std.json.fmt(message, .{}).format(&fixed_writer);

    var topic_buffer: [1024]u8 = undefined;
    _ = try self.mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{self.config.serial}), .message = fixed_writer.buffered() });

    try req.respond("ok", .{ .status = std.http.Status.ok });
}

pub fn printerResume(self: *Self, req: *std.http.Server.Request) !void {
    const message = .{
        .print = .{
            .sequence_id = "0",
            .command = "resume",
        },
    };

    var json_buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&json_buffer);
    try std.json.fmt(message, .{}).format(&fixed_writer);

    var topic_buffer: [1024]u8 = undefined;
    _ = try self.mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{self.config.serial}), .message = fixed_writer.buffered() });

    try req.respond("ok", .{ .status = std.http.Status.ok });
}

pub fn printerStop(self: *Self, req: *std.http.Server.Request) !void {
    const message = .{
        .print = .{
            .sequence_id = "0",
            .command = "stop",
        },
    };

    var json_buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&json_buffer);
    try std.json.fmt(message, .{}).format(&fixed_writer);

    var topic_buffer: [1024]u8 = undefined;
    _ = try self.mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{self.config.serial}), .message = fixed_writer.buffered() });

    try req.respond("ok", .{ .status = std.http.Status.ok });
}

pub fn printerLedChamber(self: *Self, req: *std.http.Server.Request) !void {
    const pos = std.mem.findScalarPos(u8, req.head.target, 0, '?');
    if (pos == null) {
        try req.respond("bad request", .{ .status = std.http.Status.bad_request });
        return;
    }
    var queries = std.mem.splitScalar(u8, req.head.target[pos.? + 1 .. req.head.target.len], '&');
    const request_state: []const u8 = blk: {
        while (queries.next()) |query| {
            var items = std.mem.splitScalar(u8, query, '=');
            if (items.next()) |key| {
                std.log.debug("query key: {s}", .{key});
                if (std.mem.eql(u8, key, "state")) {
                    break :blk items.next().?;
                }
            }
        }
        break :blk "";
    };

    const state = if (std.mem.eql(u8, request_state, "on")) "on" else "off";
    const message = .{ .system = .{ .sequence_id = "0", .command = "ledctrl", .led_node = "chamber_light", .led_mode = state, .led_on_time = 500, .led_off_time = 500, .loop_times = 0, .interval_time = 0 } };

    var json_buffer: [8192]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&json_buffer);
    try std.json.fmt(message, .{}).format(&fixed_writer);

    var topic_buffer: [1024]u8 = undefined;
    _ = try self.mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{self.config.serial}), .message = fixed_writer.buffered() });

    try req.respond("ok", .{ .status = std.http.Status.ok });
}

pub fn uploadFile(self: *Self, req: *std.http.Server.Request) !void {
    std.log.debug("Got request for file upload", .{});

    if (req.head.method != .POST) {
        try req.respond("bad request", .{ .status = .bad_request });
        return;
    }
    const content_type = req.head.content_type orelse {
        try req.respond("bad request", .{ .status = .bad_request });
        return;
    };
    if (!std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        try req.respond("bad request", .{ .status = .bad_request });
        return;
    }

    const boundary_pos = std.mem.find(u8, content_type, "boundary=") orelse {
        try req.respond("bad request", .{ .status = .bad_request });
        return;
    };

    var boundary_buf: [128]u8 = undefined;
    const boundary_len = content_type.len - boundary_pos - 9;
    @memcpy(boundary_buf[0..boundary_len], content_type[boundary_pos + 9 ..]);
    const boundary = boundary_buf[0..boundary_len];

    var buf: [8192]u8 = undefined;
    const body_buf = try self.allocator.alloc(u8, 64 * 1024 * 1024);
    defer self.allocator.free(body_buf);

    var reader = req.readerExpectNone(&buf);
    const n = try reader.readSliceShort(body_buf);

    const body_data = body_buf[0..n];

    var form = try http.Form.parse(self.allocator, body_data, boundary);
    defer form.deinit(self.allocator);

    const form_file = form.getPart("file") orelse return error.MissingFile;
    const content_disposition_header = form_file.headers.get("Content-Disposition") orelse return error.MissingContentDisposition;

    const search_for = "filename=\"";
    const name_pos = std.mem.find(u8, content_disposition_header.value, search_for) orelse return error.MissingFilename;
    const name_pos_end = std.mem.findScalarPos(u8, content_disposition_header.value, name_pos + search_for.len, '"') orelse return error.BadFilename;
    const filename = content_disposition_header.value[name_pos + search_for.len .. name_pos_end];

    const should_print = std.ascii.eqlIgnoreCase(form.getPart("print").?.data.?, "true");

    var ftp_client = ftp.Client{ .allocator = self.allocator, .ca_bundle = self.config.ca_bundle };
    const ftp_conn = try ftp_client.connect(self.config.ip, 990, .tls, .{
        .username = "bblp",
        .password = self.config.access_code,
    });

    defer {
        ftp_conn.end() catch |err| {
            std.log.debug("failed to disconnect from ftp: {}", .{err});
        };
        ftp_conn.destroy();
    }

    try ftp_conn.uploadFile(filename, form_file.data.?);

    if (should_print) {
        var print_buf: [8192]u8 = undefined;
        const subtask_name = try fileNameWithoutExtension(filename);
        const message = .{
            .print = .{
                .ams_mapping = &.{-1},
                .ams_mapping2 = &.{.{
                    .ams_id = 255,
                    .slot_id = 0,
                }},
                .auto_bed_leveling = 1,
                .bed_leveling = true,
                .bed_type = "auto",
                .cfg = "0",
                .command = "project_file",
                .extrude_cali_flag = 2,
                .file = filename,
                .flow_cali = false,
                .layer_inspect = false,
                .md5 = "CA460FF88C0AA982BE54EBDEB6EF6630",
                .nozzle_offset_cali = 2,
                .param = "Metadata/plate_1.gcode",
                .profile_id = "0",
                .project_id = "0",
                .sequence_id = "50000",
                .subtask_id = "0",
                .subtask_name = subtask_name,
                .task_id = "0",
                .timelapse = false,
                .url = try std.fmt.bufPrint(&print_buf, "ftp://{s}", .{filename}),
                .use_ams = false,
                .vibration_cali = false,
            },
        };

        var json_buffer: [8192]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&json_buffer);
        try std.json.fmt(message, .{}).format(&fixed_writer);

        var topic_buffer: [1024]u8 = undefined;
        _ = try self.mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{self.config.serial}), .message = fixed_writer.buffered() });
    }

    try req.respond("ok", .{ .status = .ok });
}

pub fn webcam(self: *Self, req: *std.http.Server.Request) !void {
    var write_buf: [8192]u8 = undefined;
    var body_writer = try req.respondStreaming(&write_buf, .{
        .content_length = self.printer_status.image.len,
        .respond_options = .{ .extra_headers = &.{.{
            .name = "content-type",
            .value = "image/jpeg",
        }} },
    });
    var writer = &body_writer.writer;
    try writer.writeAll(self.printer_status.image);
    try body_writer.flush();
}

fn fileNameWithoutExtension(filename: []const u8) ![]const u8 {
    const first_dot_index = std.mem.find(u8, filename, ".");
    if (first_dot_index) |indx| {
        return filename[0..indx];
    }
    return error.InvalidInput;
}
