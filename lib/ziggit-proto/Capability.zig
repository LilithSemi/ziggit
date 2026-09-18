//! The capability advertisement: git's `version 2` line, then zero or more
//! `key[=value]` lines, ending at a flush pkt-line. A v2 server sends this
//! before it will run any command.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;

const pktline_mod = @import("ziggit-pktline");

/// One advertised capability. A bare capability such as `server-option` has
/// no value.
pub const Capability = struct {
    key: []const u8, // owned by the Capabilities holding it, freed by Capabilities.deinit
    value: ?[]const u8, // owned by the Capabilities holding it, freed by Capabilities.deinit
};

pub const Capabilities = struct {
    entries: []const Capability, // owned by this Capabilities, freed by deinit

    pub fn deinit(c: *Capabilities, gpa: Allocator) void {
        freeEntries(gpa, c.entries);
        gpa.free(c.entries);
        c.* = undefined;
    }

    pub fn has(c: Capabilities, key: []const u8) bool {
        for (c.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return true;
        }
        return false;
    }

    pub fn get(c: Capabilities, key: []const u8) ?[]const u8 {
        for (c.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    /// The object format the server declared. Absent means sha1.
    pub fn objectFormat(c: Capabilities) Format {
        const value = c.get("object-format") orelse return .sha1;
        // `parseCapabilities` already refused any spelling `Format` does
        // not know, so a `Capabilities` built by it never reaches here
        // holding one.
        return Format.fromName(value) orelse .sha1;
    }

    /// True when the server advertised "version 2".
    pub fn isV2(c: Capabilities) bool {
        const value = c.get("version") orelse return false;
        return std.mem.eql(u8, value, "2");
    }
};

pub const ParseError = error{ ProtocolError, UnsupportedProtocol } || Allocator.Error;

/// `parseCapabilities` alone can answer `RemoteRefused`, so it carries its
/// own set. Putting it in `ParseError` widened every other reader in this
/// module with an error none of them can produce, which a caller then has
/// to handle or explicitly rule out for no reason.
pub const CapabilityError = ParseError || error{RemoteRefused};

/// Reads one capability advertisement from `r`: the leading `version 2`
/// line, then every `key[=value]` line up to the flush pkt-line that ends
/// it.
///
/// A first line other than exactly `version 2` is `error.UnsupportedProtocol`:
/// this module speaks v2 only, and a v1 or v0 server is refused rather than
/// downgraded to. An `object-format` value this module does not implement
/// is the same error, never a silent guess at sha1.
/// `remote_message` receives the server's own text when it answers with an
/// `ERR` line, and is left alone otherwise. The caller owns what lands
/// there and must free it. It is an out-parameter rather than a
/// `Diagnostic` because this module deliberately imports no error
/// taxonomy; each transport decides how to report what it is handed.
pub fn parseCapabilities(gpa: Allocator, r: *std.Io.Reader, buf: []u8, remote_message: *?[]u8) CapabilityError!Capabilities {
    var entries: std.ArrayList(Capability) = .empty;
    errdefer {
        freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }

    const first_line = try readLine(r, buf);

    // A server that refuses the request answers with one `ERR <message>`
    // pkt-line instead of an advertisement, and the message is the whole
    // point of it: the git daemon says "access denied or repository not
    // exported" for a repository that is not there, and git prints that
    // text as "remote error: ...".
    //
    // Without this, every such refusal parses as "the first line is not
    // `version 2`" and is reported as `UnsupportedProtocol`, which tells a
    // reader their server is too old when the truth is they named a
    // repository that does not exist. All three transports shared that
    // fault, because all three land here.
    if (std.mem.startsWith(u8, first_line, "ERR ")) {
        remote_message.* = try gpa.dupe(u8, first_line["ERR ".len..]);
        return error.RemoteRefused;
    }

    if (!std.mem.eql(u8, first_line, "version 2")) return error.UnsupportedProtocol;
    try entries.append(gpa, .{
        .key = try gpa.dupe(u8, "version"),
        .value = try gpa.dupe(u8, "2"),
    });

    while (true) {
        const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
        switch (packet) {
            .flush => break,
            .delimiter, .response_end => return error.ProtocolError,
            .data => |data| {
                const line = trimNewline(data);
                if (line.len == 0) return error.ProtocolError;

                const eq = std.mem.indexOfScalar(u8, line, '=');
                const key_src = if (eq) |i| line[0..i] else line;
                const value_src = if (eq) |i| line[i + 1 ..] else null;
                if (key_src.len == 0) return error.ProtocolError;

                const key = try gpa.dupe(u8, key_src);
                errdefer gpa.free(key);
                const value = if (value_src) |v| try gpa.dupe(u8, v) else null;
                errdefer if (value) |v| gpa.free(v);

                try entries.append(gpa, .{ .key = key, .value = value });
            },
        }
    }

    for (entries.items) |e| {
        if (!std.mem.eql(u8, e.key, "object-format")) continue;
        const v = e.value orelse return error.ProtocolError;
        if (Format.fromName(v) == null) return error.UnsupportedProtocol;
    }

    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

fn freeEntries(gpa: Allocator, entries: []const Capability) void {
    for (entries) |e| {
        gpa.free(e.key);
        if (e.value) |v| gpa.free(v);
    }
}

/// Reads one pkt-line and trims its trailing newline. Used for the leading
/// `version 2` line, which is read before anything is known about the
/// stream, so its own errors are not yet worth distinguishing.
fn readLine(r: *std.Io.Reader, buf: []u8) ParseError![]const u8 {
    const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
    return trimNewline(switch (packet) {
        .data => |d| d,
        .flush, .delimiter, .response_end => return error.ProtocolError,
    });
}

fn trimNewline(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\n') return line[0 .. line.len - 1];
    return line;
}

/// Every pkt-line fault, truncation included, becomes `error.ProtocolError`
/// here: `ParseError` carries no lower-level read error, by design, so a
/// server that cuts the advertisement short is reported the same way as one
/// that sends nonsense.
fn mapReadError(_: pktline_mod.ReadError) ParseError {
    return error.ProtocolError;
}

// Byte-exact vectors, captured from real git 2.55.0 with:
//   mkdir -p /tmp/protovec && cd /tmp/protovec
//   git init -q r && cd r
//   git -c user.email=a@b -c user.name=a commit -q --allow-empty -m one
//   GIT_PROTOCOL=version=2 git upload-pack --advertise-refs . > advertise.raw
//
// and, in a second repository created with `git init -q --object-format=sha256 .`:
//   GIT_PROTOCOL=version=2 git upload-pack --advertise-refs . > advertise_sha256.raw
const advertisement_vector =
    "000eversion 2\x0a001bagent=git/2.55.0-Linux\x0a0013ls-refs=unborn\x0a0020fetch=shallow wait-" ++
    "for-done\x0a0012server-option\x0a0017object-format=sha1\x0a0000";
// length: 137 bytes

const advertisement_sha256_vector =
    "000eversion 2\x0a001bagent=git/2.55.0-Linux\x0a0013ls-refs=unborn\x0a0020fetch=shallow wait-" ++
    "for-done\x0a0012server-option\x0a0019object-format=sha256\x0a0000";
// length: 139 bytes

// expected

test "parseCapabilities reads version 2 and the agent string" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(advertisement_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    var caps = try parseCapabilities(gpa, &r, &buf, &msg);
    defer caps.deinit(gpa);

    try std.testing.expect(caps.isV2());
    try std.testing.expectEqualStrings("git/2.55.0-Linux", caps.get("agent").?);
    try std.testing.expect(caps.has("ls-refs"));
    try std.testing.expect(caps.has("fetch"));
    try std.testing.expect(caps.has("server-option"));
    try std.testing.expect(caps.get("server-option") == null);
}

test "parseCapabilities reads object-format sha256" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(advertisement_sha256_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    var caps = try parseCapabilities(gpa, &r, &buf, &msg);
    defer caps.deinit(gpa);

    try std.testing.expectEqual(Format.sha256, caps.objectFormat());
}

test "objectFormat defaults to sha1 when the server does not say" {
    const gpa = std.testing.allocator;
    // A minimal, hand-built stream: only the mandatory "version 2" line and
    // no `object-format` capability at all. This is ordinary grammar
    // fixture, not a captured vector: nothing here claims to be what a
    // real server sends, only what a bare-minimum one is allowed to.
    var r: std.Io.Reader = .fixed("000eversion 2\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    var caps = try parseCapabilities(gpa, &r, &buf, &msg);
    defer caps.deinit(gpa);

    try std.testing.expectEqual(Format.sha1, caps.objectFormat());
}

// suspicious

test "parseCapabilities refuses a server that advertises only version 1" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("000eversion 1\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    try std.testing.expectError(error.UnsupportedProtocol, parseCapabilities(gpa, &r, &buf, &msg));
}

test "parseCapabilities refuses an object-format we do not implement" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("000eversion 2\n001bobject-format=sha3-256\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    try std.testing.expectError(error.UnsupportedProtocol, parseCapabilities(gpa, &r, &buf, &msg));
}

test "a server that answers ERR is refused by name, carrying its own message" {
    // Captured from a real git daemon asked for a repository it does not
    // export: it sends one `ERR <message>` pkt-line in place of an
    // advertisement, and git prints that text as "remote error: ...".
    //
    // Before this, the line parsed as "the first line is not version 2" and
    // every transport reported UnsupportedProtocol, telling a reader their
    // server was too old when they had simply named a repository that is
    // not there.
    const gpa = std.testing.allocator;
    const vector = "003eERR access denied or repository not exported: /missing.git";
    var r: std.Io.Reader = .fixed(vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    try std.testing.expectError(
        error.RemoteRefused,
        parseCapabilities(gpa, &r, &buf, &msg),
    );
    try std.testing.expectEqualStrings(
        "access denied or repository not exported: /missing.git",
        msg.?,
    );
}

test "an advertisement leaves the remote message untouched" {
    // The other side of the bound: a normal advertisement must not set the
    // out-parameter, or a caller would free something it never received.
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(advertisement_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var msg: ?[]u8 = null;
    defer if (msg) |m| gpa.free(m);

    var caps = try parseCapabilities(gpa, &r, &buf, &msg);
    defer caps.deinit(gpa);
    try std.testing.expect(msg == null);
}
