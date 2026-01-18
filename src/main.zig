const std = @import("std");
var log_level = std.log.default_level;

const builtin = @import("builtin");
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

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const process = std.process;

pub fn main(init: process.Init.Minimal) !void {
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var gpio = switch (builtin.os.tag) {
        // currently only threaded is implemented in zig std
        else => std.Io.Threaded.init(gpa, .{
            .environ = .empty,
        }),
    };
    defer gpio.deinit();
    const io = gpio.io();

    var config: Config = .{
        .dev = false,
        .access_code = "",
        .ip = "",
        .serial = "",
        .ca_bundle = null,
    };

    try config.load(gpa, io, init.environ);

    var debug = false;

    var flags = Flags.empty;
    try flags.add(gpa, "dev", &config.dev, false);
    try flags.add(gpa, "debug", &debug, false);
    try flags.add(gpa, "accessCode", &config.access_code, false);
    try flags.add(gpa, "ip", &config.ip, false);
    try flags.add(gpa, "serial", &config.serial, false);
    try flags.parse(gpa, &init.args);
    defer flags.deinit(gpa);

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

    std.Io.Dir.cwd().access(io, cert_path, .{}) catch {
        const file = try std.Io.Dir.cwd().createFile(io, cert_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, embedded_cert);
    };

    var bundle = std.crypto.Certificate.Bundle{};
    try bundle.addCertsFromFilePath(gpa, io, try std.Io.Clock.real.now(io), std.Io.Dir.cwd(), cert_path);
    std.log.debug("Certificates in bundle: {d}\n", .{bundle.map.size});

    var mqtt_client = mqtt.Client{ .allocator = gpa, .io = io };

    var mqtt_conn = try mqtt_client.connect(config.ip, 8883, .tls, .{ .username = "bblp", .password = config.access_code, .client_id = "blUI", .keepalive_sec = 0 });
    _ = &mqtt_conn;

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

    var printer_status: printer.Status = .{
        .temperature = .{
            .nozzle = 0.0,
            .nozzle_target = 0.0,
            .bed = 0.0,
            .bed_target = 0.0,
        },
        .fan = .{
            .cooling_speed = 0.0,
            .case_speed = 0.0,
            .filter_speed = 0.0,
        },
        .print_percent = 0.0,
        .print_remaining_time = 0.0,
        .image = &.{},
    };

    var topic_buffer: [1024]u8 = undefined;
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

    {
        const message =
            \\{"pushing": {"sequence_id": "0", "command": "pushall"}}
        ;
        _ = try mqtt_conn.publish(.{ .topic = try std.fmt.bufPrint(&topic_buffer, "device/{s}/request", .{config.serial}), .message = message });
    }

    const mqtt_thread = try std.Thread.spawn(.{}, handleMqtt, .{ gpa, mqtt_conn, &printer_status });
    const http_thread = try std.Thread.spawn(.{}, handleHttp, .{ gpa, io, &printer_status, mqtt_conn, &config });
    const webcam_thread = try std.Thread.spawn(.{}, handleWebcam, .{ gpa, io, &printer_status, &config });

    mqtt_thread.join();
    http_thread.join();
    webcam_thread.join();
}

fn handleWebcam(gpa: std.mem.Allocator, io: std.Io, printer_status: *printer.Status, config: *Config) !void {
    // var webcam_client = webcam.Client{ .allocator = allocator, .ca_bundle = config.ca_bundle };
    var webcam_client = webcam.Client{
        .allocator = gpa,
        .io = io,
        .ca_bundle = null,
    };
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
        try img.resize(gpa, image_length);
        try reader.discardAll(3 * 4);
        try reader.readSliceAll(img.items);
        printer_status.image = try img.toOwnedSlice(gpa);
    }
}

fn handleHttp(gpa: std.mem.Allocator, io: std.Io, printer_status: *printer.Status, mqtt_conn: *mqtt.Client.Connection, config: *Config) !void {
    const HttpServer = http.Server;
    var ui: routes.UI = .{
        .allocator = gpa,
    };

    var ui_router: http.Router(routes.UI) = .{
        .context = &ui,
        .not_found_handle_fn = routes.UI.notFound,
    };
    defer ui_router.deinit(gpa);

    var api: routes.API = .{ .allocator = gpa, .io = io, .printer_status = printer_status, .mqtt_conn = mqtt_conn, .config = config };
    var api_router: http.Router(routes.API) = .{
        .context = &api,
    };
    defer api_router.deinit(gpa);

    try api_router.register(gpa, "/version", routes.API.version);
    try api_router.register(gpa, "/printer/status", routes.API.printerStatus);
    try api_router.register(gpa, "/printer/led/chamber", routes.API.printerLedChamber);
    try api_router.register(gpa, "/printer/pause", routes.API.printerPause);
    try api_router.register(gpa, "/printer/resume", routes.API.printerResume);
    try api_router.register(gpa, "/printer/stop", routes.API.printerStop);
    try api_router.register(gpa, "/printer/clean_error", routes.API.printerCleanError);
    // only handle post requests
    try api_router.register(gpa, "/files/local", routes.API.uploadFile);
    try api_router.register(gpa, "/webcam.jpg", routes.API.webcam);

    try ui_router.registerSubRouter(gpa, "/api", &api_router.serverHandler);

    var server = HttpServer{ .allocator = gpa, .io = io, .port = 3080, .handler = &ui_router.serverHandler };
    defer {
        server.stop() catch |err| {
            std.log.debug("failed to stop http server: {}", .{err});
        };
    }

    // blocks
    try server.listen();
}

fn handleMqtt(gpa: std.mem.Allocator, conn: *mqtt.Client.Connection, printer_status: *printer.Status) !void {
    const Print = struct {
        command: []const u8,
        nozzle_temper: ?f64 = null,
        nozzle_target_temper: ?f64 = null,
        bed_temper: ?f64 = null,
        bed_target_temper: ?f64 = null,
        cooling_fan_speed: ?f64 = null,
        big_fan1_speed: ?f64 = null,
        big_fan2_speed: ?f64 = null,
        mc_percent: ?f64 = null,
        mc_remaining_time: ?f64 = null,
    };
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
                const parsed_msg = try std.json.parseFromSlice(MqttMessage, gpa, publish.message, .{
                    .ignore_unknown_fields = true,
                });
                const msg = parsed_msg.value;
                switch (msg) {
                    .print => |print| {
                        if (std.mem.eql(u8, print.command, "push_status")) {
                            if (print.bed_temper) |t| {
                                printer_status.temperature.bed = t;
                            }
                            if (print.bed_target_temper) |t| {
                                printer_status.temperature.bed_target = t;
                            }
                            if (print.nozzle_temper) |t| {
                                printer_status.temperature.nozzle = t;
                            }
                            if (print.nozzle_target_temper) |t| {
                                printer_status.temperature.nozzle_target = t;
                            }
                            if (print.cooling_fan_speed) |s| {
                                printer_status.fan.cooling_speed = s;
                            }
                            if (print.big_fan1_speed) |s| {
                                printer_status.fan.case_speed = s;
                            }
                            if (print.big_fan2_speed) |s| {
                                printer_status.fan.filter_speed = s;
                            }
                            if (print.mc_percent) |p| {
                                printer_status.print_percent = p;
                            }
                            if (print.mc_remaining_time) |r| {
                                printer_status.print_remaining_time = r;
                            }
                        }
                    },
                    .system => |system| {
                        std.log.info("received system message: {}", .{system});
                    },
                }
            },
            else => {
                std.log.err("unexpected packet: {any}\n", .{packet});
            },
        }
    }
}
