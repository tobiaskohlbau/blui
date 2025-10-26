const std = @import("std");
var log_level = std.log.default_level;

const webcam = @import("webcam/main.zig");
const ftp = @import("ftp");
const mqtt = @import("mqtt");
const http = @import("http");

const Config = @import("Config.zig");
const Flags = @import("Flags.zig");

const printer = @import("printer.zig");
const routes = @import("routes.zig");

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

    try config.load(allocator);

    var debug = false;

    var flags = Flags.empty;
    try flags.add(allocator, "dev", &config.dev, false);
    try flags.add(allocator, "debug", &debug, false);
    try flags.add(allocator, "accessCode", &config.access_code, false);
    try flags.add(allocator, "ip", &config.ip, false);
    try flags.add(allocator, "serial", &config.serial, false);
    try flags.parse(&args);

    // Check required fields
    if (config.access_code.len == 0) {
        std.log.err("access_code is required", .{});
        return error.MissingRequiredConfig;
    }
    if (config.ip.len == 0) {
        std.log.err("ip is required", .{});
        return error.MissingRequiredConfig;
    }
    if (config.serial.len == 0) {
        std.log.err("serial is required", .{});
        return error.MissingRequiredConfig;
    }

    if (debug) {
        log_level = .debug;
    } else {
        log_level = .info;
    }

    std.log.debug("{}", .{config});

    const cert_path = "certificate.pem";
    const embedded_cert = @embedFile(cert_path);

    std.fs.cwd().access(cert_path, .{}) catch {
        const file = try std.fs.cwd().createFile(cert_path, .{});
        defer file.close();
        try file.writeAll(embedded_cert);
    };

    var bundle = std.crypto.Certificate.Bundle{};
    try bundle.addCertsFromFilePath(allocator, std.fs.cwd(), cert_path);
    std.log.debug("Certificates in bundle: {d}\n", .{bundle.map.size});
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

    var printer_status: printer.Status = .{
        .temperature = .{
            .nozzle = 0.0,
            .bed = 0.0,
        },
        .image = &.{},
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
    const http_thread = try std.Thread.spawn(.{}, handleHttp, .{ allocator, &printer_status, mqtt_conn, &config });
    const webcam_thread = try std.Thread.spawn(.{}, handleWebcam, .{ allocator, &printer_status, &config });

    mqtt_thread.join();
    http_thread.join();
    webcam_thread.join();
}

fn handleWebcam(allocator: std.mem.Allocator, printer_status: *printer.Status, config: *Config) !void {
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
        printer_status.image = try img.toOwnedSlice(allocator);
    }
}

fn handleHttp(allocator: std.mem.Allocator, printer_status: *printer.Status, mqtt_conn: *mqtt.Client.Connection, config: *Config) !void {
    const HttpServer = http.Server;
    var ui: routes.UI = .{
        .allocator = allocator,
    };

    var ui_router: http.Router(routes.UI) = .{
        .context = &ui,
        .not_found_handle_fn = routes.UI.notFound,
    };
    defer ui_router.deinit(allocator);

    var api: routes.API = .{ .allocator = allocator, .printer_status = printer_status, .mqtt_conn = mqtt_conn, .config = config };
    var api_router: http.Router(routes.API) = .{
        .context = &api,
    };
    defer api_router.deinit(allocator);

    try api_router.register(allocator, "/version", routes.API.version);
    try api_router.register(allocator, "/printer/status", routes.API.printerStatus);
    try api_router.register(allocator, "/printer/led/chamber", routes.API.printerLedChamber);
    // only handle post requests
    try api_router.register(allocator, "/files/local", routes.API.uploadFile);
    try api_router.register(allocator, "/webcam.jpg", routes.API.webcam);

    try ui_router.registerSubRouter(allocator, "/api", &api_router.serverHandler);

    var server = HttpServer{ .allocator = allocator, .port = 3080, .handler = &ui_router.serverHandler };
    defer {
        server.stop() catch |err| {
            std.log.debug("failed to stop http server: {}", .{err});
        };
    }

    // blocks
    try server.listen();
}

fn handleMqtt(allocator: std.mem.Allocator, conn: *mqtt.Client.Connection, printer_status: *printer.Status) !void {
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
