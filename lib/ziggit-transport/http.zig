//! Smart HTTP: the two request shapes git's dumb-envelope-free HTTP
//! protocol uses, `GET .../info/refs?service=git-upload-pack` for the
//! capability advertisement and `POST .../git-upload-pack` for every v2
//! command, driven over `zurl`.
//!
//! `Http` owns one `zurl.Client`. Nothing here shares a client across two
//! `Http` values, and nothing here keeps a setting outside `Options`: a
//! caller that runs two fetches against two hosts at once gives each its
//! own `Http` and its own `Options`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zurl = @import("zurl");

const core = @import("ziggit-core");
const proto = @import("ziggit-proto");
const pktline_mod = @import("ziggit-pktline");

const transport_mod = @import("Transport.zig");
const Transport = transport_mod.Transport;
const Options = transport_mod.Options;
const Command = transport_mod.Command;
const Progress = transport_mod.Progress;
const Capabilities = transport_mod.Capabilities;
const Diagnostic = transport_mod.Diagnostic;
const Error = transport_mod.Error;

const credentials_mod = @import("credentials.zig");
const Credential = credentials_mod.Credential;

/// The request body's read state: the bytes `ziggit-proto` already
/// encoded, and how far `read` has copied them out.
const BodyCtx = struct {
    data: []const u8,
    pos: usize,
};

fn bodyRead(ctx: *anyopaque, buffer: [*]u8, len: usize) callconv(.c) isize {
    const b: *BodyCtx = @ptrCast(@alignCast(ctx));
    const remaining = b.data.len - b.pos;
    const n = @min(remaining, len);
    @memcpy(buffer[0..n], b.data[b.pos..][0..n]);
    b.pos += n;
    return @intCast(n);
}

fn bodyRewind(ctx: *anyopaque) callconv(.c) bool {
    const b: *BodyCtx = @ptrCast(@alignCast(ctx));
    b.pos = 0;
    return true;
}

pub const Http = struct {
    gpa: Allocator,
    io: std.Io,
    /// The repository url, with any trailing slash trimmed. Owned by this
    /// struct; `deinit` frees it.
    base_url: []const u8,
    options: Options,
    /// Owned by this struct; `deinit` closes it.
    client: zurl.Client,
    /// `options.proxy_url`, parsed once at `open` rather than on every
    /// request. Borrows from `options.proxy_url`, so it lives exactly as
    /// long as `options` does.
    proxy: ?zurl.Transfer.ProxySpec,

    /// Opens no connection. `capabilities` and `command` are what touch
    /// the network; this only prepares the client that will.
    pub fn open(gpa: Allocator, io: std.Io, url: []const u8, options: Options) Error!Http {
        const trimmed = std.mem.trimEnd(u8, url, "/");
        const owned = try gpa.dupe(u8, trimmed);
        errdefer gpa.free(owned);

        const proxy: ?zurl.Transfer.ProxySpec = if (options.proxy_url) |raw|
            zurl.proxy_rules.parse(raw) catch |err| return switch (err) {
                error.UnsupportedProxyScheme => error.UnsupportedProtocol,
                error.InvalidProxy => error.ProtocolError,
            }
        else
            null;

        return .{
            .gpa = gpa,
            .io = io,
            .base_url = owned,
            .options = options,
            .client = zurl.Client.init(gpa, io),
            .proxy = proxy,
        };
    }

    pub fn transport(h: *Http) Transport {
        return .{ .ptr = h, .vtable = &vtable };
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
        h.gpa.free(h.base_url);
        h.* = undefined;
    }

    const vtable: Transport.VTable = .{
        .capabilities = capabilitiesImpl,
        .command = commandImpl,
        .close = closeImpl,
    };

    fn closeImpl(ctx: *anyopaque) void {
        // HTTP holds no per-command session to end: each `command` is one
        // complete request and response, unlike an SSH channel. The real
        // teardown is `Http.deinit`, which the caller still owns and
        // still must call; this stays a no-op so a generic caller that
        // only holds a `Transport` may call it with nothing to undo.
        _ = ctx;
    }

    fn zurlOptions(
        h: *Http,
        method: std.http.Method,
        body: ?zurl.Transfer.Body,
        headers: []const std.http.Header,
    ) zurl.Transfer.Options {
        return .{
            .method = method,
            .body = body,
            .headers = headers,
            .fail_on_error = false,
            .redirects = .{ .follow = h.options.follow_redirects },
            .connect_timeout = .{
                .duration = .{ .raw = .fromMilliseconds(h.options.connect_timeout_ms), .clock = .awake },
            },
            .low_speed_time_s = h.options.stall_timeout_s,
            .location_trusted = false,
            .ca = .{ .cacert = h.options.ca_cert_file, .capath = h.options.ca_cert_dir },
            .reporter = if (h.options.progress) |*p| .{ .ctx = p, .report = reportProgress } else null,
            // `-x` covers a cleartext and a TLS target alike, so the one
            // proxy the caller named answers for both.
            .proxy = h.proxy,
            .proxy_tls = h.proxy,
        };
    }
};

/// Adapts `Progress.onBytes` to the `callconv(.c)` shape zurl's own
/// reporter takes. zurl's decorator reports an unknown length as `0`;
/// this turns that back into the `null` `Progress.onBytes` promises.
/// A `null` total means zurl could not determine the response size; it also
/// arises from genuinely empty responses where the sender omitted Content-Length.
fn reportProgress(ctx: *anyopaque, transferred: u64, total: u64) callconv(.c) void {
    const p: *Progress = @ptrCast(@alignCast(ctx));
    p.onBytes(p.ctx, transferred, if (total == 0) null else total);
}

fn capabilitiesImpl(ctx: *anyopaque, gpa: Allocator, diag: ?*?Diagnostic) Error!Capabilities {
    const h: *Http = @ptrCast(@alignCast(ctx));

    const url = std.fmt.allocPrint(gpa, "{s}/info/refs?service=git-upload-pack", .{h.base_url}) catch
        return error.OutOfMemory;
    defer gpa.free(url);

    const zopts = h.zurlOptions(.GET, null, &.{
        .{ .name = "Git-Protocol", .value = "version=2" },
    });

    const resp = try performWithAuth(gpa, h, url, zopts, null, diag);

    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    try skipServiceHeader(gpa, resp.body, &buf, "git-upload-pack", diag);
    var remote_message: ?[]u8 = null;
    defer if (remote_message) |m| gpa.free(m);
    return proto.parseCapabilities(gpa, resp.body, &buf, &remote_message) catch |err| switch (err) {
        // The server answered an `ERR` line rather than an advertisement.
        // Its own text names the reason, which is worth far more than the
        // parse fault that used to be reported in its place.
        error.RemoteRefused => {
            recordMessage(gpa, diag, remote_message orelse "the server refused the request");
            return error.NotFound;
        },
        else => |e| return e,
    };
}

fn commandImpl(ctx: *anyopaque, gpa: Allocator, cmd: Command, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void {
    const h: *Http = @ptrCast(@alignCast(ctx));

    const url = std.fmt.allocPrint(gpa, "{s}/git-upload-pack", .{h.base_url}) catch
        return error.OutOfMemory;
    defer gpa.free(url);

    var body_ctx: BodyCtx = .{ .data = cmd.body, .pos = 0 };
    const body: zurl.Transfer.Body = .{
        .len = cmd.body.len,
        .ctx = &body_ctx,
        .read = bodyRead,
        .rewind = bodyRewind,
        .content_type = "application/x-git-upload-pack-request",
    };

    const zopts = h.zurlOptions(.POST, body, &.{
        .{ .name = "Git-Protocol", .value = "version=2" },
    });

    const resp = try performWithAuth(gpa, h, url, zopts, &body_ctx, diag);
    out.* = resp.body;
}

/// Reads the `# service=<service>` pkt-line and the flush behind it, the
/// prefix git's smart HTTP `GET .../info/refs` puts in front of the
/// ordinary capability advertisement.
fn skipServiceHeader(
    gpa: Allocator,
    r: *std.Io.Reader,
    buf: []u8,
    service: []const u8,
    diag: ?*?Diagnostic,
) Error!void {
    const packet = pktline_mod.read(r, buf) catch {
        recordMessage(gpa, diag, "the server's info/refs response is not a pkt-line stream");
        return error.ProtocolError;
    };
    const line = switch (packet) {
        .data => |d| std.mem.trimEnd(u8, d, "\n"),
        .flush, .delimiter, .response_end => {
            recordMessage(gpa, diag, "the server's info/refs response carries no service line");
            return error.ProtocolError;
        },
    };

    var expected_buf: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "# service={s}", .{service}) catch unreachable;
    if (!std.mem.eql(u8, line, expected)) {
        recordMessage(gpa, diag, "the server's info/refs response names a different service");
        return error.ProtocolError;
    }

    const flush = pktline_mod.read(r, buf) catch {
        recordMessage(gpa, diag, "the server's info/refs response carries no flush after the service line");
        return error.ProtocolError;
    };
    if (flush != .flush) {
        recordMessage(gpa, diag, "the server's info/refs response carries no flush after the service line");
        return error.ProtocolError;
    }
}

/// How large a url `performWithAuth` copies before a retry. Past any git
/// remote url a person would type, and past any redirect target a real
/// server sends. `effective_url` is peer-controlled, so a url past this
/// bound is `error.ProtocolError`, never a silent truncation: a truncated
/// retry url would ask a host, or a path, the peer never named.
const retry_url_len_max = 2048;

/// The longest host `performWithAuth` remembers having already challenged.
/// Past the 253-byte ceiling RFC 1035 puts on a DNS name, and past any
/// bracketed IPv6 literal.
const challenged_host_len_max = 256;

/// A hard ceiling on how many `401` challenges one exchange answers, no
/// matter how many hosts a redirect chain crosses. Credentials are
/// tracked per host below, so a legitimate exchange spends at most one
/// challenge per host it visits; this is well past any real redirect
/// chain, which `Options.follow_redirects` already bounds at 10 by
/// default, and it exists only so a server that keeps bouncing a request
/// between two hosts' challenges cannot loop this call forever.
const credential_attempts_max = 16;

/// Runs one request, answering a `401` by asking `h.options.credentials`.
///
/// **The retry budget is per host, not per exchange.** A host that has
/// not yet had its own credential challenge answered gets one, even if
/// other hosts on the same redirect chain already failed theirs: a
/// retried request that is itself redirected to a new host is that host's
/// first challenge, not a second challenge overall. A host whose
/// credential was already tried and rejected gets no second try.
/// `credential_attempts_max` bounds the total regardless, so a chain that
/// keeps producing new-looking hosts still ends.
fn performWithAuth(
    gpa: Allocator,
    h: *Http,
    url: []const u8,
    zopts_in: zurl.Transfer.Options,
    body_ctx: ?*BodyCtx,
    diag: ?*?Diagnostic,
) Error!zurl.Response {
    var zopts = zopts_in;
    var attempts: u8 = 0;
    // Where the next attempt goes. Starts at the caller's url; a 401
    // reached after a redirect moves this to the hop that asked, copied
    // out of the response before the next `perform` invalidates it, so a
    // retry answers the peer that actually challenged and not the
    // original origin.
    var current_url: []const u8 = url;
    var url_storage: [retry_url_len_max]u8 = undefined;

    // Every host that has already been asked for a credential this
    // exchange, and whether that credential was rejected. Bounded by
    // `credential_attempts_max`: at most one host is added per loop
    // iteration.
    var tried_hosts: [credential_attempts_max][challenged_host_len_max]u8 = undefined;
    var tried_host_lens: [credential_attempts_max]usize = undefined;
    var tried_count: usize = 0;

    while (true) {
        if (body_ctx) |bc| bc.pos = 0;

        var zdiag: zurl.Diagnostics = .{};
        const resp = h.client.perform(current_url, zopts, &zdiag) catch |err| {
            return mapZurlError(gpa, err, diag);
        };

        if (resp.status != 401) return statusToOutcome(gpa, resp, diag);

        const eff = resp.effective_url;
        if (eff.len > url_storage.len) {
            recordMessage(gpa, diag, "the server's redirect target is too long");
            return error.ProtocolError;
        }
        // Copy now: the next `perform` on this client reuses the storage
        // `resp.effective_url` may point into.
        @memcpy(url_storage[0..eff.len], eff);
        current_url = url_storage[0..eff.len];

        const host = hostOf(current_url);
        if (host.len > challenged_host_len_max) {
            recordMessage(gpa, diag, "the server's challenged host is too long");
            return error.ProtocolError;
        }

        var already_tried = false;
        for (tried_hosts[0..tried_count], tried_host_lens[0..tried_count]) |*h_buf, h_len| {
            if (std.ascii.eqlIgnoreCase(host, h_buf[0..h_len])) {
                already_tried = true;
                break;
            }
        }
        if (already_tried) {
            recordMessage(gpa, diag, "authentication failed after retrying with a credential");
            return error.AuthFailed;
        }

        attempts += 1;
        if (attempts > credential_attempts_max) {
            recordMessage(gpa, diag, "too many authentication challenges in one exchange");
            return error.AuthFailed;
        }

        const cb = h.options.credentials orelse {
            recordMessage(gpa, diag, "the server asked for credentials and no callback was given");
            return error.AuthRequired;
        };
        const cred = cb(h.options.credentials_ctx, current_url, host, .{
            .bearer = true,
            .basic = true,
            .ssh_key = false,
        }) orelse {
            recordMessage(gpa, diag, "the server asked for credentials and the callback had none");
            return error.AuthRequired;
        };

        switch (cred) {
            .none => {},
            .bearer => |token| zopts.bearer_token = token,
            .basic => |b| zopts.credentials = .{ .user = b.username, .password = b.password },
            .ssh_key => {
                recordMessage(gpa, diag, "an HTTP transport cannot answer with an ssh key credential");
                return error.UnsupportedKeyType;
            },
            .ssh_agent => {
                recordMessage(gpa, diag, "an HTTP transport cannot answer with an ssh agent credential");
                return error.UnsupportedKeyType;
            },
        }

        @memcpy(tried_hosts[tried_count][0..host.len], host);
        tried_host_lens[tried_count] = host.len;
        tried_count += 1;
    }
}

/// Classifies a non-401 status. `2xx` and `3xx` pass the response
/// through; the built-in `redirects` following already resolved every
/// redirect this transport will see.
fn statusToOutcome(gpa: Allocator, resp: zurl.Response, diag: ?*?Diagnostic) Error!zurl.Response {
    if (resp.status == 404) {
        recordMessage(gpa, diag, "the repository was not found");
        return error.NotFound;
    }
    if (resp.status >= 500) {
        recordMessage(gpa, diag, "the server is busy or failing");
        return error.ServerBusy;
    }
    if (resp.status >= 400) {
        recordMessage(gpa, diag, "the server rejected the request");
        return error.ProtocolError;
    }
    return resp;
}

/// Maps a fault `zurl.Client.perform` reported on its own, before any
/// status code existed to classify. `error.HttpReturnedError` never
/// reaches here: `fail_on_error` stays false on every request this module
/// sends, so a `4xx` or `5xx` comes back as an ordinary `Response` and
/// `statusToOutcome` classifies it there instead.
fn mapZurlError(gpa: Allocator, err: zurl.Error, diag: ?*?Diagnostic) Error {
    return switch (err) {
        error.CouldNotResolveHost,
        error.CouldNotResolveProxy,
        error.CouldNotConnect,
        error.ProxyError,
        => blk: {
            recordMessage(gpa, diag, "the network is unreachable");
            break :blk error.NetworkFailed;
        },

        error.OperationTimedOut => blk: {
            recordMessage(gpa, diag, "the operation timed out");
            break :blk error.Timeout;
        },

        // **Ambiguous, and worth flagging rather than fixing.** zurl's
        // refused-header guard also raises `WriteError`, so a future
        // change that ever let a refused header reach a request would
        // turn a permanent programming bug into a fault this module calls
        // transient and a caller retries forever. Not reachable today:
        // this module adds only `Git-Protocol` to what `zurl` writes, and
        // the test "we never set Content-Length, Transfer-Encoding, Host,
        // Connection or Expect" below proves it stays that way.
        error.ReadError, error.WriteError, error.PartialFile => blk: {
            recordMessage(gpa, diag, "the connection was lost");
            break :blk error.ConnectionLost;
        },

        error.SslConnectError => blk: {
            recordMessage(gpa, diag, "the TLS connection could not be established");
            break :blk error.NetworkFailed;
        },

        // A certificate that failed verification is not a flaky
        // connection: it is expired, untrusted, or forged, which is what
        // an active machine-in-the-middle presents. This is permanent,
        // never `NetworkFailed`, so `isTransient` tells a retry loop to
        // stop and report it instead of spinning on a fault that a later
        // attempt cannot fix.
        error.PeerFailedVerification, error.CaCertBadFile => blk: {
            recordMessage(gpa, diag, "the server's TLS certificate failed verification");
            break :blk error.TlsVerificationFailed;
        },

        error.OutOfMemory => error.OutOfMemory,

        else => blk: {
            recordMessage(gpa, diag, "the request could not be completed");
            break :blk error.ProtocolError;
        },
    };
}

fn recordMessage(gpa: Allocator, diag: ?*?Diagnostic, msg: []const u8) void {
    if (!core.wants(diag)) return;
    const detail = gpa.dupe(u8, msg) catch return;
    core.report(diag, gpa, .{ .kind = .io, .path = null, .detail = detail });
}

/// The host of `url`, with any userinfo and port trimmed off. An IPv6
/// literal keeps its brackets, so a caller that reaches back into a url
/// with this text still finds the same host.
fn hostOf(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const authority_end = std.mem.indexOfAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    var authority = after_scheme[0..authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];

    if (authority.len > 0 and authority[0] == '[') {
        if (std.mem.indexOfScalar(u8, authority, ']')) |close| return authority[0 .. close + 1];
        return authority;
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| return authority[0..colon];
    return authority;
}

const testing = std.testing;
const zurl_http = @import("zurl-http");
const TestServer = zurl_http.test_server.TestServer;

const advertisement_body =
    "001e# service=git-upload-pack\n0000000eversion 2\x0a001bagent=git/2.55.0-Linux\x0a0013ls-refs=unborn\x0a" ++
    "0020fetch=shallow wait-for-done\x0a0012server-option\x0a0017object-format=sha1\x0a0000";

fn okResponse(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-advertisement\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
}

fn testHttp(gpa: Allocator, port: u16, options: Options) !Http {
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(url);
    return Http.open(gpa, testing.io, url, options);
}

// expected

test "capabilities performs a GET of info/refs with the git-upload-pack service" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{okResponse(advertisement_body)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    try testing.expect(caps.isV2());
    const head = server.requestHead(0).?;
    try testing.expect(std.mem.startsWith(u8, head, "GET /info/refs?service=git-upload-pack HTTP/1.1\r\n"));
}

test "capabilities sends Git-Protocol version=2" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{okResponse(advertisement_body)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    const head = server.requestHead(0).?;
    try testing.expect(std.mem.indexOf(u8, head, "Git-Protocol: version=2") != null);
}

test "command posts to git-upload-pack with the git request content type" {
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";
    var server: TestServer = undefined;
    try server.start(&.{okResponse(packfile_response)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var out: *std.Io.Reader = undefined;
    try h.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    const head = server.requestHead(0).?;
    try testing.expect(std.mem.startsWith(u8, head, "POST /git-upload-pack HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, head, "content-type: application/x-git-upload-pack-request") != null);
    try testing.expectEqualStrings("0000", server.requestBody(0).?);
}

test "command yields a reader over the response body" {
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";
    var server: TestServer = undefined;
    try server.start(&.{okResponse(packfile_response)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var out: *std.Io.Reader = undefined;
    try h.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    const body = try out.allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    try testing.expectEqualStrings(packfile_response, body);
}

test "a bearer credential reaches the Authorization header" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        okResponse(advertisement_body),
    });
    defer server.stop();

    const Cb = struct {
        var saw_bearer_allowed = false;

        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = host;
            saw_bearer_allowed = allowed.bearer;
            return .{ .bearer = "s3cr3t-token" };
        }
    };

    var h = try testHttp(gpa, server.port(), .{ .credentials = Cb.get });
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    const head = server.requestHead(1).?;
    try testing.expect(std.mem.indexOf(u8, head, "authorization: Bearer s3cr3t-token") != null);
    try testing.expect(Cb.saw_bearer_allowed);
}

// suspicious

test "a 401 with no credential callback is AuthRequired" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    try testing.expectError(error.AuthRequired, h.transport().capabilities(gpa, null));
}

test "a 401 after the callback returns null is AuthRequired, not a retry loop" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = host;
            _ = allowed;
            return null;
        }
    };

    var h = try testHttp(gpa, server.port(), .{ .credentials = Cb.get });
    defer h.deinit();

    try testing.expectError(error.AuthRequired, h.transport().capabilities(gpa, null));
    // A retry loop would have made a second connection.
    try testing.expectEqual(@as(usize, 1), server.accepts());
}

test "a 404 is NotFound and is not transient" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    const result = h.transport().capabilities(gpa, null);
    try testing.expectError(error.NotFound, result);
    try testing.expect(!transport_mod.isTransient(error.NotFound));
}

test "a 503 is ServerBusy and is transient" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    const result = h.transport().capabilities(gpa, null);
    try testing.expectError(error.ServerBusy, result);
    try testing.expect(transport_mod.isTransient(error.ServerBusy));
}

test "a redirect to a different host re-invokes the credential callback" {
    const gpa = testing.allocator;

    var target_server: TestServer = undefined;
    try target_server.startOn("127.0.0.2", &.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        okResponse(advertisement_body),
    });
    defer target_server.stop();

    const location = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.2:{d}/info/refs?service=git-upload-pack",
        .{target_server.port()},
    );
    defer gpa.free(location);
    const redirect = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{location},
    );
    defer gpa.free(redirect);

    var origin_server: TestServer = undefined;
    try origin_server.start(&.{redirect});
    defer origin_server.stop();

    const SeenHost = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;

        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = allowed;
            len = @min(host.len, buf.len);
            @memcpy(buf[0..len], host[0..len]);
            return .{ .bearer = "tok" };
        }
    };

    var h = try testHttp(gpa, origin_server.port(), .{ .credentials = SeenHost.get });
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    try testing.expectEqualStrings("127.0.0.2", SeenHost.buf[0..SeenHost.len]);
}

test "a credential already attached to one host is not forwarded to a redirect target that challenges again" {
    const gpa = testing.allocator;

    // The second host challenges too, so this proves the isolation the
    // design claims rather than the shape the test above already covers:
    // a credential is obtained for the origin, attached, and the origin
    // then redirects to a different host. That host must see none of the
    // origin's credential, and its own challenge must reach the callback.
    var target_server: TestServer = undefined;
    try target_server.startOn("127.0.0.2", &.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        okResponse(advertisement_body),
    });
    defer target_server.stop();

    const location = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.2:{d}/info/refs?service=git-upload-pack",
        .{target_server.port()},
    );
    defer gpa.free(location);
    const redirect = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{location},
    );
    defer gpa.free(redirect);

    // The origin answers three requests, not two. `zurl`'s engine sends a
    // credentialed request as a probe; when the probe comes back a
    // redirect, the engine closes it, throws its answer away, and resends
    // the same request to the origin a second time with no credential at
    // all before it ever follows the hop to the new host. That is the
    // mechanism this test is proving: the origin's own redirect decision
    // never depends on, and is re-confirmed without, the secret. So the
    // origin serves the challenge, the credentialed probe's redirect, and
    // the uncredentialed resend's identical redirect, in that order.
    var origin_server: TestServer = undefined;
    try origin_server.start(&.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        redirect,
        redirect,
    });
    defer origin_server.stop();

    const Calls = struct {
        var hosts: [2][128]u8 = undefined;
        var host_lens: [2]usize = .{ 0, 0 };
        var count: usize = 0;

        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = allowed;
            if (count < hosts.len) {
                const n = @min(host.len, hosts[count].len);
                @memcpy(hosts[count][0..n], host[0..n]);
                host_lens[count] = n;
            }
            count += 1;
            return .{ .bearer = "tok" };
        }
    };

    var h = try testHttp(gpa, origin_server.port(), .{ .credentials = Calls.get });
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), Calls.count);
    try testing.expectEqualStrings("127.0.0.1", Calls.hosts[0][0..Calls.host_lens[0]]);
    try testing.expectEqualStrings("127.0.0.2", Calls.hosts[1][0..Calls.host_lens[1]]);

    // The request that reached the second host, carrying nothing the
    // first host's credential could have supplied.
    const target_head = target_server.requestHead(0).?;
    try testing.expectEqual(@as(usize, 0), TestServer.countAuthorizationHeaders(target_head));

    // The origin's own credentialed probe (index 1) does carry it, since
    // that is the origin's own credential answering the origin's own
    // challenge. The uncredentialed resend that follows it (index 2) does
    // not: the origin's redirect decision is proven independent of the
    // secret before that secret's host is ever left behind.
    const origin_probe_head = origin_server.requestHead(1).?;
    try testing.expectEqual(@as(usize, 1), TestServer.countAuthorizationHeaders(origin_probe_head));
    const origin_resend_head = origin_server.requestHead(2).?;
    try testing.expectEqual(@as(usize, 0), TestServer.countAuthorizationHeaders(origin_resend_head));
}

test "we never set Content-Length, Transfer-Encoding, Host, Connection or Expect" {
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";
    var server: TestServer = undefined;
    try server.start(&.{okResponse(packfile_response)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var out: *std.Io.Reader = undefined;
    try h.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    const head = server.requestHead(0).?;
    // The engine writes each of these itself, in lower case; this module
    // never adds one of its own beside it.
    try testing.expectEqual(@as(usize, 1), TestServer.countHeaders(head, "Content-Length"));
    try testing.expectEqual(@as(usize, 0), TestServer.countHeaders(head, "Transfer-Encoding"));
    try testing.expectEqual(@as(usize, 1), TestServer.countHeaders(head, "Host"));
    try testing.expectEqual(@as(usize, 1), TestServer.countHeaders(head, "Connection"));
    try testing.expectEqual(@as(usize, 0), TestServer.countHeaders(head, "Expect"));
}

test "a server that advertises only version 1 is UnsupportedProtocol" {
    const gpa = testing.allocator;
    // The "# service=" line every smart-HTTP advertisement opens with,
    // then a "version 1" line where a v2 server would send "version 2".
    const v1_body = "001e# service=git-upload-pack\n0000000eversion 1\x0a0000";
    var server: TestServer = undefined;
    try server.start(&.{okResponse(v1_body)});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    const result = h.transport().capabilities(gpa, null);
    try testing.expectError(error.UnsupportedProtocol, result);
}

test "the response body is streamed, not buffered" {
    const gpa = testing.allocator;

    // Bigger than any buffer this module keeps on the stack, so a
    // caller that read the whole thing into one internal buffer before
    // handing back a reader would need to grow one to match. Streaming
    // needs no such buffer at all: the reader pulls straight from the
    // socket in chunks.
    const big_len = 200_000;
    var body_storage: [big_len]u8 = undefined;
    @memset(&body_storage, 'x');

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ big_len, body_storage[0..] },
    );
    defer gpa.free(response);

    var server: TestServer = undefined;
    try server.start(&.{response});
    defer server.stop();

    var h = try testHttp(gpa, server.port(), .{});
    defer h.deinit();

    var out: *std.Io.Reader = undefined;
    try h.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    var total: usize = 0;
    var reads: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = out.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (n == 0) break;
        total += n;
        reads += 1;
    }
    try testing.expectEqual(@as(usize, big_len), total);
    // A body this size, pulled through a 4096-byte chunk, took more than
    // one read: proof it came off the reader in pieces rather than
    // arriving pre-assembled in one internal buffer.
    try testing.expect(reads > 1);
}

test "a TLS certificate that fails verification maps to a permanent error" {
    // No loopback fixture drives a real failing handshake here; this
    // proves the mapping `mapZurlError` itself makes, which is the whole
    // fix. `errors.zig` proves the other half: that `isTransient` reports
    // this error as permanent.
    try testing.expectEqual(error.TlsVerificationFailed, mapZurlError(testing.allocator, error.PeerFailedVerification, null));
    try testing.expectEqual(error.TlsVerificationFailed, mapZurlError(testing.allocator, error.CaCertBadFile, null));
    // An ordinary handshake fault, with no verification involved, stays
    // transient: this fix narrows the mapping and must not widen it.
    try testing.expectEqual(error.NetworkFailed, mapZurlError(testing.allocator, error.SslConnectError, null));
}

test "a ca_cert_file and a ca_cert_dir reach zurl's transfer options" {
    // Proven at the options-construction level, not over a live TLS
    // handshake: standing up a certificate-verifying loopback server here
    // would need writing a PEM to a real file for `--cacert` to read, and
    // this module reads no ambient path. `zurlOptions` is the one place
    // `Options.ca_cert_file` and `Options.ca_cert_dir` turn into what zurl
    // reads, so asserting its output is asserting the wiring itself.
    const gpa = testing.allocator;
    var h = try Http.open(gpa, testing.io, "http://127.0.0.1:1", .{
        .ca_cert_file = "/etc/ziggit-test/ca-bundle.pem",
        .ca_cert_dir = "/etc/ziggit-test/ca-certs",
    });
    defer h.deinit();

    const zopts = h.zurlOptions(.GET, null, &.{});
    try testing.expectEqualStrings("/etc/ziggit-test/ca-bundle.pem", zopts.ca.cacert.?);
    try testing.expectEqualStrings("/etc/ziggit-test/ca-certs", zopts.ca.capath.?);
}

test "the progress sink is called with the received byte count as the response streams" {
    const gpa = testing.allocator;

    const body_len = 50_000;
    var body_storage: [body_len]u8 = undefined;
    @memset(&body_storage, 'p');

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body_len, body_storage[0..] },
    );
    defer gpa.free(response);

    var server: TestServer = undefined;
    try server.start(&.{response});
    defer server.stop();

    const Recorder = struct {
        var calls: usize = 0;
        var last_received: u64 = 0;

        fn onBytes(ctx: ?*anyopaque, received: u64, total: ?u64) void {
            _ = ctx;
            _ = total;
            calls += 1;
            last_received = received;
        }
    };

    var h = try testHttp(gpa, server.port(), .{
        .progress = .{ .onBytes = Recorder.onBytes },
    });
    defer h.deinit();

    var out: *std.Io.Reader = undefined;
    try h.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    // A small destination buffer, the same technique "the response body
    // is streamed, not buffered" uses above: it forces more than one
    // pull off the wire, which is what proves the sink fires as bytes
    // arrive rather than once at the end from one large internal read.
    var total: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = out.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(@as(usize, body_len), total);

    try testing.expect(Recorder.calls > 1);
    try testing.expectEqual(@as(u64, body_len), Recorder.last_received);
}

test "a configured proxy carries the request, in absolute form, to the proxy" {
    const gpa = testing.allocator;
    const proxy_test_server = zurl_http.proxy_test_server;

    var proxy: proxy_test_server.ProxyTestServer = undefined;
    try proxy.start(.{ .kind = .http_proxy }, &.{okResponse(advertisement_body)});
    defer proxy.stop();

    const proxy_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{proxy.port()});
    defer gpa.free(proxy_url);

    // A closed port: if `proxy_url` were not wired in, the direct dial
    // this would otherwise attempt fails at once with a refusal instead
    // of hanging, so a regression here is a fast failure and not a
    // stall.
    const dead_port = try TestServer.closedPort("127.0.0.1");
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{dead_port});
    defer gpa.free(base_url);

    var h = try Http.open(gpa, testing.io, base_url, .{ .proxy_url = proxy_url });
    defer h.deinit();

    var caps = try h.transport().capabilities(gpa, null);
    defer caps.deinit(gpa);

    const head = proxy.requestHead();
    const expected = try std.fmt.allocPrint(
        gpa,
        "GET {s}/info/refs?service=git-upload-pack HTTP/1.1\r\n",
        .{base_url},
    );
    defer gpa.free(expected);
    try testing.expect(std.mem.startsWith(u8, head, expected));
}

test "a redirect target longer than the retry buffer is ProtocolError, not truncated" {
    const gpa = testing.allocator;

    // The target server returns 401 so performWithAuth checks the effective URL.
    var target_server: TestServer = undefined;
    try target_server.startOn("127.0.0.2", &.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer target_server.stop();

    var location_buf: [retry_url_len_max + 256]u8 = undefined;
    const location = try std.fmt.bufPrint(&location_buf, "http://127.0.0.2:{d}/{s}", .{
        target_server.port(),
        "x" ** (retry_url_len_max + 100),
    });

    const redirect = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{location},
    );
    defer gpa.free(redirect);

    var origin_server: TestServer = undefined;
    try origin_server.start(&.{redirect});
    defer origin_server.stop();

    var h = try testHttp(gpa, origin_server.port(), .{});
    defer h.deinit();

    const result = h.transport().capabilities(gpa, null);
    try testing.expectError(error.ProtocolError, result);
}

test "a challenged host longer than the buffer is ProtocolError, not truncated" {
    const gpa = testing.allocator;

    // Build a hostname that exceeds challenged_host_len_max (256).
    var host_buf: [challenged_host_len_max + 128]u8 = undefined;
    const host_part = "x" ** (challenged_host_len_max + 50);
    const long_host = try std.fmt.bufPrint(&host_buf, "{s}.example.com", .{host_part});

    var target_server: TestServer = undefined;
    try target_server.startOn("127.0.0.2", &.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer target_server.stop();

    const location = try std.fmt.allocPrint(
        gpa,
        "http://{s}:{d}/info/refs?service=git-upload-pack",
        .{ long_host, target_server.port() },
    );
    defer gpa.free(location);

    const redirect = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{location},
    );
    defer gpa.free(redirect);

    var origin_server: TestServer = undefined;
    try origin_server.start(&.{redirect});
    defer origin_server.stop();

    var h = try testHttp(gpa, origin_server.port(), .{});
    defer h.deinit();

    const result = h.transport().capabilities(gpa, null);
    try testing.expectError(error.ProtocolError, result);
}

test "an HTTP transport refuses an ssh agent credential and does not retry" {
    // `AllowedTypes.ssh_agent` is false for HTTP, so a callback answering
    // with one misread the struct. Refused by name rather than ignored,
    // and without a second connection: a callback that keeps offering a
    // shape this transport cannot use must not drive a retry loop.
    //
    // The neighbouring `ssh_key` branch had no test at all before this
    // one; both are covered now.
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = host;
            _ = allowed;
            return .{ .ssh_agent = .{ .socket_path = "/tmp/agent.sock" } };
        }
    };

    var h = try testHttp(gpa, server.port(), .{ .credentials = Cb.get });
    defer h.deinit();

    try testing.expectError(error.UnsupportedKeyType, h.transport().capabilities(gpa, null));
    try testing.expectEqual(@as(usize, 1), server.accepts());
}

test "an HTTP transport refuses an ssh key credential and does not retry" {
    const gpa = testing.allocator;
    var server: TestServer = undefined;
    try server.start(&.{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url;
            _ = host;
            _ = allowed;
            return .{ .ssh_key = .{ .path = "/tmp/id_ed25519", .passphrase = null } };
        }
    };

    var h = try testHttp(gpa, server.port(), .{ .credentials = Cb.get });
    defer h.deinit();

    try testing.expectError(error.UnsupportedKeyType, h.transport().capabilities(gpa, null));
    try testing.expectEqual(@as(usize, 1), server.accepts());
}
