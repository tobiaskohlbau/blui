const std = @import("std");

const URL = @This();

const Scheme = enum(u2) {
    HTTP,
    HTTPS,
};

scheme: ?Scheme,
host: ?[]const u8,
port: ?u16,
path: ?[]const u8,
query: ?[]const u8,
fragment: ?[]const u8,

pub const empty: URL = .{
    .scheme = null,
    .host = null,
    .port = null,
    .path = null,
    .query = null,
    .fragment = null,
};

const State = enum {
    scheme,
    host,
    port,
    path,
    query,
    fragment,
};

pub fn parse(url: *URL, raw: []const u8) !void {
    try url.parseFromState(raw, .scheme);
}

pub fn parseFromPath(url: *URL, raw: []const u8) !void {
    return url.parseFromState(raw, .path);
}

fn parseFromState(url: *URL, raw: []const u8, state: State) !void {
    var start = @as(u32, 0);
    sw: switch (state) {
        .scheme => {
            if (start == raw.len) {
                return error.InvalidUrl;
            }
            const n = std.mem.findScalarPos(u8, raw, start, ':');
            if (n == null) {
                return error.InvalidURL;
            }
            var buf: [64]u8 = undefined;
            if (n.? > buf.len) {
                return error.UnsupportedUrlScheme;
            }
            const upper_scheme = std.ascii.upperString(&buf, raw[start..n.?]);
            url.scheme = std.meta.stringToEnum(Scheme, upper_scheme) orelse return error.UnknownUrlScheme;

            url.port = switch (url.scheme.?) {
                .HTTP => 80,
                .HTTPS => 443,
            };

            if (raw[n.? + 1] != '/' or raw[n.? + 2] != '/') {
                return error.InvalidUrl;
            }
            start = @intCast(n.? + 3);

            continue :sw .host;
        },
        .host => {
            if (start == raw.len) {
                return error.InvalidUrl;
            }
            const n = std.mem.findAnyPos(u8, raw, start, &.{ ':', '/' });
            if (n == null) {
                url.host = raw[start..];
                return;
            }
            url.host = raw[start..n.?];
            if (raw[n.?] == ':') {
                start = @intCast(n.? + 1);
                continue :sw .port;
            }
            if (raw[n.?] == '/') {
                start = @intCast(n.?);
                continue :sw .path;
            }
            return error.InvalidUrl;
        },
        .port => {
            if (start == raw.len) {
                return error.InvalidUrl;
            }
            const n = std.mem.findScalarPos(u8, raw, start, '/');
            if (n == null) {
                url.port = try std.fmt.parseInt(u16, raw[start..], 10);
                return;
            }
            url.port = try std.fmt.parseInt(u16, raw[start..n.?], 10);
            if (n.? == raw.len - 1) {
                return;
            }

            start = @intCast(n.?);
            continue :sw .path;
        },
        .path => {
            // path is allowed to be empty
            if (start == raw.len) {
                return;
            }

            const n = std.mem.findAnyPos(u8, raw, start, &.{ '?', '#' });
            if (n == null) {
                url.path = raw[start..];
                return;
            }

            if (n.? != start) {
                url.path = raw[start..n.?];
            }
            start = @intCast(n.? + 1);

            if (raw[n.?] == '?') {
                continue :sw .query;
            }
            if (raw[n.?] == '#') {
                continue :sw .fragment;
            }

            return error.InvalidUrl;
        },

        .query => {
            if (start == raw.len) {
                return;
            }

            const n = std.mem.findScalarPos(u8, raw, start, '#');
            if (n == null) {
                url.query = raw[start..];
                return;
            }

            url.query = raw[start..n.?];

            start = @intCast(n.? + 1);
            continue :sw .fragment;
        },

        .fragment => {
            if (start == raw.len) {
                return;
            }

            url.fragment = raw[start..];
            return;
        },
    }
}

pub fn queryByName(url: *URL, key: []const u8) ?[]const u8 {
    if (url.query) |query| {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |q| {
            if (key.len == q.len and std.mem.eql(u8, key, q)) {
                return "";
            }
            const n = std.mem.findScalar(u8, q, '=');
            if (n) |indx| {
                if (std.mem.eql(u8, key, q[0..indx])) {
                    return q[indx + 1 ..];
                }
            }
        }
        return null;
    }

    return null;
}

test "simple url parsing" {
    var url: URL = .empty;

    try url.parse("http://google.de");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqual(null, url.path);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqual(null, url.path);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://google.de:81");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 81), url.port.?);
    try std.testing.expectEqual(null, url.path);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try std.testing.expectError(error.InvalidUrl, url.parse("http://google.de:"));

    url = .empty;
    try url.parse("http://www.google.de:81/");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 81), url.port.?);
    try std.testing.expectEqual(null, url.path);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de:81/search");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 81), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de/");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/", url.path.?);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de/search");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqual(null, url.queryByName("term"));
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de/search?term=test");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqualStrings("test", url.queryByName("term").?);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de/search?term=test#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqualStrings("test", url.queryByName("term").?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/search?term=test&term2=test2#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqualStrings("term=test&term2=test2", url.query.?);
    try std.testing.expectEqualStrings("test", url.queryByName("term").?);
    try std.testing.expectEqualStrings("test2", url.queryByName("term2").?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/search?term=test&term2#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqualStrings("term=test&term2", url.query.?);
    try std.testing.expectEqualStrings("test", url.queryByName("term").?);
    try std.testing.expectEqualStrings("", url.queryByName("term2").?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/search?term=test&term2=#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqualStrings("term=test&term2=", url.query.?);
    try std.testing.expectEqualStrings("test", url.queryByName("term").?);
    try std.testing.expectEqualStrings("", url.queryByName("term2").?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/search#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/search", url.path.?);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme.?);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/", url.path.?);
    try std.testing.expectEqual(null, url.query);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parse("http://www.google.de/?term=test");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme.?);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqual(null, url.fragment);

    url = .empty;
    try url.parse("http://www.google.de/?term=test#fragment");
    try std.testing.expectEqual(Scheme.HTTP, url.scheme);
    try std.testing.expectEqualStrings("www.google.de", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port.?);
    try std.testing.expectEqualStrings("/", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parseFromPath("/?term=test#fragment");
    try std.testing.expectEqual(null, url.scheme);
    try std.testing.expectEqual(null, url.host);
    try std.testing.expectEqual(null, url.port);
    try std.testing.expectEqualStrings("/", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);

    url = .empty;
    try url.parseFromPath("/path?term=test#fragment");
    try std.testing.expectEqual(null, url.scheme);
    try std.testing.expectEqual(null, url.host);
    try std.testing.expectEqual(null, url.port);
    try std.testing.expectEqualStrings("/path", url.path.?);
    try std.testing.expectEqualStrings("term=test", url.query.?);
    try std.testing.expectEqualStrings("fragment", url.fragment.?);
}
