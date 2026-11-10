//! Line ending and `$Id$` conversion, as pure functions over bytes.
//!
//! Clean is the worktree to blob direction, smudge is blob to worktree.
//! Every rule here was taken from git 2.56.0's own output rather than from
//! its documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

/// What the worktree copy of a text path ends its lines with.
pub const Eol = enum { lf, crlf };

/// Whether a path is text, and so whether its line endings are translated.
pub const TextKind = enum {
    /// `-text`, or the `binary` macro. Never translated.
    binary,
    /// `text`. Always translated, even content holding a NUL: git converts
    /// `a\r\n\0b\r\n` under `* text` to `a\n\0b\n`.
    text,
    /// `text=auto`, or no text attribute with `core.autocrlf` set. Content
    /// decides.
    auto,
    /// No text attribute and no `core.autocrlf`. Never translated.
    unset,
};

/// True when the content holds a NUL byte.
///
/// Git scans the whole buffer with no window: a NUL at offset 65000, and at
/// three megabytes, both still mark the file binary. `ziggit-merge`'s own
/// `isBinary` looks only at the first 8000 bytes, which is git's rule in
/// that other place; the two are deliberately different and must not be
/// folded together.
pub fn hasNul(content: []const u8) bool {
    return std.mem.indexOfScalar(u8, content, 0) != null;
}

/// Whether the clean direction translates this content.
pub fn cleanTranslates(kind: TextKind, content: []const u8) bool {
    return switch (kind) {
        .binary, .unset => false,
        .text => true,
        .auto => !hasNul(content),
    };
}

/// Whether the smudge direction translates this content.
///
/// `auto` carries one guard that `text` does not: content already holding a
/// CRLF is left alone, so a mixed blob comes out unchanged under
/// `text=auto` while the same blob under `text` is translated. The
/// asymmetry is git's and it is the rule most easily got wrong.
pub fn smudgeTranslates(kind: TextKind, content: []const u8) bool {
    return switch (kind) {
        .binary, .unset => false,
        .text => true,
        .auto => !hasNul(content) and std.mem.indexOf(u8, content, "\r\n") == null,
    };
}

/// Drops every CR that is immediately followed by LF. A lone CR survives,
/// so `a\rb\r\nc\n` becomes `a\rb\nc\n`.
///
/// Answers null when nothing would change, so a caller can keep the bytes
/// it already has rather than pay for a copy.
pub fn cleanLineEndings(gpa: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.indexOf(u8, content, "\r\n") == null) return null;

    var out = try std.ArrayList(u8).initCapacity(gpa, content.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') continue;
        out.appendAssumeCapacity(content[i]);
    }
    return try out.toOwnedSlice(gpa);
}

/// Turns every LF that is not already preceded by CR into CRLF, which never
/// doubles an existing CRLF and never touches a lone CR: `a\rb\nc\n`
/// becomes `a\rb\r\nc\r\n`.
///
/// Answers null when nothing would change.
pub fn smudgeLineEndings(gpa: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    var needed: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n' and (i == 0 or content[i - 1] != '\r')) needed += 1;
    }
    if (needed == 0) return null;

    var out = try std.ArrayList(u8).initCapacity(gpa, content.len + needed);
    errdefer out.deinit(gpa);
    for (content, 0..) |c, i| {
        if (c == '\n' and (i == 0 or content[i - 1] != '\r')) out.appendAssumeCapacity('\r');
        out.appendAssumeCapacity(c);
    }
    return try out.toOwnedSlice(gpa);
}

/// Collapses every `$Id: ... $` back to `$Id$`, which is what the blob
/// holds. Answers null when nothing would change.
pub fn cleanIdent(gpa: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.indexOf(u8, content, "$Id:") == null) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = content;
    while (std.mem.indexOf(u8, rest, "$Id:")) |start| {
        // An unterminated `$Id:` is not an expansion, so it stays as it is.
        const close = std.mem.indexOfScalarPos(u8, rest, start + 4, '$') orelse break;
        try out.appendSlice(gpa, rest[0..start]);
        try out.appendSlice(gpa, "$Id$");
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(gpa, rest);
    return try out.toOwnedSlice(gpa);
}

/// Expands every `$Id$` to `$Id: <oid> $`, the blob's own id. Answers null
/// when nothing would change.
pub fn smudgeIdent(gpa: Allocator, content: []const u8, oid: Oid) Allocator.Error!?[]u8 {
    if (std.mem.indexOf(u8, content, "$Id$") == null) return null;

    var hex: [Oid.max_formatted_length]u8 = undefined;
    const id = oid.toHex(&hex);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = content;
    while (std.mem.indexOf(u8, rest, "$Id$")) |start| {
        try out.appendSlice(gpa, rest[0..start]);
        try out.appendSlice(gpa, "$Id: ");
        try out.appendSlice(gpa, id);
        try out.appendSlice(gpa, " $");
        rest = rest[start + 4 ..];
    }
    try out.appendSlice(gpa, rest);
    return try out.toOwnedSlice(gpa);
}

const testing = std.testing;

/// Runs `cleanLineEndings` and answers the bytes either way, so a test
/// reads the same whether or not a copy was made.
fn cleaned(gpa: Allocator, content: []const u8) ![]const u8 {
    return (try cleanLineEndings(gpa, content)) orelse gpa.dupe(u8, content);
}

fn smudged(gpa: Allocator, content: []const u8) ![]const u8 {
    return (try smudgeLineEndings(gpa, content)) orelse gpa.dupe(u8, content);
}

test "clean drops a CR only when an LF follows it" {
    const gpa = testing.allocator;
    // Measured: `a\rb\r\nc\n` under `* text` stores `a\rb\nc\n`, so the
    // lone CR survives.
    const out = try cleaned(gpa, "a\rb\r\nc\n");
    defer gpa.free(out);
    try testing.expectEqualStrings("a\rb\nc\n", out);
}

test "clean leaves content that holds no CRLF alone" {
    const gpa = testing.allocator;
    try testing.expect((try cleanLineEndings(gpa, "a\nb\n")) == null);
    try testing.expect((try cleanLineEndings(gpa, "a\rb")) == null);
}

test "smudge never doubles an existing CRLF" {
    const gpa = testing.allocator;
    // Measured: an all-CRLF blob under `* text eol=crlf` comes out
    // unchanged, because every LF already had a CR in front of it.
    try testing.expect((try smudgeLineEndings(gpa, "a\r\nb\r\n")) == null);
}

test "smudge converts a lone LF and leaves a lone CR" {
    const gpa = testing.allocator;
    // Measured: blob `a\rb\nc\n` under `* text eol=crlf` becomes
    // `a\rb\r\nc\r\n`.
    const out = try smudged(gpa, "a\rb\nc\n");
    defer gpa.free(out);
    try testing.expectEqualStrings("a\rb\r\nc\r\n", out);
}

test "smudge converts only the lone LF in mixed content" {
    const gpa = testing.allocator;
    // Measured: blob `a\r\nb\nc\r\n` under `* text eol=crlf` becomes
    // `a\r\nb\r\nc\r\n`.
    const out = try smudged(gpa, "a\r\nb\nc\r\n");
    defer gpa.free(out);
    try testing.expectEqualStrings("a\r\nb\r\nc\r\n", out);
}

test "an LF first in the content still gains its CR" {
    const gpa = testing.allocator;
    const out = try smudged(gpa, "\nx");
    defer gpa.free(out);
    try testing.expectEqualStrings("\r\nx", out);
}

test "a NUL anywhere marks content binary, with no window" {
    const gpa = testing.allocator;
    // Git scans the whole buffer: measured with a NUL at 65000 and at 3MB.
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    @memset(big, 'x');
    try testing.expect(!hasNul(big));
    big[99_999] = 0;
    try testing.expect(hasNul(big));
}

test "forced text translates even content holding a NUL" {
    // Measured: `a\r\n\0b\r\n` under `* text` stores `a\n\0b\n`, so the
    // NUL does not stop a forced translation.
    try testing.expect(cleanTranslates(.text, "a\r\n\x00b\r\n"));
    try testing.expect(!cleanTranslates(.auto, "a\r\n\x00b\r\n"));
    try testing.expect(!cleanTranslates(.binary, "a\r\nb\r\n"));
    try testing.expect(!cleanTranslates(.unset, "a\r\nb\r\n"));
}

test "auto refuses to smudge content that already holds CRLF, forced text does not" {
    // The asymmetry git has and the rule most easily got wrong. Measured:
    // a mixed blob under `* text=auto` with autocrlf true comes out
    // unchanged, while the same blob under `* text` is converted.
    const mixed = "a\r\nb\nc\r\n";
    try testing.expect(!smudgeTranslates(.auto, mixed));
    try testing.expect(smudgeTranslates(.text, mixed));
    // With no CR in it, auto does translate.
    try testing.expect(smudgeTranslates(.auto, "a\nb\n"));
}

test "ident expands to the blob's own id and collapses back" {
    const gpa = testing.allocator;
    const oid = try oid_mod.Oid.parse(.sha1, "908fac037784f9bf5b6cf3d9cddfe130aa13646c");

    // Measured: the blob holds `$Id$` and the worktree gets
    // `$Id: 908fac037784f9bf5b6cf3d9cddfe130aa13646c $`.
    const out = (try smudgeIdent(gpa, "start\n$Id$\nend\n", oid)).?;
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "start\n$Id: 908fac037784f9bf5b6cf3d9cddfe130aa13646c $\nend\n",
        out,
    );

    const back = (try cleanIdent(gpa, out)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("start\n$Id$\nend\n", back);
}

test "clean collapses an ident holding any id at all" {
    const gpa = testing.allocator;
    // Measured: a worktree line of `$Id: deadbeef... $` stores `$Id$`.
    const back = (try cleanIdent(gpa, "x\n$Id: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef $\ny\n")).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("x\n$Id$\ny\n", back);
}

test "an unterminated ident is left as it is" {
    const gpa = testing.allocator;
    const out = try cleanIdent(gpa, "$Id: no closing marker\n");
    if (out) |o| {
        defer gpa.free(o);
        try testing.expectEqualStrings("$Id: no closing marker\n", o);
    }
}

test "content with no ident marker is left alone" {
    const gpa = testing.allocator;
    const oid = oid_mod.Oid.zero(.sha1);
    try testing.expect((try smudgeIdent(gpa, "nothing here\n", oid)) == null);
    try testing.expect((try cleanIdent(gpa, "nothing here\n")) == null);
}
