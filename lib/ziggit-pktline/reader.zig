//! Reading pkt-line packets from a stream.

const std = @import("std");
const Packet = @import("Packet.zig").Packet;

pub const ReadError = error{ InvalidPktLine, PktLineTooLong, UnexpectedEndOfStream, ReadFailed };

/// Reads one packet from the stream.
/// The buffer must be at least Packet.max_data_length bytes.
/// A returned .data borrows buffer and is invalid after the next read call.
pub fn read(r: *std.Io.Reader, buffer: []u8) ReadError!Packet {
    std.debug.assert(buffer.len >= Packet.max_data_length);

    var header: [4]u8 = undefined;
    r.readSliceAll(&header) catch |err| {
        return switch (err) {
            error.EndOfStream => error.UnexpectedEndOfStream,
            else => error.ReadFailed,
        };
    };

    const length = parseLength(&header) catch {
        return error.InvalidPktLine;
    };

    switch (length) {
        0 => return .flush,
        1 => return .delimiter,
        2 => return .response_end,
        3 => return error.InvalidPktLine,
        else => {},
    }

    if (length > 65520) return error.PktLineTooLong;

    const payload_len = std.math.sub(usize, length, 4) catch {
        return error.InvalidPktLine;
    };

    // Defensive check: payload_len is at most 65516 (65520 - 4), and buffer.len
    // is asserted to be at least 65516, so this check cannot fire. Kept for
    // safety if constraints change.
    if (payload_len > buffer.len) {
        return error.PktLineTooLong;
    }

    r.readSliceAll(buffer[0..payload_len]) catch |err| {
        return switch (err) {
            error.EndOfStream => error.UnexpectedEndOfStream,
            else => error.ReadFailed,
        };
    };

    return .{ .data = buffer[0..payload_len] };
}

/// Parses a 4-byte lowercase hex header into its numeric value.
fn parseLength(header: *const [4]u8) ReadError!usize {
    var length: usize = 0;
    for (header) |c| {
        length = std.math.mul(usize, length, 16) catch {
            return error.InvalidPktLine;
        };
        const digit = hexNibble(c) catch {
            return error.InvalidPktLine;
        };
        length = std.math.add(usize, length, digit) catch {
            return error.InvalidPktLine;
        };
    }
    return length;
}

/// Decodes one lowercase hex digit. Rejects uppercase.
fn hexNibble(c: u8) ReadError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidPktLine,
    };
}

// expected

test "read parses a flush packet" {
    var r: std.Io.Reader = .fixed("0000");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expectEqual(Packet.flush, packet);
}

test "read parses a delimiter packet" {
    var r: std.Io.Reader = .fixed("0001");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expectEqual(Packet.delimiter, packet);
}

test "read parses a response end packet" {
    var r: std.Io.Reader = .fixed("0002");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expectEqual(Packet.response_end, packet);
}

test "read parses a data packet and returns its payload without the header" {
    var r: std.Io.Reader = .fixed("0006ab");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expectEqualSlices(u8, "ab", packet.data);
}

// suspicious

test "read rejects a length header that is not four hex digits" {
    var r: std.Io.Reader = .fixed("00ax");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.InvalidPktLine, read(&r, &buffer));
}

test "read rejects uppercase hex in the length header" {
    var r: std.Io.Reader = .fixed("00AB");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.InvalidPktLine, read(&r, &buffer));
}

test "read rejects length 0003, which no pkt-line may use" {
    var r: std.Io.Reader = .fixed("0003");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.InvalidPktLine, read(&r, &buffer));
}

test "read rejects a declared length longer than the bytes that arrived" {
    var r: std.Io.Reader = .fixed("0006a");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEndOfStream, read(&r, &buffer));
}

test "read rejects a declared length above the 65520 ceiling" {
    var r: std.Io.Reader = .fixed("ffff");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.PktLineTooLong, read(&r, &buffer));
}

test "read of an empty stream is UnexpectedEndOfStream, not flush" {
    var r: std.Io.Reader = .fixed("");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEndOfStream, read(&r, &buffer));
}

test "read accepts a data packet with no trailing newline" {
    var r: std.Io.Reader = .fixed("0009hello");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expectEqualSlices(u8, "hello", packet.data);
}

test "read parses length 0004 as an empty data packet, distinct from flush" {
    var r: std.Io.Reader = .fixed("0004");
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expect(std.meta.activeTag(packet) == .data);
    try std.testing.expectEqual(@as(usize, 0), packet.data.len);
    try std.testing.expect(packet != .flush);
}

test "read parses a packet at the maximum length of 65520" {
    var full_packet: [4 + Packet.max_data_length]u8 = undefined;
    @memcpy(full_packet[0..4], "fff0");
    @memset(full_packet[4..], 'x');
    var r: std.Io.Reader = .fixed(&full_packet);
    var buffer: [Packet.max_data_length]u8 = undefined;
    const packet = try read(&r, &buffer);
    try std.testing.expect(std.meta.activeTag(packet) == .data);
    try std.testing.expectEqual(@as(usize, Packet.max_data_length), packet.data.len);
    try std.testing.expect(std.mem.allEqual(u8, packet.data, 'x'));
}

test "read rejects a declared length of 65521, one past the ceiling" {
    var r: std.Io.Reader = .fixed("fff1");
    var buffer: [Packet.max_data_length]u8 = undefined;
    try std.testing.expectError(error.PktLineTooLong, read(&r, &buffer));
}
