//! Applies a git pack delta to its base: a declared base size, a declared
//! result size, and a stream of copy and insert instructions.
//!
//! The instruction format has no formal specification; this file trusts
//! none of it. A copy instruction is checked against the base it copies
//! from, and the total written length is checked against the size the
//! delta itself declared, both before and after the instruction stream
//! ends.

const std = @import("std");

pub const delta = struct {
    pub const Error = error{CorruptDelta};

    /// Applies `patch` to `base`, appending the reconstructed bytes to
    /// `out`. `patch` is the fully decompressed delta payload: a base-size
    /// varint, a result-size varint, then the instruction stream.
    ///
    /// The base-size varint is checked against `base.len`; a delta built
    /// for a different base is rejected rather than silently misapplied.
    /// `out` failing to accept a write has no separate error in this
    /// function's error set, so it also surfaces as `CorruptDelta`.
    ///
    /// `out` is written incrementally, one instruction at a time, not
    /// buffered and released only on success: a `patch` that starts with
    /// several valid instructions and then turns out corrupt still leaves
    /// those earlier, correctly-derived bytes in `out` before the error
    /// surfaces. What `out` never receives is bytes from the instruction
    /// that overshoots: each instruction's contribution to the running
    /// total is checked against the declared result size before that
    /// instruction is written, not after, so a too-long result is rejected
    /// without ever writing the bytes that would have made it too long.
    pub fn apply(base: []const u8, patch: []const u8, out: *std.Io.Writer) Error!void {
        var r: std.Io.Reader = .fixed(patch);

        const declared_base_size = r.takeLeb128(u64) catch return error.CorruptDelta;
        if (declared_base_size != base.len) return error.CorruptDelta;
        const result_size = r.takeLeb128(u64) catch return error.CorruptDelta;

        var written: u64 = 0;
        while (true) {
            const control = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return error.CorruptDelta,
            };
            if (control & 0x80 != 0) {
                written = try applyCopy(&r, base, control, out, written, result_size);
            } else if (control != 0) {
                written = try applyInsert(&r, control, out, written, result_size);
            } else {
                // Instruction byte 0 is reserved by the format.
                return error.CorruptDelta;
            }
        }
        if (written != result_size) return error.CorruptDelta;
    }

    fn applyCopy(
        r: *std.Io.Reader,
        base: []const u8,
        control: u8,
        out: *std.Io.Writer,
        written: u64,
        result_size: u64,
    ) Error!u64 {
        var copy_offset: u32 = 0;
        var copy_size: u32 = 0;
        inline for (0..4) |i| {
            if (control & (@as(u8, 1) << i) != 0) {
                const b = r.takeByte() catch return error.CorruptDelta;
                copy_offset |= @as(u32, b) << (8 * i);
            }
        }
        inline for (0..3) |i| {
            if (control & (@as(u8, 1) << (4 + i)) != 0) {
                const b = r.takeByte() catch return error.CorruptDelta;
                copy_size |= @as(u32, b) << (8 * i);
            }
        }
        if (copy_size == 0) copy_size = 0x10000;

        const end = std.math.add(u32, copy_offset, copy_size) catch return error.CorruptDelta;
        if (end > base.len) return error.CorruptDelta;
        // Checked, and rejected, before the write it describes: `out` must
        // never see bytes that push the running total past the declared
        // result size, even when everything about the copy is otherwise
        // well formed.
        const new_written = std.math.add(u64, written, copy_size) catch return error.CorruptDelta;
        if (new_written > result_size) return error.CorruptDelta;
        out.writeAll(base[copy_offset..end]) catch return error.CorruptDelta;
        return new_written;
    }

    fn applyInsert(
        r: *std.Io.Reader,
        control: u8,
        out: *std.Io.Writer,
        written: u64,
        result_size: u64,
    ) Error!u64 {
        // Checked before the read and write it describes, for the same
        // reason as `applyCopy`: an insert that would overshoot never
        // reaches `out`.
        const new_written = std.math.add(u64, written, control) catch return error.CorruptDelta;
        if (new_written > result_size) return error.CorruptDelta;
        const bytes = r.take(control) catch return error.CorruptDelta;
        out.writeAll(bytes) catch return error.CorruptDelta;
        return new_written;
    }
};

fn expectApplied(base: []const u8, patch: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try delta.apply(base, patch, &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

// expected

test "delta apply handles a copy instruction" {
    // base_size=10, result_size=3, copy(offset=2, size=3) from "abcdefghij".
    const patch = [_]u8{ 10, 3, 0x91, 2, 3 };
    try expectApplied("abcdefghij", &patch, "cde");
}

test "delta apply handles an insert instruction" {
    // base_size=0, result_size=5, insert 5 literal bytes "hello".
    const patch = "\x00\x05\x05hello";
    try expectApplied("", patch, "hello");
}

// suspicious

test "delta apply rejects a copy that reads past the end of the base" {
    // base_size=2, result_size=5, copy(offset=0, size=5) from a 2 byte base.
    const patch = [_]u8{ 2, 5, 0x91, 0, 5 };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.CorruptDelta, delta.apply("ab", &patch, &w));
}

test "delta apply rejects a result shorter than the declared result size" {
    // base_size=3, result_size=5, but the instruction stream only inserts 3 bytes.
    const patch = "\x03\x05\x03xyz";
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.CorruptDelta, delta.apply("abc", patch, &w));
}

test "delta apply rejects a result longer than the declared result size" {
    // base_size=3, result_size=2, but the instruction stream inserts 3 bytes.
    const patch = "\x03\x02\x03xyz";
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.CorruptDelta, delta.apply("abc", patch, &w));
}

test "delta apply never writes the bytes of the instruction that overshoots" {
    // base_size=3, result_size=2: the single insert instruction below would
    // push the running total to 3, past the declared 2, so its bytes must
    // never reach `out` at all, not even the two that would have been in
    // bounds if the instruction were shorter.
    const patch = "\x03\x02\x03xyz";
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.CorruptDelta, delta.apply("abc", patch, &w));
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}
