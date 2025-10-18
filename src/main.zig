const std = @import("std");
var log_level = std.log.default_level;

const webcam = @import("webcam/main.zig");
const ftp = @import("ftp");
const mqtt = @import("mqtt");
const http = @import("http");

const ui = @import("ui");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const Temperature = struct {
    bed: f64,
    nozzle: f64,
};

const PrinterStatus = struct {
    temperature: Temperature,
};

const HttpHandlers = struct {
    allocator: std.mem.Allocator,
    mqtt_conn: *mqtt.Client.Connection,
    config: *Config,
    img: []u8,

    printer_status: *PrinterStatus,

    pub fn apiVersion(self: *HttpHandlers, req: *std.http.Server.Request) !void {
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

    pub fn apiPrinterStatus(self: *HttpHandlers, req: *std.http.Server.Request) !void {
        var buffer: [8192]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&buffer);
        var writer = &fixed_writer;

        try std.json.fmt(self.printer_status, .{
            .whitespace = .indent_1,
        }).format(writer);

        try req.respond(writer.buffered(), .{
            .status = std.http.Status.ok,
        });
    }

    pub fn apiPrinterLedChamber(self: *HttpHandlers, req: *std.http.Server.Request) !void {
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

    pub fn apiUploadFile(self: *HttpHandlers, req: *std.http.Server.Request) !void {
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
                    // .bed_type = "textured_plate",
                    .cfg = 0,
                    .command = "project_file",
                    .extrude_cali_flag = 2,
                    .file = filename,
                    .flow_cali = false,
                    .layer_inspect = false,
                    .md5 = "CA460FF88C0AA982BE54EBDEB6EF6630",
                    .nozzle_offset_cali = 2,
                    .param = "Metadata/plate_1.gcode",
                    .profile_id = 0,
                    .project_id = 0,
                    .sequence_id = 50000,
                    .subtask_id = 0,
                    .subtask_name = subtask_name,
                    .task_id = 0,
                    .timelapse = false,
                    .url = try std.fmt.bufPrint(&print_buf, "ftp=//{s}", .{filename}),
                    .use_ams = false,
                    .vibration_cali = true,
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

    pub fn apiWebcam(self: *HttpHandlers, req: *std.http.Server.Request) !void {
        var write_buf: [8192]u8 = undefined;
        var body_writer = try req.respondStreaming(&write_buf, .{
            .content_length = self.img.len,
            .respond_options = .{ .extra_headers = &.{.{
                .name = "content-type",
                .value = "image/jpeg",
            }} },
        });
        var writer = &body_writer.writer;
        try writer.writeAll(self.img);
        try body_writer.flush();
    }

    pub fn notFound(self: *HttpHandlers, req: *std.http.Server.Request) !void {
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
};

const Flags = struct {
    fn Value(comptime T: type) type {
        return struct {
            required: bool,
            name: []const u8,
            value: *T,
            found: bool,
        };
    }

    const Type = union(enum) {
        string: *Value([]const u8),
        boolean: *Value(bool),
    };

    flags: std.hash_map.StringHashMapUnmanaged(Type),

    fn init() Flags {
        return .{
            .flags = .{},
        };
    }

    pub fn add(self: *Flags, allocator: std.mem.Allocator, name: []const u8, value: anytype, required: bool) !void {
        switch (@typeInfo(@TypeOf(value))) {
            .pointer => |pointer| {
                if (pointer.size != .one) {
                    @compileError("Single item pointer required!");
                }
                switch (pointer.child) {
                    []const u8 => try self.stringFlag(allocator, name, value, required),
                    bool => try self.boolFlag(allocator, name, value, required),
                    else => @compileError(std.fmt.comptimePrint("Unsupported type {s}.", .{@typeName(pointer.child)})),
                }
            },
            else => @compileError("Pointer to item required!"),
        }
    }

    fn stringFlag(self: *Flags, allocator: std.mem.Allocator, name: []const u8, value: *[]const u8, required: bool) !void {
        const flag = try allocator.create(Value([]const u8));
        flag.* = .{
            .name = name,
            .required = required,
            .value = value,
            .found = false,
        };
        try self.flags.put(allocator, name, .{ .string = flag });
    }

    fn boolFlag(self: *Flags, allocator: std.mem.Allocator, name: []const u8, value: *bool, required: bool) !void {
        const flag = try allocator.create(Value(bool));
        flag.* = .{
            .name = name,
            .required = required,
            .value = value,
            .found = false,
        };
        try self.flags.put(allocator, name, .{ .boolean = flag });
    }

    pub fn parse(self: *Flags, args: *std.process.ArgIterator) !void {
        const ParseState = enum { next, arg, bool_flag, string_flag };
        const FlagType = union(ParseState) {
            next: void,
            arg: []const u8,
            bool_flag: *Value(bool),
            string_flag: *Value([]const u8),
        };

        const start: FlagType = .{ .arg = args.next() orelse return error.InvalidArglist };
        sw: switch (start) {
            .next => {
                if (args.next()) |arg| {
                    continue :sw FlagType{ .arg = arg };
                } else {
                    break :sw;
                }
            },
            .arg => |arg| {
                if (std.ascii.startsWithIgnoreCase(arg, "-")) {
                    var n: usize = 1;
                    if (arg[1] == '-') {
                        n = 2;
                    }
                    switch (self.flags.get(arg[n..]).?) {
                        .string => |flag| {
                            continue :sw .{ .string_flag = flag };
                        },
                        .boolean => |flag| {
                            continue :sw .{ .bool_flag = flag };
                        },
                    }
                    return error.UnsupportedType;
                }
                continue :sw .next;
            },
            .bool_flag => |flag| {
                flag.*.found = true;
                if (args.next()) |arg| {
                    if (std.ascii.startsWithIgnoreCase(arg, "--") or std.ascii.startsWithIgnoreCase(arg, "-")) {
                        flag.value.* = true;
                        continue :sw FlagType{ .arg = arg };
                    } else {
                        flag.value.* = std.ascii.eqlIgnoreCase("true", arg);
                        continue :sw .next;
                    }
                } else {
                    flag.value.* = true;
                    break :sw;
                }
            },
            .string_flag => |flag| {
                flag.value.* = args.next() orelse return error.InvalidArgument;
                flag.found = true;
                continue :sw .next;
            },
        }

        var iter = self.flags.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |flag| {
                    if (flag.required and !flag.found) {
                        return error.MissingRequiredFlag;
                    }
                },
                .boolean => |flag| {
                    if (flag.required and !flag.found) {
                        return error.MissingRequiredFlag;
                    }
                },
            }
        }
    }
};

const Config = struct {
    dev: bool,
    access_code: []const u8,
    ip: []const u8,
    serial: []const u8,
    ca_bundle: ?std.crypto.Certificate.Bundle,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var config: Config = .{
        .dev = false,
        .access_code = "",
        .ip = "",
        .serial = "",
        .ca_bundle = null,
    };

    var debug = false;

    var flags = Flags.init();
    try flags.add(allocator, "dev", &config.dev, false);
    try flags.add(allocator, "debug", &debug, false);
    try flags.add(allocator, "accessCode", &config.access_code, true);
    try flags.add(allocator, "ip", &config.ip, true);
    try flags.add(allocator, "serial", &config.serial, true);
    try flags.parse(&args);

    if (debug) {
        log_level = .debug;
    } else {
        log_level = .info;
    }

    std.log.debug("{}", .{config});

    var bundle = std.crypto.Certificate.Bundle{};
    // config.ca_bundle = bundle;
    try bundle.addCertsFromFilePath(allocator, std.fs.cwd(), "certificate.pem");
    std.log.debug("Certificates in bundle: {d}\n", .{bundle.map.size});
    // var mqtt_client = mqtt.Client{ .allocator = allocator, .ca_bundle = bundle };
    var mqtt_client = mqtt.Client{ .allocator = allocator };

    var mqtt_conn = try mqtt_client.connect(config.ip, 8883, .tls, .{ .username = "bblp", .password = config.access_code, .client_id = "blUI", .keepalive_sec = 0 });

    defer {
        mqtt_conn.disconnect() catch |err| {
            std.log.err("failed to disconnect from mqtt broker: {}", .{err});
        };
    }

    if (mqtt_conn.readPacket()) |packet| switch (packet) {
        .disconnect => |d| {
            std.debug.print("server disconnected us: {s}", .{@tagName(d.reason)});
            return;
        },
        .connack => |connack| {
            if (connack.code != .accepted) {
                std.log.debug("got bad reason code: {}", .{connack.code});
                return;
            }
        },
        else => {},
    } else |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return;
    }

    const message =
        \\{"pushing": {"sequence_id": "0", "command": "pushall"}}
    ;
    var topic_buffer: [1024]u8 = undefined;
    _ = try mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{config.serial}), .message = message });

    var printer_status: PrinterStatus = .{
        .temperature = .{
            .nozzle = 0.0,
            .bed = 0.0,
        },
    };

    {
        const packet_identifier = try mqtt_conn.subscribe(.{ .topics = &.{.{ .filter = try std.fmt.bufPrint(&topic_buffer, "device/{s}/report", .{config.serial}), .qos = .at_most_once }} });
        if (mqtt_conn.readPacket()) |packet| switch (packet) {
            .disconnect => |d| {
                std.debug.print("server disconnected us: {s}", .{@tagName(d.reason)});
                return;
            },
            .suback => |s| {
                std.debug.assert(s.packet_identifier == packet_identifier);
            },
            else => {
                unreachable;
            },
        } else |err| {
            std.debug.print("Failed to read package after subscribing: {}\n", .{err});
            return;
        }
    }

    const mqtt_thread = try std.Thread.spawn(.{}, handleMqtt, .{ allocator, mqtt_conn, &printer_status });

    var http_handlers: HttpHandlers = .{ .allocator = allocator, .printer_status = &printer_status, .mqtt_conn = mqtt_conn, .config = &config, .img = &.{} };
    const http_thread = try std.Thread.spawn(.{}, handleHttp, .{
        allocator,
        &http_handlers,
    });
    const webcam_thread = try std.Thread.spawn(.{}, handleWebcam, .{ allocator, &http_handlers, &config });

    mqtt_thread.join();
    http_thread.join();
    webcam_thread.join();
}

fn handleWebcam(allocator: std.mem.Allocator, http_handlers: *HttpHandlers, config: *Config) !void {
    // var webcam_client = webcam.Client{ .allocator = allocator, .ca_bundle = config.ca_bundle };
    var webcam_client = webcam.Client{ .allocator = allocator, .ca_bundle = null };
    const webcam_conn = try webcam_client.connect(config.ip, 6000, .{
        .username = "bblp",
        .password = config.access_code,
    });

    defer {
        webcam_conn.end() catch |err| {
            std.log.debug("failed to end webcam connection: {}", .{err});
        };
        webcam_conn.destroy();
    }

    var img = std.array_list.Aligned(u8, null).empty;
    const reader = webcam_conn.reader();

    while (true) {
        const image_length = try reader.takeInt(u32, .little);
        try img.resize(allocator, image_length);
        try reader.discardAll(3 * 4);
        try reader.readSliceAll(img.items);
        http_handlers.img = try img.toOwnedSlice(allocator);
    }
}

fn handleHttp(allocator: std.mem.Allocator, http_handlers: *HttpHandlers) !void {
    const HttpServer = http.Server(*HttpHandlers);
    var router = std.StringArrayHashMapUnmanaged(HttpServer.Handler).empty;
    var server = HttpServer{ .allocator = allocator, .context = http_handlers, .port = 3080, .router = &router, .not_found_handler = HttpHandlers.notFound };
    defer {
        server.stop() catch |err| {
            std.log.debug("failed to stop http server: {}", .{err});
        };
    }

    try router.put(allocator, "/api/version", HttpHandlers.apiVersion);
    try router.put(allocator, "/api/version", HttpHandlers.apiVersion);
    try router.put(allocator, "/api/printer/status", HttpHandlers.apiPrinterStatus);
    try router.put(allocator, "/api/printer/led/chamber", HttpHandlers.apiPrinterLedChamber);
    // only handle post requests
    try router.put(allocator, "/api/files/local", HttpHandlers.apiUploadFile);
    try router.put(allocator, "/api/webcam.jpg", HttpHandlers.apiWebcam);

    // blocks
    try server.listen();
}

fn handleMqtt(allocator: std.mem.Allocator, conn: *mqtt.Client.Connection, printer_status: *PrinterStatus) !void {
    const Print = struct { command: []const u8, nozzle_temper: ?f64 = null, bed_temper: ?f64 = null, nozzle_target_temper: ?f64 = null };
    const System = struct { command: []const u8 };
    const MqttMessage = union(enum) {
        print: Print,
        system: System,
    };

    while (true) {
        const packet = try conn.readPacket();
        switch (packet) {
            .publish => |*publish| {
                std.debug.print("topic: {s}\ndata: {s}\n\n", .{ publish.topic, publish.message });
                const parsed_msg = try std.json.parseFromSlice(MqttMessage, allocator, publish.message, .{
                    .ignore_unknown_fields = true,
                });
                const msg = parsed_msg.value;
                switch (msg) {
                    .print => |print| {
                        if (std.mem.eql(u8, print.command, "push_status")) {
                            if (print.bed_temper) |t| {
                                printer_status.temperature.bed = t;
                            }
                            if (print.nozzle_temper) |t| {
                                printer_status.temperature.nozzle = t;
                            }
                        }
                    },
                    .system => |system| {
                        std.debug.print("received system message: {}", .{system});
                    },
                }
            },
            else => {
                std.debug.print("unexpected packet: {any}\n", .{packet});
            },
        }
    }
}

fn fileNameWithoutExtension(filename: []const u8) ![]const u8 {
    const first_dot_index = std.mem.find(u8, filename, ".");
    if (first_dot_index) |indx| {
        return filename[0..indx];
    }
    return error.InvalidInput;
}
