//! `sideband-64k` demultiplexing: once a `fetch` response reaches its
//! `packfile` section, every remaining pkt-line carries a one byte band
//! number ahead of its payload. Band 1 is pack data, band 2 is progress
//! text meant for a human, band 3 is a fatal message from the server.

const std = @import("std");

const pktline_mod = @import("ziggit-pktline");

pub const Sideband = struct {
    pub const Error = error{ ProtocolError, RemoteError } || pktline_mod.ReadError;

    pub const ProgressSink = struct {
        ctx: ?*anyopaque = null,
        /// Receives band 2 text. Must not block and must not allocate.
        onText: *const fn (ctx: ?*anyopaque, text: []const u8) void,
    };

    /// The pkt-line stream to demultiplex.
    src: *std.Io.Reader,
    /// Scratch space for `pktline.read`. Must be at least
    /// `pktline.Packet.max_data_length` bytes, the same requirement
    /// `pktline.read` itself has.
    pktbuf: []u8,
    progress: ?ProgressSink,
    /// The band 1 reader exposed through `reader()`.
    interface: std.Io.Reader,
    /// Bytes already read out of the current band 1 packet but not yet
    /// handed to a caller, because a `limit` smaller than the packet cut
    /// the last `stream` call short. Borrowed from `pktbuf`; valid because
    /// nothing reads a new packet into `pktbuf` while this is non-empty.
    leftover: []const u8,
    /// The band 3 text from the last read, when the last read ended the
    /// stream with a remote error. Borrowed from `pktbuf`, valid until the
    /// next read.
    diag: ?[]const u8,
    state: enum { streaming, eof, failed },

    /// `std.Io.Reader`'s vtable fixes the error set a `stream` callback may
    /// return to `{ReadFailed, WriteFailed, EndOfStream}`; there is no way
    /// for a byte read through `reader()` to literally carry
    /// `error.RemoteError` or `error.ProtocolError`. Both conditions
    /// surface as `error.ReadFailed` instead, with `remoteError()` as the
    /// side channel that says which one it was and what the server said,
    /// the same shape `ziggit-core.Diagnostic` uses for "a generic error,
    /// plus detail fetched separately".
    pub fn init(r: *std.Io.Reader, buf: []u8, progress: ?ProgressSink) Sideband {
        return .{
            .src = r,
            .pktbuf = buf,
            .progress = progress,
            .interface = .{
                .vtable = &.{ .stream = stream },
                // This reader holds no buffer of its own: every byte it
                // hands out already lives in `pktbuf`, reached through
                // `leftover`, or is written straight into the caller's
                // destination by `stream`. A caller must read it with
                // `readSliceAll`/`streamRemaining`-style calls, not
                // `peek`/`takeByte`, which need buffer capacity this
                // reader does not have.
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .leftover = &.{},
            .diag = null,
            .state = .streaming,
        };
    }

    /// Band 1 only. A band 3 message ends the stream with
    /// `error.ReadFailed`; `remoteError()` afterward holds the server's
    /// text.
    pub fn reader(s: *Sideband) *std.Io.Reader {
        return &s.interface;
    }

    /// The band 3 text, valid until the next read. Null unless the last
    /// read returned `error.RemoteError` (in practice, `error.ReadFailed`
    /// from `reader()`; see `init`'s doc comment).
    pub fn remoteError(s: *const Sideband) ?[]const u8 {
        return s.diag;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *Sideband = @fieldParentPtr("interface", r);

        if (s.leftover.len > 0) {
            const chunk = limit.sliceConst(s.leftover);
            try w.writeAll(chunk);
            s.leftover = s.leftover[chunk.len..];
            return chunk.len;
        }

        switch (s.state) {
            .eof => return error.EndOfStream,
            .failed => return error.ReadFailed,
            .streaming => {},
        }

        while (true) {
            const packet = pktline_mod.read(s.src, s.pktbuf) catch {
                // A torn packet must never look like a clean end of
                // stream: a caller that stops on `error.EndOfStream` would
                // otherwise treat a truncated packfile as a complete one.
                s.state = .failed;
                return error.ReadFailed;
            };
            switch (packet) {
                .flush => {
                    s.state = .eof;
                    return error.EndOfStream;
                },
                .delimiter, .response_end => {
                    s.state = .failed;
                    return error.ReadFailed;
                },
                .data => |data| {
                    if (data.len == 0) {
                        s.state = .failed;
                        return error.ReadFailed;
                    }
                    const band = data[0];
                    const payload = data[1..];
                    switch (band) {
                        1 => {
                            if (payload.len == 0) continue;
                            const chunk = limit.sliceConst(payload);
                            try w.writeAll(chunk);
                            if (chunk.len < payload.len) s.leftover = payload[chunk.len..];
                            return chunk.len;
                        },
                        2 => {
                            if (s.progress) |p| p.onText(p.ctx, payload);
                            continue;
                        },
                        3 => {
                            s.diag = payload;
                            s.state = .failed;
                            return error.ReadFailed;
                        },
                        else => {
                            // A band number git never assigns: reject
                            // instead of guessing what it means.
                            s.state = .failed;
                            return error.ReadFailed;
                        },
                    }
                },
            }
        }
    }
};

// Byte-exact vectors, captured from real git 2.55.0's response to a
// `command=fetch` request (see fetch.zig's vector comment for the exact
// request bytes), by extracting individual pkt-lines from the response
// with a small script that parses pkt-line framing and prints one packet's
// raw bytes by index.
//
// `band3_error_packet_vector` needed a genuine server-side failure to
// trigger: the repository's blob for a second commit was deleted from
// `.git/objects` before the fetch request ran, so `git-pack-objects` died
// partway through building the pack and upload-pack reported that failure
// over sideband band 3 instead of finishing the packfile section.
const band2_progress_packet_vector =
    "0081\x02Enumerating objects: 2, done.\x0aCounting objects:  50% (1/2)\x0dCounting objects: 1" ++
    "00% (2/2)\x0dCounting objects: 100% (2/2), done.\x0a";
// length: 129 bytes

const band1_pack_packet_vector =
    "008d\x01PACK\x00\x00\x00\x02\x00\x00\x00\x02\x96\x07x\x9c}\xca\xc1\x0d\x80 \x0c\x00\xc0?St" ++
    "\x01\x93\x8a\xa5\x94\xc4\x18W\xa1X\xa3\x0f$!\xb8\xbf\x1bx\xef\x1b\xdd\x0cH\xc5\x87\xa30\xf9" ++
    "\xa2l\x9a22Z =\xe5\xe0\xe4EN5\xa3\x84\xe4\xf2;\xae\xd6!\xc3\x9aw\xdd`\x8e\x92B\x5c<G\x980" ++
    "\x22\xba\xd2j\xbd\xc7\xb0\x9f\xe2\xdac\xee\x03\xc3Z\x1f\xae x\x9c\x03\x00\x00\x00\x00\x01 " ++
    "\xdc-\xa8\xeb\xf3\xda\x18\x17x\x99\xcad\x08\x89\x11BY\xb8";
// length: 141 bytes

const band3_error_packet_vector =
    "0047\x03aborting due to possible repository corruption on the remote side.";
// length: 71 bytes

const packfile_pack_bytes = band1_pack_packet_vector[5..];
const band2_progress_text = band2_progress_packet_vector[5..];

// expected

test "Sideband yields band one as pack data" {
    var r: std.Io.Reader = .fixed(band1_pack_packet_vector ++ "0000");
    var pktbuf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var sb = Sideband.init(&r, &pktbuf, null);

    var out: [packfile_pack_bytes.len]u8 = undefined;
    try sb.reader().readSliceAll(&out);
    try std.testing.expectEqualSlices(u8, packfile_pack_bytes, &out);
    try std.testing.expectError(error.EndOfStream, sb.reader().readSliceAll(out[0..1]));
}

test "Sideband calls the progress sink with band two text" {
    const State = struct {
        calls: usize = 0,
        last: [256]u8 = undefined,
        last_len: usize = 0,
    };

    const Handler = struct {
        fn onText(ctx: ?*anyopaque, text: []const u8) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.calls += 1;
            s.last_len = text.len;
            @memcpy(s.last[0..text.len], text);
        }
    };

    var state: State = .{};

    var r: std.Io.Reader = .fixed(band2_progress_packet_vector ++ "0000");
    var pktbuf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var sb = Sideband.init(&r, &pktbuf, .{ .onText = Handler.onText, .ctx = &state });

    var out: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sb.reader().readSliceAll(&out));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqualStrings(band2_progress_text, state.last[0..state.last_len]);
}

// suspicious

test "Sideband turns a band three message into RemoteError" {
    var r: std.Io.Reader = .fixed(band3_error_packet_vector);
    var pktbuf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var sb = Sideband.init(&r, &pktbuf, null);

    var out: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, sb.reader().readSliceAll(&out));
    try std.testing.expectEqualStrings(
        "aborting due to possible repository corruption on the remote side.",
        sb.remoteError().?,
    );
}

test "Sideband rejects a band number that is not 1, 2 or 3" {
    var r: std.Io.Reader = .fixed("0005\x040000");
    var pktbuf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var sb = Sideband.init(&r, &pktbuf, null);

    var out: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, sb.reader().readSliceAll(&out));
}

test "a truncated response is UnexpectedEndOfStream, not a partial success" {
    // "008d" declares a 137 byte payload but only a few bytes of it
    // actually arrive: the stream cuts off mid packet, the way a dropped
    // connection would. A caller reading via `Sideband` must see a hard
    // failure here, not a clean end of stream that looks like the pack
    // simply finished early.
    var r: std.Io.Reader = .fixed("008d\x01PACK");
    var pktbuf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    var sb = Sideband.init(&r, &pktbuf, null);

    var out: [4]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, sb.reader().readSliceAll(&out));
}
