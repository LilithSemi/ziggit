//! A single pkt-line packet, tagged with its type.

/// One pkt-line. The three special lengths are not data.
pub const Packet = union(enum) {
    flush, // "0000"
    delimiter, // "0001"
    response_end, // "0002"
    data: []const u8,

    /// Maximum payload length in bytes (65520 total minus 4 byte header).
    pub const max_data_length: usize = 65516;
};
