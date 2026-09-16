//! Parsing `.gitmodules`: git config syntax, one `[submodule "name"]`
//! section per submodule, each carrying a `path` and a `url`.
//!
//! `.gitmodules` lives inside the repository, and a repository can come
//! from a remote server: every field this reads is untrusted input, the
//! same as a tree entry name is to `ziggit-checkout`. This file only
//! extracts what the text says; `update.zig` is what validates a
//! submodule's `path` before it is ever joined to a worktree path, and
//! what decides whether a submodule with no `url` is fatal.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fetch_mod = @import("ziggit-fetch");
const checkout_mod = @import("ziggit-checkout");

const config_mod = @import("ziggit-config");
const Config = config_mod.Config;

/// Every fault the whole `ziggit-submodule` surface can raise.
/// `InvalidSubmodulePath`, `SubmoduleTooDeep`, `RelativeUrlWithoutParentRemote`,
/// and `RelativeUrlEscapesRoot` are this module's own; the rest come from
/// fetching a submodule's history and checking out its tree. Declared here,
/// alongside `Submodule`, since `parseGitmodules` needs it and `update.zig`
/// reuses it rather than defining a second copy.
pub const Error = error{ InvalidSubmodulePath, SubmoduleTooDeep, RelativeUrlWithoutParentRemote, RelativeUrlEscapesRoot } || fetch_mod.Error || checkout_mod.Error;

pub const Submodule = struct {
    name: []const u8, // owned
    path: []const u8, // owned
    url: []const u8, // owned, empty when `.gitmodules` set no url

    pub fn deinit(s: *Submodule, gpa: Allocator) void {
        gpa.free(s.name);
        gpa.free(s.path);
        gpa.free(s.url);
        s.* = undefined;
    }
};

/// Longest a `submodule.<name>.path` or `submodule.<name>.url` lookup key
/// this builds on the stack can be. A defensive ceiling against a
/// hostile, absurdly long submodule name, not a spec limit: a name past
/// this is simply skipped, the same as one with no `path` at all.
const max_key_len: usize = 1024;

/// Parses `.gitmodules`, git config syntax, from a blob's bytes. Returns
/// one `Submodule` per `[submodule "name"]` section that carries a
/// `path`; a section with no `path` names nothing this project could
/// ever check out, so it is dropped here rather than handed back as a
/// `Submodule` with an unusable empty path. A section with no `url` is
/// still returned, with `url` empty: whether that is fatal is
/// `update.zig`'s call, made with a `diag` this function is not given.
///
/// Returned in ascending order by name: `Config.subsectionIterator`
/// itself makes no order promise, walking a hash map, so this sorts
/// explicitly rather than handing back an order that would otherwise
/// depend on hash bucket layout.
pub fn parseGitmodules(gpa: Allocator, bytes: []const u8) Error![]Submodule {
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, bytes, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = c.subsectionIterator(gpa, "submodule");
    defer it.deinit();
    while (try it.next()) |name| try names.append(gpa, name);
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var out: std.ArrayList(Submodule) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(gpa);
        out.deinit(gpa);
    }

    for (names.items) |name| {
        var path_key_buf: [max_key_len]u8 = undefined;
        const path_key = std.fmt.bufPrint(&path_key_buf, "submodule.{s}.path", .{name}) catch continue;
        const path = c.getString(path_key) orelse continue;

        var url_key_buf: [max_key_len]u8 = undefined;
        const url_key = std.fmt.bufPrint(&url_key_buf, "submodule.{s}.url", .{name}) catch continue;
        const url = c.getString(url_key) orelse "";

        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        const path_owned = try gpa.dupe(u8, path);
        errdefer gpa.free(path_owned);
        const url_owned = try gpa.dupe(u8, url);
        errdefer gpa.free(url_owned);

        try out.append(gpa, .{ .name = name_owned, .path = path_owned, .url = url_owned });
    }

    return out.toOwnedSlice(gpa);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

fn freeAll(gpa: Allocator, subs: []Submodule) void {
    for (subs) |*s| s.deinit(gpa);
    gpa.free(subs);
}

// expected

test "parseGitmodules reads the name, path and url of one submodule" {
    const gpa = testing.allocator;
    const bytes = "[submodule \"lib\"]\n\tpath = vendor/lib\n\turl = https://example.com/lib.git\n";
    const subs = try parseGitmodules(gpa, bytes);
    defer freeAll(gpa, subs);

    try testing.expectEqual(@as(usize, 1), subs.len);
    try testing.expectEqualStrings("lib", subs[0].name);
    try testing.expectEqualStrings("vendor/lib", subs[0].path);
    try testing.expectEqualStrings("https://example.com/lib.git", subs[0].url);
}

test "parseGitmodules reads several submodules" {
    const gpa = testing.allocator;
    const bytes =
        "[submodule \"a\"]\n\tpath = a\n\turl = https://example.com/a.git\n" ++
        "[submodule \"b\"]\n\tpath = nested/b\n\turl = https://example.com/b.git\n";
    const subs = try parseGitmodules(gpa, bytes);
    defer freeAll(gpa, subs);

    try testing.expectEqual(@as(usize, 2), subs.len);
    try testing.expectEqualStrings("a", subs[0].name);
    try testing.expectEqualStrings("a", subs[0].path);
    try testing.expectEqualStrings("b", subs[1].name);
    try testing.expectEqualStrings("nested/b", subs[1].path);
    try testing.expectEqualStrings("https://example.com/b.git", subs[1].url);
}

// suspicious

test "a submodule section with no path is dropped rather than returned with an empty path" {
    const gpa = testing.allocator;
    const bytes = "[submodule \"noPath\"]\n\turl = https://example.com/x.git\n";
    const subs = try parseGitmodules(gpa, bytes);
    defer freeAll(gpa, subs);
    try testing.expectEqual(@as(usize, 0), subs.len);
}

test "a submodule section with no url still returns an entry, url empty" {
    const gpa = testing.allocator;
    const bytes = "[submodule \"noUrl\"]\n\tpath = noUrl\n";
    const subs = try parseGitmodules(gpa, bytes);
    defer freeAll(gpa, subs);
    try testing.expectEqual(@as(usize, 1), subs.len);
    try testing.expectEqualStrings("noUrl", subs[0].name);
    try testing.expectEqualStrings("", subs[0].url);
}

test "a malformed .gitmodules is CorruptConfig" {
    const gpa = testing.allocator;
    try testing.expectError(error.CorruptConfig, parseGitmodules(gpa, "[submodule\n"));
}

test "a bracket inside a quoted url value does not fabricate a phantom submodule" {
    const gpa = testing.allocator;
    // The literal bytes on disk carry a `[` and a raw `"` inside this
    // url's own value; a scanner with no notion of "inside a value"
    // could mistake that for a second `[submodule "trap"]` header. It
    // finds no `path` for "trap", since none was ever really set, so no
    // phantom `Submodule` is produced.
    const bytes = "[submodule \"real\"]\n\tpath = real\n\turl = https://x/y[submodule \"trap\"]z\n";
    const subs = try parseGitmodules(gpa, bytes);
    defer freeAll(gpa, subs);
    try testing.expectEqual(@as(usize, 1), subs.len);
    try testing.expectEqualStrings("real", subs[0].name);
}
