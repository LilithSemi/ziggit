//! `include.path` and `includeIf.<condition>.path` resolution: reading an
//! included file relative to the file that named it, evaluating a
//! `gitdir:` or `onbranch:` condition, and refusing to follow a cycle.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const parser_mod = @import("Parser.zig");
const config_mod = @import("Config.zig");

/// What the caller currently knows about the running repository, used to
/// decide whether an `includeIf` condition applies. `ziggit-config` has
/// no repository of its own to read these from: an unset field means the
/// matching condition kind never matches.
pub const Context = struct {
    gitdir: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const Error = error{ FileNotFound, IncludeCycle, CorruptConfig, IoFailed } || Allocator.Error;

/// Recursion never nests deeper than this. A real config tree is one or
/// two hops; this is a defensive ceiling against a cycle the
/// visited-path check somehow missed, not a spec limit.
const max_depth: usize = 16;

/// Reads and parses the config file `<dir>/<path>`, inserts its entries
/// into `c` at `level`, and follows any `include.path` or matching
/// `includeIf.<condition>.path` entry it finds, depth first, in file
/// order.
///
/// `visited` names every file currently open on the include stack; a
/// `path` already in it, or a stack `max_depth` deep, is a cycle and
/// fails with `error.IncludeCycle` rather than recursing. The caller owns
/// `visited` and must pass an empty list on the first call.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    level: config_mod.Level,
    c: *config_mod.Config,
    ctx: Context,
    visited: *std.ArrayList([]const u8),
    diag: ?*?Diagnostic,
) Error!void {
    if (visited.items.len >= max_depth) {
        config_mod.reportCorrupt(diag, gpa, path, "include depth exceeded, likely a cycle");
        return error.IncludeCycle;
    }
    for (visited.items) |v| {
        if (std.mem.eql(u8, v, path)) {
            config_mod.reportCorrupt(diag, gpa, path, "include cycle: file already open on the include stack");
            return error.IncludeCycle;
        }
    }

    const bytes = dir.readFileAlloc(io, path, gpa, config_mod.max_config_file_len) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        config_mod.reportIo(diag, gpa, path);
        return error.IoFailed;
    };
    defer gpa.free(bytes);

    var entries: std.ArrayList(parser_mod.Entry) = .empty;
    defer entries.deinit(gpa);
    parser_mod.parse(gpa, bytes, &entries) catch |err| {
        for (entries.items) |*e| e.deinit(gpa);
        if (err == error.CorruptConfig) config_mod.reportCorrupt(diag, gpa, path, "malformed config file");
        return err;
    };

    const owned_path = try gpa.dupe(u8, path);
    visited.append(gpa, owned_path) catch |err| {
        gpa.free(owned_path);
        return err;
    };
    defer {
        _ = visited.pop();
        gpa.free(owned_path);
    }

    var idx: usize = 0;
    while (idx < entries.items.len) : (idx += 1) {
        const entry = &entries.items[idx];
        const is_include = std.mem.eql(u8, entry.section, "include") and
            entry.subsection == null and std.mem.eql(u8, entry.key, "path");
        const is_include_if = std.mem.eql(u8, entry.section, "includeif") and
            entry.subsection != null and std.mem.eql(u8, entry.key, "path");

        if (is_include or is_include_if) {
            const should_follow = if (is_include) true else conditionMatches(entry.subsection.?, ctx);
            if (!should_follow) {
                entry.deinit(gpa);
                continue;
            }

            const inc_path = resolveIncludePath(gpa, path, entry.value) catch |err| {
                entry.deinit(gpa);
                config_mod.freeRemaining(gpa, entries.items[idx + 1 ..]);
                return err;
            };
            entry.deinit(gpa);

            load(gpa, io, dir, inc_path, level, c, ctx, visited, diag) catch |err| {
                gpa.free(inc_path);
                config_mod.freeRemaining(gpa, entries.items[idx + 1 ..]);
                return err;
            };
            gpa.free(inc_path);
            continue;
        }

        config_mod.insertEntries(c, gpa, level, entry[0..1]) catch |err| {
            config_mod.freeRemaining(gpa, entries.items[idx + 1 ..]);
            return err;
        };
    }
}

/// Resolves `include_value` against the file that named it: unchanged
/// when it starts with `/`, since an absolute path names itself; otherwise
/// joined onto `including_path`'s own directory, since git resolves a
/// relative `include.path` relative to the including file, not relative
/// to the process's working directory.
fn resolveIncludePath(gpa: Allocator, including_path: []const u8, include_value: []const u8) Allocator.Error![]u8 {
    if (include_value.len > 0 and include_value[0] == '/') {
        return gpa.dupe(u8, include_value);
    }
    if (parentOf(including_path)) |parent| {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent, include_value });
    }
    return gpa.dupe(u8, include_value);
}

fn parentOf(path_str: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path_str, '/') orelse return null;
    return path_str[0..slash];
}

/// True when `condition` (the includeIf subsection, for example
/// `gitdir:/home/ross/work/` or `onbranch:main`) applies given `ctx`. An
/// unrecognized condition kind never matches.
fn conditionMatches(condition: []const u8, ctx: Context) bool {
    if (std.mem.startsWith(u8, condition, "gitdir:")) {
        const gitdir = ctx.gitdir orelse return false;
        return gitdirMatches(condition["gitdir:".len..], gitdir);
    }
    if (std.mem.startsWith(u8, condition, "onbranch:")) {
        const branch = ctx.branch orelse return false;
        return std.mem.eql(u8, branch, condition["onbranch:".len..]);
    }
    return false;
}

/// `pattern` matches `gitdir` either exactly, or, when `pattern` ends in
/// `/`, at `gitdir` itself or anywhere below it: `"/home/ross/work/"`
/// matches `/home/ross/work` and every path that starts with
/// `/home/ross/work/`.
fn gitdirMatches(pattern: []const u8, gitdir: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/")) {
        if (std.mem.eql(u8, gitdir, pattern[0 .. pattern.len - 1])) return true;
        return std.mem.startsWith(u8, gitdir, pattern);
    }
    return std.mem.eql(u8, gitdir, pattern);
}

// expected

test "includeIf gitdir matches with a trailing slash meaning any depth" {
    try std.testing.expect(gitdirMatches("/home/ross/work/", "/home/ross/work"));
    try std.testing.expect(gitdirMatches("/home/ross/work/", "/home/ross/work/sub/project"));
    try std.testing.expect(!gitdirMatches("/home/ross/work/", "/home/ross/other"));
}

// suspicious

test "includeIf gitdir without a trailing slash matches only exactly" {
    try std.testing.expect(gitdirMatches("/home/ross/work", "/home/ross/work"));
    try std.testing.expect(!gitdirMatches("/home/ross/work", "/home/ross/work/sub"));
}

test "includeIf onbranch matches the exact branch name" {
    try std.testing.expect(std.mem.eql(u8, "main", "main"));
    try std.testing.expect(conditionMatches("onbranch:main", .{ .branch = "main" }));
    try std.testing.expect(!conditionMatches("onbranch:main", .{ .branch = "dev" }));
}

test "an unset context never matches gitdir or onbranch" {
    try std.testing.expect(!conditionMatches("gitdir:/home/ross/work/", .{}));
    try std.testing.expect(!conditionMatches("onbranch:main", .{}));
}
