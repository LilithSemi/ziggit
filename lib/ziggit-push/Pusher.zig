//! One push over a `Transport`: read the advertisement, send the commands
//! and the pack, read the report.
//!
//! The transport must have been opened for `.receive_pack`. Opening it for
//! the wrong service reaches the remote's upload-pack instead, which
//! answers an advertisement this cannot read.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const pktline_mod = @import("ziggit-pktline");
const transport_mod = @import("ziggit-transport");
const Transport = transport_mod.Transport;

const protocol_mod = @import("protocol.zig");
const Advertisement = protocol_mod.Advertisement;
const Report = protocol_mod.Report;

const send_mod = @import("send.zig");
const Update = send_mod.Update;

pub const Error = send_mod.Error || protocol_mod.Error || transport_mod.Error;

/// Pushes `updates` and answers with the remote's report, which the caller
/// owns and must `deinit`.
///
/// A report that comes back is not a success: `Report.ok` is what says the
/// pack landed and every ref moved. `error.LeaseNotHeld` means this
/// refused the push before sending anything, because the advertisement
/// disagreed with the expected old value.
///
/// The request is built in memory before it is sent. Smart HTTP needs the
/// body's length up front, so there is no streaming shape that serves all
/// three transports, and an initial push of a long history costs its own
/// pack in memory.
pub fn push(
    gpa: Allocator,
    odb: *Odb,
    f: Format,
    t: Transport,
    updates: []const Update,
    diag: ?*?Diagnostic,
) Error!Report {
    const pktbuf = try gpa.alloc(u8, pktline_mod.Packet.max_data_length);
    defer gpa.free(pktbuf);

    var adv_reader: *std.Io.Reader = undefined;
    try t.advertiseRefs(gpa, &adv_reader, diag);
    var adv = try protocol_mod.readAdvertisement(gpa, f, adv_reader, pktbuf);
    defer adv.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    _ = try send_mod.writeRequest(gpa, odb, f, adv, updates, &body.writer, diag);

    var reply: *std.Io.Reader = undefined;
    try t.command(gpa, .{ .name = "receive-pack", .body = body.written() }, &reply, diag);

    return protocol_mod.readReport(gpa, reply, pktbuf);
}
