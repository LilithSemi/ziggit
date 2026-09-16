//! Writing pkt-line packets to a stream.

const std = @import("std");
const Packet = @import("Packet.zig").Packet;

pub const WriteError = std.Io.Writer.Error || error{PktLineTooLong};

/// Writes a packet to the stream. Data packets are rejected if oversized.
/// Special packets (flush, delimiter, response_end) carry no payload.
pub fn write(w: *std.Io.Writer, packet: Packet) WriteError!void {
    switch (packet) {
        .flush => {
            try w.writeAll("0000");
        },
        .delimiter => {
            try w.writeAll("0001");
        },
        .response_end => {
            try w.writeAll("0002");
        },
        .data => |data| {
            const total_length = std.math.add(usize, data.len, 4) catch {
                return error.PktLineTooLong;
            };
            if (total_length > 65520) {
                return error.PktLineTooLong;
            }
            var header: [4]u8 = undefined;
            formatLength(total_length, &header);
            try w.writeAll(&header);
            try w.writeAll(data);
        },
    }
}

/// Writes data as one packet, appending a newline the way git's own
/// command lines carry one.
pub fn writeLine(w: *std.Io.Writer, data: []const u8) WriteError!void {
    const total_length = std.math.add(usize, data.len, 5) catch {
        return error.PktLineTooLong;
    };
    if (total_length > 65520) {
        return error.PktLineTooLong;
    }
    var header: [4]u8 = undefined;
    formatLength(total_length, &header);
    try w.writeAll(&header);
    try w.writeAll(data);
    try w.writeAll("\n");
}

/// Formats a length as a 4-byte lowercase hex string.
fn formatLength(length: usize, header: *[4]u8) void {
    const digits = "0123456789abcdef";
    header[0] = digits[(length >> 12) & 0xf];
    header[1] = digits[(length >> 8) & 0xf];
    header[2] = digits[(length >> 4) & 0xf];
    header[3] = digits[length & 0xf];
}

// expected

test "write then read round trips a data packet" {
    var buffer: [Packet.max_data_length + 4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, .{ .data = "hello" });

    var r: std.Io.Reader = .fixed(w.buffered());
    var read_buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try @import("reader.zig").read(&r, &read_buffer);
    try std.testing.expectEqualSlices(u8, "hello", packet.data);
}

test "writeLine appends the newline git's command lines carry" {
    var buffer: [Packet.max_data_length + 5]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeLine(&w, "hello");

    var r: std.Io.Reader = .fixed(w.buffered());
    var read_buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try @import("reader.zig").read(&r, &read_buffer);
    try std.testing.expectEqualSlices(u8, "hello\n", packet.data);
}

// suspicious

test "write rejects data longer than max_data_length" {
    var buffer: [Packet.max_data_length + 4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    const data = [_]u8{0} ** (Packet.max_data_length + 1);
    try std.testing.expectError(error.PktLineTooLong, write(&w, .{ .data = &data }));
}
