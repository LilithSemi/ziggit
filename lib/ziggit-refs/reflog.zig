//! Appends one line to a ref's reflog: `logs/<name>` beside `refs/` under
//! `git_dir`. Every call only appends; nothing here reads or rewrites an
//! existing line, so a reader watching the file mid-write only ever sees
//! whole lines that were already there before this call started.
//!
//! `append` does its own read-then-write of the file's length, so a caller
//! must serialize concurrent calls for the same `name` itself, the same way
//! `Store.update` holds `name`'s own `<name>.lock` across the call. This
//! module never locks anything on its own.
//!
//! This module never invents an identity. `Store` is the one that knows
//! whether it has a real committer to attribute a write to, so it decides
//! whether `append` runs at all; `append` only ever writes the `Identity`
//! it is handed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const core_mod = @import("ziggit-core");
const Identity = core_mod.Identity;
const loose_mod = @import("loose.zig");

/// `RevertFailed` means the write below did not finish and the attempt to
/// undo it, right here inside `append`, also failed: `logs/<name>` is left
/// holding a partial line, not the clean state either a full success or a
/// clean `IoFailed` promises. A caller with a `Diagnostic` channel should
/// surface this distinctly from a plain `IoFailed`, since it means the
/// reflog file itself now needs a human to look at it.
pub const Error = error{ InvalidReflogMessage, IoFailed, RevertFailed } || Allocator.Error;
pub const RevertError = error{IoFailed} || Allocator.Error;

/// Rejects a message a reflog line cannot carry. A reflog line is one entry
/// per line, its trailing field tab-separated from the rest; a newline or a
/// tab inside `message` would let that message be misread as more than one
/// field or more than one entry.
pub fn validateMessage(message: []const u8) error{InvalidReflogMessage}!void {
    if (std.mem.indexOfAny(u8, message, "\n\t") != null) return error.InvalidReflogMessage;
}

/// Appends one reflog line for `name`:
/// "<old-hex> <new-hex> <identity> <unix-seconds> <tz>\t<message>\n", the
/// identity, seconds and tz written by `Identity.write`. Creates
/// `logs/<name>` and its parent directories on the ref's first reflog
/// entry. Returns the length `logs/<name>` had before this call, so a
/// caller that must undo this specific append after a later step fails can
/// pass that length to `revert`.
pub fn append(
    gpa: Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    old: Oid,
    new: Oid,
    identity: Identity,
    message: []const u8,
) Error!u64 {
    try validateMessage(message);

    const log_path = try std.fmt.allocPrint(gpa, "logs/{s}", .{name});
    defer gpa.free(log_path);

    if (loose_mod.parentOf(log_path)) |parent| {
        dir.createDirPath(io, parent) catch return error.IoFailed;
    }

    var old_buf: [Oid.max_formatted_length]u8 = undefined;
    var new_buf: [Oid.max_formatted_length]u8 = undefined;

    var line_buf: std.Io.Writer.Allocating = .init(gpa);
    defer line_buf.deinit();
    line_buf.writer.print("{s} {s} ", .{ old.toHex(&old_buf), new.toHex(&new_buf) }) catch return error.IoFailed;
    identity.write(&line_buf.writer) catch return error.IoFailed;
    line_buf.writer.print("\t{s}\n", .{message}) catch return error.IoFailed;
    const line = line_buf.written();

    var file = dir.createFile(io, log_path, .{ .truncate = false }) catch return error.IoFailed;
    defer file.close(io);

    const offset = file.length(io) catch return error.IoFailed;
    file.writePositionalAll(io, line, offset) catch {
        // A write that stopped partway leaves bytes of `line` on disk past
        // `offset`. Cut them back off now, while the failure is still ours
        // to fix, so this call is atomic from its caller's view: either the
        // whole line landed, or the file is exactly what it was before this
        // call started.
        file.setLength(io, offset) catch return error.RevertFailed;
        return error.IoFailed;
    };
    return offset;
}

/// Undoes an `append` to `logs/<name>` after the caller learns the change
/// that line was recording did not actually take effect: truncates the
/// file back to `previous_length`, the value `append` returned. Call this
/// only while still holding whatever serializes calls for `name`, since a
/// line appended by someone else in between would be lost too. A reflog
/// missing an entry is a known gap; a reflog line describing an update that
/// never happened is a lie, and this exists so the caller never has to
/// choose the lie.
pub fn revert(gpa: Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8, previous_length: u64) RevertError!void {
    const log_path = try std.fmt.allocPrint(gpa, "logs/{s}", .{name});
    defer gpa.free(log_path);

    var file = dir.openFile(io, log_path, .{ .mode = .write_only }) catch return error.IoFailed;
    defer file.close(io);
    file.setLength(io, previous_length) catch return error.IoFailed;
}

/// The identity every test below writes with, when a real one does not
/// matter to what the test is checking.
const test_identity: Identity = .{ .name = "A U Thor", .email = "author@example.com", .when = 1234567890, .tz_offset_minutes = 0 };

// expected

test "append writes a reflog line carrying the old id, the new id, and the message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "refs/heads/main", old, new, test_identity, "branch: created from main");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    var old_buf: [Oid.max_formatted_length]u8 = undefined;
    var expected_prefix_buf: [Oid.max_formatted_length * 2 + 2]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(&expected_prefix_buf, "{s} 333333333333333333333333333333333333333c ", .{old.toHex(&old_buf)});
    try std.testing.expect(std.mem.startsWith(u8, content, expected_prefix));
    try std.testing.expect(std.mem.endsWith(u8, content, "\tbranch: created from main\n"));
}

// suspicious

test "a second append adds a new line without disturbing the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_old = Oid.zero(.sha1);
    const first_new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", first_old, first_new, test_identity, "first");

    const second_new = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", first_new, second_new, test_identity, "second");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "\tfirst"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "\tsecond"));
    try std.testing.expect(lines.next() == null);
}

test "append rejects a message with a newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try std.testing.expectError(
        error.InvalidReflogMessage,
        append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, test_identity, "two\nlines"),
    );
}

test "append rejects a message with a tab" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try std.testing.expectError(
        error.InvalidReflogMessage,
        append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, test_identity, "a\ttab"),
    );
}

test "a rejected message leaves no reflog file behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try std.testing.expectError(
        error.InvalidReflogMessage,
        append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, test_identity, "bad\nmessage"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096)),
    );
}

// regression

test "revert truncates an append back to its previous length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_old = Oid.zero(.sha1);
    const first_new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", first_old, first_new, test_identity, "first");

    const second_new = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    const before_second = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", first_new, second_new, test_identity, "second");

    try revert(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", before_second);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, content, "\n"), "\tfirst"));
}

test "a reflog line written with a real identity parses back to the same name, email and tz offset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const id: Identity = .{ .name = "Ada Lovelace", .email = "ada@example.com", .when = 1700000000, .tz_offset_minutes = 60 };
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, id, "commit: real identity");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    const line = std.mem.trimEnd(u8, content, "\n");
    const tab = std.mem.indexOfScalar(u8, line, '\t').?;
    // The line is "<old-hex> <new-hex> <identity>\t<message>"; skip the
    // two hex fields to reach the identity, which is everything up to
    // the tab.
    const first_space = std.mem.indexOfScalar(u8, line, ' ').?;
    const second_space = std.mem.indexOfScalarPos(u8, line, first_space + 1, ' ').?;
    const identity_field = line[second_space + 1 .. tab];

    const parsed = try Identity.parse(identity_field);
    try std.testing.expectEqualStrings(id.name, parsed.name);
    try std.testing.expectEqualStrings(id.email, parsed.email);
    try std.testing.expectEqual(id.tz_offset_minutes, parsed.tz_offset_minutes);
}

test "a reflog line carries a positive non-zero tz offset such as +0530" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const id: Identity = .{ .name = "A U Thor", .email = "author@example.com", .when = 1700000000, .tz_offset_minutes = 5 * 60 + 30 };
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, id, "tz check");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "+0530") != null);
}

test "a reflog line carries a negative tz offset such as -0430" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const id: Identity = .{ .name = "A U Thor", .email = "author@example.com", .when = 1700000000, .tz_offset_minutes = -(4 * 60 + 30) };
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, id, "tz check");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "-0430") != null);
}

/// A `std.Io` that behaves exactly like `std.testing.io`, except its
/// `fileWritePositional` stops after `remaining` bytes, the same shape a
/// disk that runs out of space mid-write leaves behind. Every other
/// operation is the real implementation, called with the real
/// implementation's own `userdata`, so only the write path differs.
const WriteStopsAfter = struct {
    var remaining: usize = 0;
    var table: std.Io.VTable = undefined;

    fn write(
        userdata: ?*anyopaque,
        file: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
        offset: u64,
    ) std.Io.File.WritePositionalError!usize {
        if (remaining == 0) return error.NoSpaceLeft;
        const chunk = data[0];
        const allowed = @min(chunk.len, remaining);
        const written = try std.testing.io.vtable.fileWritePositional(userdata, file, header, &.{chunk[0..allowed]}, splat, offset);
        remaining -= written;
        return written;
    }

    fn io(bytes_allowed: usize) std.Io {
        remaining = bytes_allowed;
        table = std.testing.io.vtable.*;
        table.fileWritePositional = write;
        return .{ .userdata = std.testing.io.userdata, .vtable = &table };
    }
};

test "a write that stops partway through the line leaves the file exactly as it was before the call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = Oid.zero(.sha1);
    const new = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    _ = try append(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", old, new, test_identity, "first");

    const before = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(before);

    // Five bytes is enough to let the write start and land some bytes on
    // disk, but not enough to finish the line, forcing the exact partial
    // write finding 1 is about.
    const second_new = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try std.testing.expectError(
        error.IoFailed,
        append(std.testing.allocator, tmp.dir, WriteStopsAfter.io(5), "HEAD", new, second_new, test_identity, "second"),
    );

    const after = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}
