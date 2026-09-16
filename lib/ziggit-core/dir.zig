//! One directory-path convention, shared by every layer that must tell an
//! absolute path apart from a relative one: `GIT_OBJECT_DIRECTORY` and
//! `GIT_ALTERNATE_OBJECT_DIRECTORIES`-style options, a `.git` file's
//! `gitdir:` target, a `commondir` file, an `objects/info/alternates`
//! entry, and a caller-supplied config file path.

const std = @import("std");

/// Opens `path` as a directory, with iteration enabled: an absolute path
/// (leading "/") opens directly; a relative path resolves against `base`
/// when given, the process's current directory otherwise.
pub fn openDirRelative(io: std.Io, base: ?std.Io.Dir, path: []const u8) std.Io.Dir.OpenError!std.Io.Dir {
    if (path.len > 0 and path[0] == '/') {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    const from = base orelse std.Io.Dir.cwd();
    return from.openDir(io, path, .{ .iterate = true });
}

// expected

test "a relative path resolves against the given base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");

    var opened = try openDirRelative(io, tmp.dir, "sub");
    defer opened.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/marker", .data = "hi" });
    const content = try opened.readFileAlloc(io, "marker", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

test "an absolute path opens directly, ignoring the given base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var unrelated = std.testing.tmpDir(.{ .iterate = true });
    defer unrelated.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    var opened = try openDirRelative(io, unrelated.dir, path_buf[0..len]);
    defer opened.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "marker", .data = "hi" });
    const content = try opened.readFileAlloc(io, "marker", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hi", content);
}
