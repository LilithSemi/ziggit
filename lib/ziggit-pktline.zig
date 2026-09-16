//! The pkt-line codec: git's wire protocol framing.
//!
//! A pkt-line is a 4-character lowercase hex length header followed by that
//! many bytes TOTAL, including the header. Three special lengths carry no
//! payload: 0000 is flush, 0001 is delimiter, 0002 is response-end.
//! Length 0003 is reserved and invalid. Length 0004 is a legal empty data
//! packet, distinct from flush.

const packet_mod = @import("ziggit-pktline/Packet.zig");
pub const Packet = packet_mod.Packet;

const reader_mod = @import("ziggit-pktline/reader.zig");
pub const read = reader_mod.read;
pub const ReadError = reader_mod.ReadError;

const writer_mod = @import("ziggit-pktline/writer.zig");
pub const write = writer_mod.write;
pub const writeLine = writer_mod.writeLine;
pub const WriteError = writer_mod.WriteError;

test {
    _ = packet_mod;
    _ = reader_mod;
    _ = writer_mod;
}
