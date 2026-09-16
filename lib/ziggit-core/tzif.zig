//! Reads the UTC offset that was in effect at a given moment out of a
//! TZif stream (RFC 8536), the format `/etc/localtime` is written in.
//!
//! `std.tz` parses that byte format, but it has no `/etc/localtime`
//! lookup and reads no `TZ` variable: it never finds the file on its own.
//! This library reads no ambient state either, so opening the file and
//! handing over a reader stays the caller's job. This module only turns
//! the bytes the caller already has into an offset.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadHeader,
    BadVersion,
    Malformed,
    OverlargeFooter,
    StreamTooLong,
    EndOfStream,
    ReadFailed,
    NonWholeMinuteOffset,
    OffsetOutOfRange,
    /// The header declares a `timecnt`, `typecnt` or `leapcnt` too large
    /// for the stream to hold. Reported instead of letting
    /// `std.tz.Tz.parse` size an allocation from the same number, so a
    /// hostile header is told apart from genuine allocator exhaustion.
    OverlargeCounts,
} || Allocator.Error;

/// The UTC offset in effect at `when` (unix seconds), in minutes east,
/// read from `reader`. `std.tz.Tz.parse` allocates its result; this frees
/// it again before returning, so nothing here outlives the call.
pub fn offsetFromTzif(gpa: Allocator, reader: *std.Io.Reader, when: i64) Error!i16 {
    try rejectImpossibleCounts(reader);

    var parsed = try std.tz.Tz.parse(gpa, reader);
    defer parsed.deinit();

    return minutesFromOffsetSeconds(pickTimetype(parsed, when).offset);
}

// RFC 8536 ยง3.1: a TZif header is 44 octets: 4 magic, 1 version, 15
// reserved, then six 4 octet counts, in this order: isutcnt, isstdcnt,
// leapcnt, timecnt, typecnt, charcnt. `std.tz.Tz.Header` lays out the same
// 44 bytes; the offsets below decode them independently, so the counts
// can be checked before `std.tz.Tz.parse` allocates from them.
const header_len: usize = 44;
const version_offset: usize = 4;
const isutcnt_offset: usize = 20;
const isstdcnt_offset: usize = 24;
const leapcnt_offset: usize = 28;
const timecnt_offset: usize = 32;
const typecnt_offset: usize = 36;
const charcnt_offset: usize = 40;

const HeaderCounts = struct {
    isutcnt: u64,
    isstdcnt: u64,
    leapcnt: u64,
    timecnt: u64,
    typecnt: u64,
    charcnt: u64,
};

fn readHeaderCounts(header: []const u8) HeaderCounts {
    return .{
        .isutcnt = std.mem.readInt(u32, header[isutcnt_offset..][0..4], .big),
        .isstdcnt = std.mem.readInt(u32, header[isstdcnt_offset..][0..4], .big),
        .leapcnt = std.mem.readInt(u32, header[leapcnt_offset..][0..4], .big),
        .timecnt = std.mem.readInt(u32, header[timecnt_offset..][0..4], .big),
        .typecnt = std.mem.readInt(u32, header[typecnt_offset..][0..4], .big),
        .charcnt = std.mem.readInt(u32, header[charcnt_offset..][0..4], .big),
    };
}

fn checkedAdd(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.OverlargeCounts;
}

fn checkedMul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.OverlargeCounts;
}

/// The byte length of one block's body: everything between its header and
/// the next header, or end of file. `legacy` selects RFC 8536 ยง3.1 (32 bit
/// timestamps) or ยง3.2 (64 bit timestamps); a version 2 or 3 file has one
/// block of each. Every per-record size mirrors a read `std.tz.Tz.parseBlock`
/// performs, in the same order:
///   - a transition is a timestamp (4 bytes legacy, 8 bytes modern) plus a
///     1 byte type index (`takeInt` then `takeByte` per transition);
///   - a `ttinfo` record is a 4 byte UT offset, a 1 byte DST flag and a
///     1 byte designator index, 6 bytes total (three reads per type);
///   - a leap second record is a 4 or 8 byte occurrence plus a 4 byte
///     correction (`takeInt` twice per record);
///   - the designator bytes (`charcnt`) and the standard/wall and UT/local
///     indicator bytes (`isstdcnt` and `isutcnt`, one octet each) follow.
fn blockBodyLen(counts: HeaderCounts, legacy: bool) Error!u64 {
    const transition_len = try checkedMul(counts.timecnt, if (legacy) @as(u64, 4 + 1) else @as(u64, 8 + 1));
    const timetype_len = try checkedMul(counts.typecnt, 6);
    const leap_len = try checkedMul(counts.leapcnt, if (legacy) @as(u64, 4 + 4) else @as(u64, 8 + 4));
    const indicator_len = try checkedAdd(counts.isstdcnt, counts.isutcnt);
    const rest_len = try checkedAdd(counts.charcnt, indicator_len);

    return checkedAdd(try checkedAdd(transition_len, timetype_len), try checkedAdd(leap_len, rest_len));
}

/// Rejects a TZif stream whose header (or, for version 2 or 3, whose
/// second header) declares more transitions, time types or leap seconds
/// than the stream can hold. `std.tz.Tz.parse` sizes its allocations
/// straight from those counts with no such check, so this runs first.
///
/// This reads by peeking, never taking, so `reader`'s position is
/// unchanged when it returns and `reader` stays ready for
/// `std.tz.Tz.parse`.
///
/// The bound compares against `reader.buffer.len`, the most this reader
/// could ever hand back from one peek. For a reader built over a whole
/// file already in memory (`std.Io.Reader.fixed`, the pattern this
/// module's own doc comment and every test here use), that length is the
/// file's exact size, so the check is exact for both a version 0 file and
/// a version 2 or 3 file's two blocks. For a reader with a smaller
/// working buffer than the file, `buffer.len` is only a ceiling, so this
/// can reject a genuine file too large for that buffer; it never accepts
/// a file too small to hold what its header claims.
fn rejectImpossibleCounts(reader: *std.Io.Reader) Error!void {
    // A reader whose buffer cannot hold one header can never satisfy the
    // peek below without exceeding its own capacity. `std.tz.Tz.parse`
    // reads the header into its own stack memory, not the reader's
    // buffer, so it stays safe to call directly in this narrow case.
    if (reader.buffer.len < header_len) return;

    const header1 = reader.peek(header_len) catch |err| switch (err) {
        error.EndOfStream => return, // Genuinely short stream; std.tz.Tz.parse reports this itself.
        error.ReadFailed => return error.ReadFailed,
    };
    if (!std.mem.eql(u8, header1[0..4], "TZif")) return; // std.tz.Tz.parse reports the bad magic.
    const version1 = header1[version_offset];
    if (version1 != 0 and version1 != '2' and version1 != '3') return; // std.tz.Tz.parse reports the bad version.

    const legacy_len = try blockBodyLen(readHeaderCounts(header1), true);
    const legacy_end = try checkedAdd(header_len, legacy_len);
    if (legacy_end > reader.buffer.len) return error.OverlargeCounts;

    if (version1 == 0) return; // A version 0 file has only this one block.

    // A version 2 or 3 file repeats the header and body in modern, 64 bit
    // form (RFC 8536 ยง3.2). `std.tz.Tz.parse` only skips the legacy block
    // above, never allocates from it, but its declared size still has to
    // be provably real before the modern header past it can be trusted.
    const header2_end = try checkedAdd(legacy_end, header_len);
    if (header2_end > reader.buffer.len) return error.OverlargeCounts;

    const header2_pos = std.math.cast(usize, legacy_end) orelse return error.OverlargeCounts;
    const peek_len = std.math.cast(usize, header2_end) orelse return error.OverlargeCounts;
    const combined = reader.peek(peek_len) catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return error.ReadFailed,
    };
    const header2 = combined[header2_pos..][0..header_len];
    if (!std.mem.eql(u8, header2[0..4], "TZif")) return;
    const version2 = header2[version_offset];
    if (version2 != '2' and version2 != '3') return;

    const modern_len = try blockBodyLen(readHeaderCounts(header2), false);
    const modern_end = try checkedAdd(header2_end, modern_len);
    if (modern_end > reader.buffer.len) return error.OverlargeCounts;
}

/// The timetype in effect at `when`: the one belonging to the last
/// transition at or before `when`. RFC 8536 requires `transitions` to be
/// sorted in strictly ascending `ts` order, so a plain scan that stops at
/// the first transition past `when` is enough; no binary search is
/// needed for a file this small.
///
/// `when` before every transition, or a file with no transitions at all,
/// has no transition to answer from. A fresh TZif file's first timetype
/// is sometimes the DST one, which would misreport the zone's normal
/// offset, so this picks the first timetype that is not DST instead;
/// only when every timetype is DST does it fall back to the first one.
/// `Tz.parse` already refuses a file with zero timetypes, so this always
/// finds one.
fn pickTimetype(parsed: std.tz.Tz, when: i64) *const std.tz.Timetype {
    var chosen: ?*const std.tz.Timetype = null;
    for (parsed.transitions) |t| {
        if (t.ts > when) break;
        chosen = t.timetype;
    }
    if (chosen) |c| return c;

    for (parsed.timetypes) |*tt| {
        if (!tt.isDst()) return tt;
    }
    return &parsed.timetypes[0];
}

/// Converts a TZif offset from seconds to minutes. A TZif file is
/// untrusted input, so a real-world offset that is not a whole number of
/// minutes, or one too large for `i16`, is reported rather than
/// truncated into a wrong answer.
fn minutesFromOffsetSeconds(offset_seconds: i32) Error!i16 {
    const minutes = std.math.divExact(i32, offset_seconds, 60) catch return error.NonWholeMinuteOffset;
    return std.math.cast(i16, minutes) orelse error.OffsetOutOfRange;
}

// expected

// Both byte vectors below are hand built TZif version 0 (the "legacy",
// 32 bit timestamp) files: the smallest form the parser accepts, built
// as a source constant so no test reads a real file.

// zig fmt is told to leave these alone: its normal column layout for a
// long array literal would break each field across an arbitrary number
// of rows, so a comment naming one field would no longer sit next to
// the bytes it names.
// zig fmt: off

/// One transition, at unix time 1000, from a non-DST zero offset into a
/// one hour DST offset.
const one_transition_tzif =
    // header: magic "TZif", version 0 (legacy), 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', 0 } ++ [_]u8{0} ** 15 ++
    // counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=1, typecnt=2, charcnt=4
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 } ++ [_]u8{ 0, 0, 0, 4 } ++
    // transition: ts = 1000
    [_]u8{ 0, 0, 0x03, 0xE8 } ++
    // that transition's timetype index: 1
    [_]u8{1} ++
    // timetype 0: offset 0s, not DST, designator index 0 ("A")
    [_]u8{ 0, 0, 0, 0, 0, 0 } ++
    // timetype 1: offset 3600s, DST, designator index 2 ("B")
    [_]u8{ 0, 0, 0x0E, 0x10, 1, 2 } ++
    // designators: "A\0B\0"
    [_]u8{ 'A', 0, 'B', 0 };

/// No transitions at all, one non-DST timetype whose offset, 37 seconds,
/// is not a whole number of minutes.
const no_transition_odd_offset_tzif =
    // header: magic "TZif", version 0 (legacy), 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', 0 } ++ [_]u8{0} ** 15 ++
    // counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=0, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 } ++
    // timetype 0: offset 37s, not DST, designator index 0 ("A")
    [_]u8{ 0, 0, 0, 0x25, 0, 0 } ++
    // designators: "A\0"
    [_]u8{ 'A', 0 };

/// A version 0 header alone, 44 bytes and no body, declaring `timecnt` as
/// the largest possible `u32`. This is the shape the finding this module
/// fixes describes: a small file whose header claims far more than it
/// could ever hold.
const hostile_timecnt_tzif =
    // header: magic "TZif", version 0 (legacy), 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', 0 } ++ [_]u8{0} ** 15 ++
    // counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=0xFFFFFFFF, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 };

/// A minimal, genuinely valid version 2 file: an empty legacy block
/// (RFC 8536 ยง3.1) followed by a modern block (ยง3.2) with one transition,
/// at unix time 2000, into a 30 minute offset, and an empty POSIX TZ
/// footer.
const version2_tzif =
    // legacy header: magic "TZif", version '2', 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', '2' } ++ [_]u8{0} ** 15 ++
    // legacy counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=0, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 } ++
    // legacy timetype 0: offset 0s, not DST, designator index 0 ("A")
    [_]u8{ 0, 0, 0, 0, 0, 0 } ++
    // legacy designators: "A\0"
    [_]u8{ 'A', 0 } ++
    // modern header: magic "TZif", version '2', 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', '2' } ++ [_]u8{0} ** 15 ++
    // modern counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=1, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 } ++
    // modern transition: ts = 2000 (8 byte timestamp)
    [_]u8{ 0, 0, 0, 0, 0, 0, 0x07, 0xD0 } ++
    // that transition's timetype index: 0
    [_]u8{0} ++
    // modern timetype 0: offset 1800s (30 minutes), not DST, designator index 0 ("A")
    [_]u8{ 0, 0, 0x07, 0x08, 0, 0 } ++
    // modern designators: "A\0"
    [_]u8{ 'A', 0 } ++
    // footer: empty POSIX TZ string between two newlines
    [_]u8{ '\n', '\n' };

/// A version 2 file whose legacy block (RFC 8536 ยง3.1) is genuinely
/// present and valid, but whose modern header (ยง3.2) declares `timecnt`
/// as the largest possible `u32` with no modern body behind it. This is
/// the same attack as `hostile_timecnt_tzif`, aimed at the second header
/// instead of the first, to prove the bound holds for both.
const hostile_modern_timecnt_tzif =
    // legacy header: magic "TZif", version '2', 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', '2' } ++ [_]u8{0} ** 15 ++
    // legacy counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=0, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 } ++
    // legacy timetype 0: offset 0s, not DST, designator index 0 ("A")
    [_]u8{ 0, 0, 0, 0, 0, 0 } ++
    // legacy designators: "A\0"
    [_]u8{ 'A', 0 } ++
    // modern header: magic "TZif", version '2', 15 reserved bytes
    [_]u8{ 'T', 'Z', 'i', 'f', '2' } ++ [_]u8{0} ** 15 ++
    // modern counts: isutcnt=0, isstdcnt=0, leapcnt=0, timecnt=0xFFFFFFFF, typecnt=1, charcnt=2
    [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{0} ** 4 ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 2 };

// zig fmt: on

test "offsetFromTzif reads the offset before the first transition" {
    var reader: std.Io.Reader = .fixed(&one_transition_tzif);
    const minutes = try offsetFromTzif(std.testing.allocator, &reader, 500);
    try std.testing.expectEqual(@as(i16, 0), minutes);
}

test "offsetFromTzif reads the offset after a transition" {
    var reader: std.Io.Reader = .fixed(&one_transition_tzif);
    const minutes = try offsetFromTzif(std.testing.allocator, &reader, 1500);
    try std.testing.expectEqual(@as(i16, 60), minutes);
}

test "offsetFromTzif reads a version 2 file's modern block" {
    var reader: std.Io.Reader = .fixed(&version2_tzif);
    const minutes = try offsetFromTzif(std.testing.allocator, &reader, 2500);
    try std.testing.expectEqual(@as(i16, 30), minutes);
}

// suspicious

test "offsetFromTzif rejects an offset that is not a whole number of minutes" {
    var reader: std.Io.Reader = .fixed(&no_transition_odd_offset_tzif);
    try std.testing.expectError(error.NonWholeMinuteOffset, offsetFromTzif(std.testing.allocator, &reader, 0));
}

// A 44 byte header claiming a `timecnt` of 0xFFFFFFFF asks `std.tz.Tz.parse`
// to allocate a `[]Transition` sized for over 4 billion entries before it
// has read a single further byte. Both tests below wrap `std.testing.allocator`
// in a `FailingAllocator` that fails on the very first allocation: if
// `offsetFromTzif` let that request through, the result would be
// `error.OutOfMemory` from the failing allocator, not the named error this
// module now returns. Getting the named error back instead proves no
// allocation was attempted; it does not measure how much memory a real
// allocator would have handed out had the check been missing.

test "offsetFromTzif rejects a hostile timecnt without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var reader: std.Io.Reader = .fixed(&hostile_timecnt_tzif);
    try std.testing.expectError(error.OverlargeCounts, offsetFromTzif(failing.allocator(), &reader, 0));
}

test "offsetFromTzif rejects a hostile timecnt in a version 2 file's modern block without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var reader: std.Io.Reader = .fixed(&hostile_modern_timecnt_tzif);
    try std.testing.expectError(error.OverlargeCounts, offsetFromTzif(failing.allocator(), &reader, 0));
}
