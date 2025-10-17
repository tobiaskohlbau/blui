const std = @import("std");

const Form = @This();

parts: std.array_list.Aligned(Part, null),

const PartIterator = struct {
    form: *Form,
    pos: usize,

    pub fn next(self: *PartIterator) ?Part {
        defer self.pos += 1;
        if (self.pos > self.form.parts.items.len - 1) {
            return null;
        }
        return self.form.parts.items[self.pos];
    }
};

const Header = struct {
    key: []const u8,
    value: []const u8,
};

const Part = struct {
    headers: std.hash_map.StringHashMapUnmanaged(Header) = .empty,
    data: ?[]const u8,
};

pub fn getPart(form: *Form, name: []const u8) ?Part {
    var it = form.partIterator();
    while (it.next()) |part| {
        const header = part.headers.get("Content-Disposition") orelse continue;
        const search_for = "name=\"";
        const name_pos = std.mem.find(u8, header.value, search_for) orelse continue;
        const name_pos_end = std.mem.findScalarPos(u8, header.value, name_pos + search_for.len, '"') orelse continue;
        if (std.mem.eql(u8, header.value[name_pos + search_for.len .. name_pos_end], name)) {
            return part;
        }
    }
    return null;
}

fn slurp(data: []const u8, pos: usize) usize {
    var n = pos;
    while (data[n] == '\r' or data[n] == '\n') : (n += 1) {}
    return n;
}

pub fn partIterator(form: *Form) PartIterator {
    return .{
        .form = form,
        .pos = 0,
    };
}

pub fn deinit(form: *Form, allocator: std.mem.Allocator) void {
    for (form.parts.items) |*part| {
        part.headers.deinit(allocator);
        // allocator.destroy(part);
    }
    form.parts.deinit(allocator);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8, boundary: []const u8) !Form {
    const seperator = try allocator.alloc(u8, boundary.len + 2);
    defer allocator.free(seperator);
    seperator[0] = '-';
    seperator[1] = '-';
    @memcpy(seperator[2..], boundary);
    const State = enum {
        start,
        header,
        body,
    };
    var part: *Part = undefined;
    var parts = std.array_list.Aligned(Part, null).empty;
    var pos: usize = 0;
    sw: switch (@as(State, .start)) {
        .start => {
            std.debug.print("expecting seperator: {d}\n", .{pos});
            if (!std.mem.eql(u8, data[pos .. pos + seperator.len], seperator)) {
                return error.BadInput;
            }
            pos += seperator.len;

            std.debug.print("position after seperator: {d}\n", .{pos});

            // check for part end
            if (data[pos + 1] == '-' and data[pos + 1] == '-') {
                std.debug.print("end of all part\n", .{});
                return .{
                    .parts = parts,
                };
            }

            part = try parts.addOne(allocator);
            part.headers = .empty;
            part.data = null;
            pos = slurp(data, pos);
            std.debug.print("found seperator: {d} {x}\n", .{ pos, data[pos] });
            continue :sw .header;
        },
        .header => {
            const colon_pos = std.mem.findScalarPos(u8, data, pos, ':') orelse return error.BadHeader;
            const eol_pos = std.mem.findPos(u8, data, pos, "\r\n") orelse return error.BadHeader;
            std.debug.print("found colon and eol: {d} {d}\n", .{ colon_pos, eol_pos });
            const key = data[pos..colon_pos];
            try part.headers.put(allocator, key, .{
                .key = key,
                .value = data[colon_pos + 1 .. eol_pos],
            });

            pos = eol_pos;
            std.debug.print("new position: {d} following {x}\n", .{ pos, data[pos .. pos + 4] });

            if (std.mem.startsWith(u8, data[pos..], "\r\n\r\n")) {
                std.debug.print("found content separator\n", .{});
                pos = slurp(data, pos);
                continue :sw .body;
            }

            pos = slurp(data, pos);
            continue :sw .header;
        },
        .body => {
            const seperator_pos = std.mem.findPos(u8, data, pos, seperator) orelse return error.BadBody;

            std.debug.print("found seperator at: {d} {d}\n", .{ pos, seperator_pos });
            if (seperator_pos != pos) {
                part.data = data[pos .. seperator_pos - 2];
            }

            // advance past seperator
            pos = seperator_pos;

            continue :sw .start;
        },
    }
}

inline fn crlf(comptime s: []const u8) []const u8 {
    comptime {
        var res: []const u8 = "";
        var pos: usize = 0;
        while (std.mem.findScalarPos(u8, s, pos, '\\')) |i| {
            if (i + 1 == s.len) @compileError(std.fmt.comptimePrint("trailing \\ at {d}", i));
            res = res ++ s[pos..i];
            switch (s[i + 1]) {
                'r' => res = res ++ "\r",
                else => @compileError("invalid escape"),
            }
            pos = i + 2;
        }
        return res ++ s[pos..];
    }
}

test "simple parsing" {
    const form_data = crlf(
        \\--boundary\r
        \\Content-Disposition: form-data; name="field1"\r
        \\\r
        \\value1\r
        \\--boundary\r
        \\Content-Disposition: form-data; name="field2"; filename="example.txt"\r
        \\Content-Type: text/plain\r
        \\\r
        \\file content here\r
        \\--boundary--\r
    );
    const boundary = "boundary";
    var form = try parse(std.testing.allocator, form_data, boundary);
    defer form.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), form.parts.items.len);
    var it = form.partIterator();
    if (it.next()) |part| {
        var header_it = part.headers.iterator();

        var header = header_it.next() orelse return error.MissingHeader;
        try std.testing.expectEqualStrings("Content-Disposition", header.key_ptr.*);
        try std.testing.expectEqualStrings(" form-data; name=\"field1\"", header.value_ptr.value);

        try std.testing.expectEqualStrings("value1", part.data.?);
    }
    if (it.next()) |part| {
        var header_it = part.headers.iterator();

        var matching_headers: usize = 0;
        while (header_it.next()) |header| {
            if (std.mem.eql(u8, "Content-Disposition", header.key_ptr.*)) {
                try std.testing.expectEqualStrings(" form-data; name=\"field2\"; filename=\"example.txt\"", header.value_ptr.value);
                matching_headers += 1;
            }
            if (std.mem.eql(u8, "Content-Type", header.key_ptr.*)) {
                try std.testing.expectEqualStrings(" text/plain", header.value_ptr.value);
                matching_headers += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), matching_headers);

        try std.testing.expectEqualStrings("file content here", part.data.?);
    }
}

test "simple empty parsing" {
    const form_data = crlf(
        \\--boundary\r
        \\Content-Disposition: form-data; name="field1"\r
        \\\r
        \\value1\r
        \\--boundary\r
        \\Content-Disposition: form-data; name="field2"\r
        \\\r
        \\\r
        \\--boundary\r
        \\Content-Disposition: form-data; name="field3"; filename="example.txt"\r
        \\Content-Type: text/plain\r
        \\\r
        \\file content here\r
        \\--boundary--\r
    );
    const boundary = "boundary";
    var form = try parse(std.testing.allocator, form_data, boundary);
    defer form.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), form.parts.items.len);
    var it = form.partIterator();
    if (it.next()) |part| {
        var header_it = part.headers.iterator();

        var header = header_it.next() orelse return error.MissingHeader;
        try std.testing.expectEqualStrings("Content-Disposition", header.key_ptr.*);
        try std.testing.expectEqualStrings(" form-data; name=\"field1\"", header.value_ptr.value);

        try std.testing.expectEqualStrings("value1", part.data.?);
    }
    if (it.next()) |part| {
        var header_it = part.headers.iterator();

        var header = header_it.next() orelse return error.MissingHeader;
        try std.testing.expectEqualStrings("Content-Disposition", header.key_ptr.*);
        try std.testing.expectEqualStrings(" form-data; name=\"field2\"", header.value_ptr.value);

        try std.testing.expectEqual(null, part.data);
    }
    if (it.next()) |part| {
        var header_it = part.headers.iterator();

        var matching_headers: usize = 0;
        while (header_it.next()) |header| {
            if (std.mem.eql(u8, "Content-Disposition", header.key_ptr.*)) {
                try std.testing.expectEqualStrings(" form-data; name=\"field3\"; filename=\"example.txt\"", header.value_ptr.value);
                matching_headers += 1;
            }
            if (std.mem.eql(u8, "Content-Type", header.key_ptr.*)) {
                try std.testing.expectEqualStrings(" text/plain", header.value_ptr.value);
                matching_headers += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), matching_headers);

        try std.testing.expectEqualStrings("file content here", part.data.?);
    }
}
