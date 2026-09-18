//! `git-upload-pack` over the git daemon protocol, `git://`, on one plain
//! TCP connection.
//!
//! **The simplest of the three transports, and the only one with no
//! security of any kind.** The daemon protocol is anonymous, unencrypted
//! and unauthenticated: there is no credential to offer and no host key to
//! check, so a `git://` fetch trusts whatever answers the socket. Git
//! itself is no different. A caller that needs to know who it is talking
//! to wants `https` or `ssh`.
//!
//! **The session shape matches `Ssh`, not `Http`.** One connection carries
//! the whole conversation: the request line names the repository, the
//! daemon runs one `git-upload-pack` process, and every v2 command after
//! that is written to the same socket and read back from it. `Http` posts
//! once per command because stateless-rpc is what smart HTTP is; nothing
//! here needs that.
//!
//! **This builds on `std.Io.net` alone.** A plain TCP connection and a
//! hostname lookup are both in the standard library, so this transport
//! adds no dependency, unlike the two above it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("ziggit-core");
const proto = @import("ziggit-proto");
const pktline_mod = @import("ziggit-pktline");

const transport_mod = @import("Transport.zig");
const Transport = transport_mod.Transport;
const Command = transport_mod.Command;
const Capabilities = transport_mod.Capabilities;
const Diagnostic = transport_mod.Diagnostic;
const Error = transport_mod.Error;

/// The port the git daemon listens on when a url names none. Git omits the
/// port from the `host=` parameter when it is this one, and includes it
/// otherwise; `writeRequest` reproduces that.
pub const default_port: u16 = 9418;

/// Everything the session owns that must not move once it is running: the
/// stream, and the reader built over it, which holds a pointer to it.
///
/// Allocated once so `Git` stays a small handle that can be copied freely,
/// the same arrangement `Ssh` uses and for the same reason.
const State = struct {
    gpa: Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,
    /// `std.Io.net.Stream` hands out its own `Reader`, so this transport
    /// writes no adapter of its own. One instance lives for the whole
    /// session: every `capabilities` and `command` call reads the same
    /// socket.
    reader: std.Io.net.Stream.Reader,
    reader_buffer: [8192]u8,
    writer: std.Io.net.Stream.Writer,
    writer_buffer: [4096]u8,
};

pub const Git = struct {
    gpa: Allocator,
    io: std.Io,
    state: *State,

    /// Connects to the daemon at `url` (`git://host[:port]/path`) and asks
    /// it for `git-upload-pack` on that path.
    ///
    /// **This takes no `Options`, unlike `Http.open` and `Ssh.open`.** Not
    /// one field of it can be honoured here today: credentials have nothing
    /// to authenticate to, the proxy, CA and redirect settings are HTTP's
    /// alone, and the connect timeout is refused by `std.Io` itself (see
    /// below). Taking the struct and ignoring it would be an option a
    /// caller can set and this code silently drops, which is a bug this
    /// project has shipped more than once. The parameter comes back when
    /// there is something for it to control.
    pub fn open(gpa: Allocator, io: std.Io, url: []const u8) Error!Git {
        const parsed = try parseUrl(url);

        const address = std.Io.net.IpAddress.resolve(io, parsed.host, parsed.port) catch
            return error.NetworkFailed;

        const state = gpa.create(State) catch return error.OutOfMemory;
        errdefer gpa.destroy(state);
        state.gpa = gpa;
        state.io = io;

        // `Options.connect_timeout_ms` is NOT honoured here, and this is a
        // limit of the standard library rather than a choice.
        // `std.Io.Threaded`'s `netConnectIpPosix` does this:
        //
        //     if (options.timeout != .none)
        //         @panic("TODO implement netConnectIpPosix with timeout");
        //
        // so passing the caller's timeout crashes the process instead of
        // bounding the dial. `Http` and `Ssh` both honour the same field,
        // because they connect through zurl rather than through `std.Io`.
        // A `git://` dial to an unreachable host therefore waits for the
        // system's own TCP timeout.
        //
        // Passing `.none` and saying so beats passing the timeout and
        // crashing, and it beats saying nothing: a caller that sets the
        // field is entitled to know it does nothing here. Revisit when
        // that TODO is implemented.
        state.stream = address.connect(io, .{
            .mode = .stream,
            .timeout = .none,
        }) catch return error.NetworkFailed;
        errdefer state.stream.close(io);

        try writeRequest(io, &state.stream, parsed);

        state.reader = state.stream.reader(io, &state.reader_buffer);
        state.writer = state.stream.writer(io, &state.writer_buffer);
        return .{ .gpa = gpa, .io = io, .state = state };
    }

    pub fn transport(g: *Git) Transport {
        return .{ .ptr = g, .vtable = &vtable };
    }

    pub fn deinit(g: *Git) void {
        g.state.stream.close(g.io);
        g.gpa.destroy(g.state);
        g.* = undefined;
    }

    const vtable: Transport.VTable = .{
        .capabilities = capabilitiesImpl,
        .command = commandImpl,
        .close = closeImpl,
    };

    fn capabilitiesImpl(ctx: *anyopaque, gpa: Allocator, diag: ?*?Diagnostic) Error!Capabilities {
        const g: *Git = @ptrCast(@alignCast(ctx));
        g.state.reader.interface.seek = 0;
        g.state.reader.interface.end = 0;

        var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
        var remote_message: ?[]u8 = null;
        defer if (remote_message) |m| gpa.free(m);
        return proto.parseCapabilities(gpa, &g.state.reader.interface, &buf, &remote_message) catch |err| {
            // The daemon refused by name: say what it said. Its commonest
            // refusal is a repository that is not there.
            if (err == error.RemoteRefused) {
                recordMessage(gpa, diag, remote_message orelse "the git daemon refused the request");
                return error.NotFound;
            }
            // Unlike ssh, nothing here can fail to ask for v2: the version
            // rides in the request line and the daemon either understands
            // it or does not. So v0 means the daemon is old, not that a
            // request was refused along the way.
            const msg = switch (err) {
                error.UnsupportedProtocol => "the git daemon answered protocol v0 or v1, which this build does not implement",
                else => "reading the git daemon's capability advertisement failed",
            };
            recordMessage(gpa, diag, msg);
            return switch (err) {
                error.RemoteRefused => unreachable, // handled above
                else => |e| e,
            };
        };
    }

    fn commandImpl(ctx: *anyopaque, gpa: Allocator, cmd: Command, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void {
        const g: *Git = @ptrCast(@alignCast(ctx));
        g.state.reader.interface.seek = 0;
        g.state.reader.interface.end = 0;

        g.state.writer.interface.writeAll(cmd.body) catch {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "the git daemon connection failed while writing the '{s}' command",
                .{cmd.name},
            ) catch "the git daemon connection failed while writing the command";
            recordMessage(gpa, diag, msg);
            return error.ConnectionLost;
        };
        g.state.writer.interface.flush() catch {
            recordMessage(gpa, diag, "the git daemon connection failed while flushing a command");
            return error.ConnectionLost;
        };

        out.* = &g.state.reader.interface;
    }

    /// The daemon needs no goodbye: closing the socket ends the session,
    /// and `deinit` does that. A caller holding only a `Transport` may
    /// still call this, so it is a no-op rather than an error.
    fn closeImpl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    /// True when the url named a port explicitly. Git puts the port in the
    /// `host=` parameter only then, so this is not the same question as
    /// `port != default_port`.
    port_was_written: bool,
};

fn parseUrl(url: []const u8) Error!ParsedUrl {
    const prefix = "git://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.UnsupportedProtocol;
    const rest = url[prefix.len..];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.ProtocolError;
    const authority = rest[0..slash];
    const path = rest[slash..];
    if (path.len <= 1) return error.ProtocolError;

    // `git://` has no authentication, so a userinfo component is always a
    // mistake. Git does not reject it: it treats `someone@host` as a
    // literal hostname and fails the DNS lookup, which sends a reader
    // looking for a name server problem they do not have. Refusing it here
    // names the real fault. Measured against git 2.54.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.ProtocolError;

    var host = authority;
    var port: u16 = default_port;
    var port_was_written = false;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.ProtocolError;
        port_was_written = true;
    }
    if (host.len == 0) return error.ProtocolError;

    return .{ .host = host, .port = port, .path = path, .port_was_written = port_was_written };
}

/// Longest request line this will build. The path and the host dominate;
/// git's own daemon refuses far smaller requests than this.
const max_request_len: usize = 4096;

/// Writes the daemon's one request line, which names the service, the
/// repository and the protocol version.
///
/// Captured from git 2.54 rather than read off a specification, because
/// two details are easy to get wrong and both are silent:
///
/// ```
/// 0040git-upload-pack /project.git\0host=127.0.0.1:9501\0\0version=2\0
/// 003bgit-upload-pack /project.git\0host=127.0.0.1\0\0version=2\0
/// ```
///
/// **The extra parameters are introduced by a SECOND NUL**, so there is an
/// empty field between the host and `version=2`. Leaving it out makes the
/// daemon read no version at all and answer protocol v0, which looks like
/// an old server rather than a malformed request.
///
/// **The port appears in `host=` only when the url wrote one.** The second
/// line above is the same daemon on port 9418 reached by a url that named
/// no port.
fn buildRequest(buf: *[max_request_len]u8, parsed: ParsedUrl) Error![]const u8 {
    // The length prefix covers itself, so the payload is written after
    // room for it, measured, and the prefix filled in over the front.
    var payload: std.Io.Writer = .fixed(buf[4..]);
    payload.writeAll("git-upload-pack ") catch return error.ProtocolError;
    payload.writeAll(parsed.path) catch return error.ProtocolError;
    payload.writeByte(0) catch return error.ProtocolError;
    payload.writeAll("host=") catch return error.ProtocolError;
    payload.writeAll(parsed.host) catch return error.ProtocolError;
    if (parsed.port_was_written) {
        payload.print(":{d}", .{parsed.port}) catch return error.ProtocolError;
    }
    payload.writeByte(0) catch return error.ProtocolError;
    // The empty field that introduces the extra parameters.
    payload.writeByte(0) catch return error.ProtocolError;
    payload.writeAll("version=2") catch return error.ProtocolError;
    payload.writeByte(0) catch return error.ProtocolError;

    const total = payload.buffered().len + 4;
    if (total > 0xffff) return error.ProtocolError;
    var w: std.Io.Writer = .fixed(buf);
    _ = w.print("{x:0>4}", .{total}) catch return error.ProtocolError;
    return buf[0..total];
}

fn writeRequest(io: std.Io, stream: *std.Io.net.Stream, parsed: ParsedUrl) Error!void {
    var buf: [max_request_len]u8 = undefined;
    const line = try buildRequest(&buf, parsed);
    var out_buf: [max_request_len]u8 = undefined;
    var out = stream.writer(io, &out_buf);
    out.interface.writeAll(line) catch return error.NetworkFailed;
    out.interface.flush() catch return error.NetworkFailed;
}

fn recordMessage(gpa: Allocator, diag: ?*?Diagnostic, text: []const u8) void {
    if (!core.wants(diag)) return;
    const owned = gpa.dupe(u8, text) catch null;
    core.report(diag, gpa, .{ .kind = .io, .path = null, .detail = owned });
}

const testing = std.testing;

test "the daemon request line matches the bytes git sends" {
    // Both vectors were captured from git 2.54 with a listening socket, not
    // written from a specification.
    var parsed = try parseUrl("git://127.0.0.1:9501/project.git");
    var buf: [max_request_len]u8 = undefined;
    var got = try buildRequest(&buf, parsed);
    try testing.expectEqualStrings(
        "0040git-upload-pack /project.git\x00host=127.0.0.1:9501\x00\x00version=2\x00",
        got,
    );

    // The same daemon reached by a url naming no port: git omits the port
    // from `host=` entirely, and the length changes with it.
    parsed = try parseUrl("git://127.0.0.1/project.git");
    got = try buildRequest(&buf, parsed);
    try testing.expectEqualStrings(
        "003bgit-upload-pack /project.git\x00host=127.0.0.1\x00\x00version=2\x00",
        got,
    );
}

test "a git url naming a user is refused rather than resolved as a hostname" {
    // Git treats `someone@host` as a literal hostname and fails the DNS
    // lookup. The daemon protocol has no authentication, so a userinfo
    // component is always a mistake and saying so beats a name server error.
    try testing.expectError(error.ProtocolError, parseUrl("git://someone@127.0.0.1:9418/p.git"));
}

test "a git url parses its host, port and path" {
    const with_port = try parseUrl("git://example.com:9999/a/b.git");
    try testing.expectEqualStrings("example.com", with_port.host);
    try testing.expectEqual(@as(u16, 9999), with_port.port);
    try testing.expectEqualStrings("/a/b.git", with_port.path);
    try testing.expect(with_port.port_was_written);

    const without = try parseUrl("git://example.com/a/b.git");
    try testing.expectEqual(default_port, without.port);
    try testing.expect(!without.port_was_written);
}

test "a git url this transport cannot serve is refused by name" {
    try testing.expectError(error.UnsupportedProtocol, parseUrl("https://example.com/a.git"));
    // No path at all, and a bare slash, are both incomplete rather than
    // requests for the daemon's root.
    try testing.expectError(error.ProtocolError, parseUrl("git://example.com"));
    try testing.expectError(error.ProtocolError, parseUrl("git://example.com/"));
    try testing.expectError(error.ProtocolError, parseUrl("git:///a.git"));
}
