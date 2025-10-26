const std = @import("std");

const Flags = @This();

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

pub const empty: Flags = .{
    .flags = .{},
};

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
