//! The layered config store: every level's parsed values in one table,
//! read back by dotted name.
//!
//! A later `Level` always wins over an earlier one for `getString`,
//! `getBool`, and `getInt`; `getAll` ignores level and returns every value
//! ever added for a key, oldest first, since that is what a multivalue
//! key like `remote.origin.fetch` needs. A section name and a key name
//! compare case insensitively; a subsection name compares case
//! sensitively. Both rules come straight from git, not from us.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const parser_mod = @import("Parser.zig");
const include_mod = @import("include.zig");

/// Where one value came from. Precedence follows declaration order: a
/// `.command` value beats a `.worktree` one, which beats `.local`, and so
/// on, regardless of the order `addText`/`addFile` were called in.
pub const Level = enum { system, global, local, worktree, command };

/// Longest config file this reads in one call, `include`d files included.
/// A defensive ceiling against a hostile or accidentally huge file, not a
/// spec limit.
pub const max_config_file_len: std.Io.Limit = .limited(1 << 20);

/// Longest `name` this can look up without allocating. A dotted config
/// name is a handful of short words in real use; this is a defensive
/// ceiling, not a spec limit, and a longer `name` simply reads as not
/// found rather than erroring.
const max_lookup_key_len: usize = 1024;

/// Every value ever added for one canonical `(section, subsection, key)`,
/// in the order they were added. The three arrays stay index aligned.
const ValueList = struct {
    /// Owned by `ValueList`. `ValueList.deinit` frees each string once.
    /// `getString` and its siblings only borrow a string here. They never
    /// free one.
    texts: std.ArrayList([]const u8) = .empty,
    levels: std.ArrayList(Level) = .empty,
    /// True for a key line with no `=` at all, which `getBool` reads as
    /// true regardless of `texts[i]` (always the empty string for such a
    /// line).
    is_bare: std.ArrayList(bool) = .empty,

    fn deinit(vl: *ValueList, gpa: Allocator) void {
        for (vl.texts.items) |t| gpa.free(t);
        vl.texts.deinit(gpa);
        vl.levels.deinit(gpa);
        vl.is_bare.deinit(gpa);
        vl.* = undefined;
    }

    /// Index of the value that wins: the highest `Level`, and the last
    /// one added at that level when more than one line set the same key.
    /// Null when `vl` holds no value at all.
    fn winningIndex(vl: *const ValueList) ?usize {
        if (vl.levels.items.len == 0) return null;
        var best: usize = 0;
        for (vl.levels.items, 0..) |lvl, idx| {
            if (@intFromEnum(lvl) >= @intFromEnum(vl.levels.items[best])) best = idx;
        }
        return best;
    }
};

pub const Config = struct {
    pub const Error = error{ CorruptConfig, IncludeCycle, IoFailed } || std.mem.Allocator.Error;

    /// `chock` sets `GIT_CONFIG_SYSTEM=/dev/null` today by hiding the
    /// real file from the process; we give the caller an explicit flag
    /// instead. When `use_system` or `use_global` is false, `addFile`
    /// never opens that level's file at all.
    pub const Options = struct {
        use_system: bool = true,
        use_global: bool = true,
        /// The value of core.repositoryformatversion this build
        /// understands. `ziggit-config` only carries this; validating a
        /// repository's actual value against it is `ziggit-repo`'s job.
        max_format_version: u32 = 1,
    };

    /// Frees every stored string and the table itself; caller-owned
    /// otherwise.
    gpa: Allocator,
    entries: std.StringHashMapUnmanaged(ValueList) = .empty,
    /// Set directly before calling `addFile`. See `Options`.
    options: Options = .{},
    /// What an `includeIf "gitdir:…"` condition is matched against.
    /// Unset, no such condition ever matches: `ziggit-config` has no
    /// repository of its own to read a gitdir from. Set directly before
    /// calling `addFile`. Borrowed: `Config` never frees this string, so
    /// keep it alive across every `addFile` call.
    gitdir: ?[]const u8 = null,
    /// What an `includeIf "onbranch:…"` condition is matched against.
    /// Unset, no such condition ever matches. Borrowed: `Config` never
    /// frees this string, so keep it alive across every `addFile` call.
    branch: ?[]const u8 = null,

    pub fn init(gpa: Allocator) Config {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Config) void {
        var it = c.entries.iterator();
        while (it.next()) |kv| {
            c.gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit(c.gpa);
        }
        c.entries.deinit(c.gpa);
        c.* = undefined;
    }

    /// Parses `bytes` into `c` at `level`. Later levels win over earlier
    /// ones, regardless of call order. `addText` never follows
    /// `include.path` or `includeIf`, since raw text carries no directory
    /// to resolve a relative include against; use `addFile` for that.
    pub fn addText(c: *Config, level: Level, bytes: []const u8, diag: ?*?Diagnostic) Error!void {
        var entries: std.ArrayList(parser_mod.Entry) = .empty;
        // Only the backing array, never `entries.items[i]` itself:
        // `parser_mod.parse` leaves whatever it appended intact on error,
        // freed just below, and `insertEntries` always frees or stores
        // every entry it is handed, on either outcome.
        defer entries.deinit(c.gpa);
        parser_mod.parse(c.gpa, bytes, &entries) catch |err| {
            for (entries.items) |*e| e.deinit(c.gpa);
            if (err == error.CorruptConfig) reportCorrupt(diag, c.gpa, null, "malformed config text");
            return err;
        };
        try insertEntries(c, c.gpa, level, entries.items);
    }

    /// Reads `<dir>/<path>` and parses it into `c` at `level`, following
    /// any `include.path` or matching `includeIf` entry it names,
    /// resolved relative to the file that named it. A missing file is not
    /// an error: it is normal for a config level to have nothing on disk.
    ///
    /// When `level` is `.system` and `options.use_system` is false, or
    /// `level` is `.global` and `options.use_global` is false, this
    /// returns immediately without touching `dir` at all.
    pub fn addFile(c: *Config, io: std.Io, level: Level, dir: std.Io.Dir, path: []const u8, diag: ?*?Diagnostic) Error!void {
        if (level == .system and !c.options.use_system) return;
        if (level == .global and !c.options.use_global) return;

        var visited: std.ArrayList([]const u8) = .empty;
        defer visited.deinit(c.gpa);
        const ctx = include_mod.Context{ .gitdir = c.gitdir, .branch = c.branch };
        include_mod.load(c.gpa, io, dir, path, level, c, ctx, &visited, diag) catch |err| switch (err) {
            // Nothing on disk at this level is normal, not a fault.
            error.FileNotFound => return,
            error.IncludeCycle => return error.IncludeCycle,
            error.CorruptConfig => return error.CorruptConfig,
            error.IoFailed => return error.IoFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// `name` is the full dotted key, lowercased for section and key but
    /// case-sensitive for a subsection, which is how git compares them.
    /// Borrowed; valid until the next `addText`/`addFile` call or
    /// `deinit`.
    pub fn getString(c: *Config, name: []const u8) ?[]const u8 {
        const vl = c.find(name) orelse return null;
        const idx = vl.winningIndex() orelse return null;
        return vl.texts.items[idx];
    }

    pub fn getBool(c: *Config, name: []const u8) ?bool {
        const vl = c.find(name) orelse return null;
        const idx = vl.winningIndex() orelse return null;
        if (vl.is_bare.items[idx]) return true;
        return parseGitBool(vl.texts.items[idx]);
    }

    /// Honours a `k`, `m`, or `g` suffix (case insensitively) as a
    /// multiplier of 1024. Overflow, from a huge number with a `g`
    /// suffix, reads as not found rather than wrapping.
    pub fn getInt(c: *Config, name: []const u8) ?i64 {
        const s = c.getString(name) orelse return null;
        return parseGitInt(s);
    }

    /// Every value for a multivalue key, oldest first. Empty, never null,
    /// for a key nothing set. Borrowed the same way as `getString`.
    pub fn getAll(c: *Config, name: []const u8) []const []const u8 {
        const vl = c.find(name) orelse return &.{};
        return vl.texts.items;
    }

    fn find(c: *Config, name: []const u8) ?*const ValueList {
        const parts = splitName(name) orelse return null;
        var buf: [max_lookup_key_len]u8 = undefined;
        const key = canonicalKeyBuf(&buf, parts.section, parts.subsection, parts.key) orelse return null;
        return c.entries.getPtr(key);
    }

    /// Iterates the key names stored under `section`, optionally narrowed
    /// to one `subsection`, without exposing how `Config` stores a key
    /// internally. `section` must already be lower case; pass `null` for
    /// `subsection` to match only a key set outside any subsection. Order
    /// is unspecified. A caller that must refuse a key it does not
    /// recognize, rather than silently ignore it, walks this instead of
    /// depending on `Config`'s storage format.
    pub fn sectionKeyIterator(c: *Config, section: []const u8, subsection: ?[]const u8) SectionKeyIterator {
        return .{ .inner = c.entries.keyIterator(), .section = section, .subsection = subsection };
    }

    /// Iterates the distinct subsection names present under `section`,
    /// each yielded once regardless of how many keys it carries. `section`
    /// must already be lower case. Order is unspecified. A caller that
    /// must discover which subsections exist at all, rather than read the
    /// keys of one it already names, walks this instead of depending on
    /// `Config`'s storage format.
    ///
    /// Unlike `sectionKeyIterator`, this needs `gpa`: a subsection can
    /// carry more than one key (`remote.origin.url` and
    /// `remote.origin.fetch` both name the subsection "origin"), so
    /// yielding each subsection once needs a small owned set of names
    /// already returned, not a plain borrow-and-filter pass. Call
    /// `SubsectionIterator.deinit` when done.
    pub fn subsectionIterator(c: *Config, gpa: Allocator, section: []const u8) SubsectionIterator {
        return .{ .inner = c.entries.keyIterator(), .section = section, .gpa = gpa };
    }
};

/// Returned by `Config.sectionKeyIterator`. Borrowed: every name it
/// yields is valid until the next `addText`/`addFile` call or `deinit`,
/// the same lifetime `getString` promises.
///
/// `inner` holds raw pointers into the hash map's own backing storage. Do
/// not call `addText` or `addFile` while this iterator is still being
/// advanced: either call can move or free that storage, and the next
/// `.next()` call then reads freed memory.
pub const SectionKeyIterator = struct {
    inner: std.StringHashMapUnmanaged(ValueList).KeyIterator,
    section: []const u8,
    subsection: ?[]const u8,

    /// Next key name under the section (and subsection, if one was
    /// given), lower case, or `null` once none are left.
    pub fn next(it: *SectionKeyIterator) ?[]const u8 {
        while (it.inner.next()) |key_ptr| {
            const decoded = decodeKey(key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, decoded.section, it.section)) continue;
            if (it.subsection) |want| {
                if (decoded.subsection == null or !std.mem.eql(u8, decoded.subsection.?, want)) continue;
            } else if (decoded.subsection != null) {
                continue;
            }
            return decoded.key;
        }
        return null;
    }
};

/// Returned by `Config.subsectionIterator`. Every name it yields is
/// borrowed and valid until the next `addText`/`addFile` call or
/// `deinit` on `Config` itself, the same lifetime `getString` promises.
///
/// `inner` holds raw pointers into the hash map's own backing storage. Do
/// not call `addText` or `addFile` on the underlying `Config` while this
/// iterator is still being advanced: either call can move or free that
/// storage, and the next `.next()` call then reads freed memory.
pub const SubsectionIterator = struct {
    inner: std.StringHashMapUnmanaged(ValueList).KeyIterator,
    section: []const u8,
    gpa: Allocator,
    seen: std.ArrayList([]const u8) = .empty,

    /// Frees this iterator's own bookkeeping. Never touches `Config`
    /// itself or any string it yielded.
    pub fn deinit(it: *SubsectionIterator) void {
        it.seen.deinit(it.gpa);
        it.* = undefined;
    }

    /// Next subsection name under `section` not yet yielded, or `null`
    /// once none are left. Fails only if recording a newly seen name runs
    /// out of memory; the strings themselves are always borrowed, never
    /// allocated.
    pub fn next(it: *SubsectionIterator) Allocator.Error!?[]const u8 {
        while (it.inner.next()) |key_ptr| {
            const decoded = decodeKey(key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, decoded.section, it.section)) continue;
            const sub = decoded.subsection orelse continue;

            var already_seen = false;
            for (it.seen.items) |s| {
                if (std.mem.eql(u8, s, sub)) {
                    already_seen = true;
                    break;
                }
            }
            if (already_seen) continue;

            try it.seen.append(it.gpa, sub);
            return sub;
        }
        return null;
    }
};

/// Inserts every entry in `parsed` into `c` at `level`, freeing each
/// entry's `section`, `subsection`, and `key` once its canonical key is
/// built, and moving `value` into storage rather than copying it. Called
/// by `Config.addText` directly and by `include.zig` once per file it
/// reads, so an include's entries land at the same level as the file that
/// named them.
///
/// Consumes every entry in `parsed` no matter the outcome: on success all
/// are stored, on failure the one that failed and everything after it are
/// freed instead. A caller never needs to free `parsed` itself afterward,
/// only its own backing array.
pub fn insertEntries(c: *Config, gpa: Allocator, level: Level, parsed: []parser_mod.Entry) Allocator.Error!void {
    var idx: usize = 0;
    while (idx < parsed.len) : (idx += 1) {
        const e = &parsed[idx];
        const canon = canonicalKeyAlloc(gpa, e.section, e.subsection, e.key) catch |err| {
            freeRemaining(gpa, parsed[idx..]);
            return err;
        };
        const gop = c.entries.getOrPut(gpa, canon) catch |err| {
            gpa.free(canon);
            freeRemaining(gpa, parsed[idx..]);
            return err;
        };
        if (gop.found_existing) {
            gpa.free(canon);
        } else {
            gop.value_ptr.* = .{};
        }

        const reserved = blk: {
            gop.value_ptr.texts.ensureUnusedCapacity(gpa, 1) catch break :blk false;
            gop.value_ptr.levels.ensureUnusedCapacity(gpa, 1) catch break :blk false;
            gop.value_ptr.is_bare.ensureUnusedCapacity(gpa, 1) catch break :blk false;
            break :blk true;
        };
        if (!reserved) {
            freeRemaining(gpa, parsed[idx..]);
            return error.OutOfMemory;
        }

        gop.value_ptr.texts.appendAssumeCapacity(e.value);
        gop.value_ptr.levels.appendAssumeCapacity(level);
        gop.value_ptr.is_bare.appendAssumeCapacity(e.is_bare);

        gpa.free(e.section);
        if (e.subsection) |s| gpa.free(s);
        gpa.free(e.key);
    }
}

/// Frees every entry in `parsed`. Shared by `insertEntries`'s own error
/// paths and by `include.zig`, which needs the same cleanup for an entry
/// it decided not to store at all, for example a `includeIf` whose
/// condition did not match.
pub fn freeRemaining(gpa: Allocator, parsed: []parser_mod.Entry) void {
    for (parsed) |*e| e.deinit(gpa);
}

/// Reports `.corrupt_config`, the only `Diagnostic.Kind` that fits either
/// a malformed config or an include cycle; `ziggit-core` has no dedicated
/// kind for the latter.
pub fn reportCorrupt(diag: ?*?Diagnostic, gpa: Allocator, path: ?[]const u8, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = if (path) |p| gpa.dupe(u8, p) catch null else null;
    const detail_dup = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_config, .path = path_dup, .detail = detail_dup });
}

pub fn reportIo(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, path) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = path_dup, .detail = null });
}

const SplitName = struct { section: []const u8, subsection: ?[]const u8, key: []const u8 };

/// Splits a dotted `name` the way git's own lookup API does: the section
/// is everything before the first dot, the key is everything after the
/// last dot, and the subsection, if the two differ, is whatever sits
/// between them, dots and all. Null when `name` has no dot at all.
fn splitName(name: []const u8) ?SplitName {
    const first = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, name, '.').?;
    const subsection: ?[]const u8 = if (last > first) name[first + 1 .. last] else null;
    return .{ .section = name[0..first], .subsection = subsection, .key = name[last + 1 ..] };
}

/// Builds the same byte layout as `canonicalKeyAlloc`, without
/// allocating: `section` and `key` are lowercased on the fly, and
/// `subsection` is copied exactly. Null when `buf` is too small, which
/// `find` treats as "not found" rather than an error.
fn canonicalKeyBuf(buf: []u8, section: []const u8, subsection: ?[]const u8, key: []const u8) ?[]const u8 {
    var n: usize = 0;
    if (n + section.len >= buf.len) return null;
    for (section) |c| {
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    buf[n] = 0;
    n += 1;
    if (subsection) |s| {
        if (n + 1 + s.len >= buf.len) return null;
        buf[n] = 'S';
        n += 1;
        @memcpy(buf[n .. n + s.len], s);
        n += s.len;
    } else {
        if (n + 1 >= buf.len) return null;
        buf[n] = 'N';
        n += 1;
    }
    if (n >= buf.len) return null;
    buf[n] = 0;
    n += 1;
    if (n + key.len > buf.len) return null;
    for (key) |c| {
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// Owned counterpart of `canonicalKeyBuf`, used to store a key rather
/// than merely look one up. `section` and `key` are expected already
/// lower case, as `Parser.parse` produces them.
fn canonicalKeyAlloc(gpa: Allocator, section_lower: []const u8, subsection: ?[]const u8, key_lower: []const u8) Allocator.Error![]u8 {
    if (subsection) |s| {
        return std.fmt.allocPrint(gpa, "{s}\x00S{s}\x00{s}", .{ section_lower, s, key_lower });
    }
    return std.fmt.allocPrint(gpa, "{s}\x00N\x00{s}", .{ section_lower, key_lower });
}

const DecodedKey = struct { section: []const u8, subsection: ?[]const u8, key: []const u8 };

/// Splits a canonical key built by `canonicalKeyAlloc` back into its
/// three parts. `null` for a byte string that is not one of ours, which
/// cannot happen for a key actually stored in `entries` but keeps this
/// total rather than assuming its input.
fn decodeKey(canon: []const u8) ?DecodedKey {
    const first_nul = std.mem.indexOfScalar(u8, canon, 0) orelse return null;
    const section = canon[0..first_nul];
    const rest = canon[first_nul + 1 ..];
    if (rest.len == 0) return null;
    const marker = rest[0];
    const after_marker = rest[1..];
    const second_nul = std.mem.indexOfScalar(u8, after_marker, 0) orelse return null;
    const subsection_part = after_marker[0..second_nul];
    const key = after_marker[second_nul + 1 ..];
    const subsection: ?[]const u8 = switch (marker) {
        'S' => subsection_part,
        'N' => null,
        else => return null,
    };
    return .{ .section = section, .subsection = subsection, .key = key };
}

/// `true`, `yes`, `on`, `1` read as true; `false`, `no`, `off`, `0`, and
/// the empty string read as false, all case insensitively. Any other
/// text is not a recognized boolean and reads as not found.
fn parseGitBool(s: []const u8) ?bool {
    if (s.len == 0) return false;
    inline for (.{ "true", "yes", "on", "1" }) |t| {
        if (std.ascii.eqlIgnoreCase(s, t)) return true;
    }
    inline for (.{ "false", "no", "off", "0" }) |f| {
        if (std.ascii.eqlIgnoreCase(s, f)) return false;
    }
    return null;
}

fn parseGitInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var text = s;
    var mult: i64 = 1;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            mult = 1024;
            text = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            mult = 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            mult = 1024 * 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        else => {},
    }
    text = std.mem.trim(u8, text, " \t");
    const base = std.fmt.parseInt(i64, text, 10) catch return null;
    return std.math.mul(i64, base, mult) catch null;
}

// expected

test "getString reads a key from a plain section" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[core]\n\tbare = true\n", null);
    try std.testing.expectEqualStrings("true", c.getString("core.bare").?);
}

test "getString reads a key from a quoted subsection" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[user \"Alice Doe\"]\n\temail = alice@example.com\n", null);
    try std.testing.expectEqualStrings("alice@example.com", c.getString("user.Alice Doe.email").?);
}

test "a later level overrides an earlier one" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.system, "[core]\n\teditor = ed\n", null);
    try c.addText(.local, "[core]\n\teditor = vim\n", null);
    try std.testing.expectEqualStrings("vim", c.getString("core.editor").?);
}

test "getBool reads true, yes, on and 1 as true" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[a]\n\tw = true\n[b]\n\tx = yes\n[c]\n\ty = on\n[d]\n\tz = 1\n", null);
    try std.testing.expect(c.getBool("a.w").?);
    try std.testing.expect(c.getBool("b.x").?);
    try std.testing.expect(c.getBool("c.y").?);
    try std.testing.expect(c.getBool("d.z").?);
}

test "getBool reads an empty value as true" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    // A bare key, no `=` at all, is git's boolean true, not an empty
    // string: `[core]\n  bare =\n` (below) is the empty-string case, and
    // is false instead.
    try c.addText(.local, "[core]\n\tbare\n", null);
    try std.testing.expect(c.getBool("core.bare").?);
}

test "getInt reads 1k as 1024" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[core]\n\tbig = 1k\n", null);
    try std.testing.expectEqual(@as(i64, 1024), c.getInt("core.big").?);
}

test "getAll returns every value of a multivalue key in file order" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(
        .local,
        "[remote \"origin\"]\n" ++
            "\tfetch = +refs/heads/a:refs/remotes/origin/a\n" ++
            "\tfetch = +refs/heads/b:refs/remotes/origin/b\n",
        null,
    );
    const all = c.getAll("remote.origin.fetch");
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("+refs/heads/a:refs/remotes/origin/a", all[0]);
    try std.testing.expectEqualStrings("+refs/heads/b:refs/remotes/origin/b", all[1]);
}

test "sectionKeyIterator yields every key set in a plain section" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[extensions]\n\tobjectformat = sha256\n\tpreciousobjects = true\n", null);

    var seen_object_format = false;
    var seen_precious_objects = false;
    var count: usize = 0;
    var it = c.sectionKeyIterator("extensions", null);
    while (it.next()) |name| {
        count += 1;
        if (std.mem.eql(u8, name, "objectformat")) seen_object_format = true;
        if (std.mem.eql(u8, name, "preciousobjects")) seen_precious_objects = true;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(seen_object_format);
    try std.testing.expect(seen_precious_objects);
}

test "sectionKeyIterator only matches the subsection it was given" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[remote \"origin\"]\n\turl = a\n[remote \"upstream\"]\n\turl = b\n", null);

    var origin_it = c.sectionKeyIterator("remote", "origin");
    const origin_key = origin_it.next().?;
    try std.testing.expectEqualStrings("url", origin_key);
    try std.testing.expect(origin_it.next() == null);

    var bare_it = c.sectionKeyIterator("remote", null);
    try std.testing.expect(bare_it.next() == null);
}

test "subsectionIterator yields each distinct subsection under a section once" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    // "origin" carries two keys; a naive scan with no dedup would yield
    // it twice.
    try c.addText(
        .local,
        "[remote \"origin\"]\n\turl = a\n\tfetch = b\n[remote \"upstream\"]\n\turl = c\n[core]\n\tbare = true\n",
        null,
    );

    var it = c.subsectionIterator(gpa, "remote");
    defer it.deinit();

    var seen_origin: usize = 0;
    var seen_upstream: usize = 0;
    var count: usize = 0;
    while (try it.next()) |name| {
        count += 1;
        if (std.mem.eql(u8, name, "origin")) seen_origin += 1;
        if (std.mem.eql(u8, name, "upstream")) seen_upstream += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), seen_origin);
    try std.testing.expectEqual(@as(usize, 1), seen_upstream);
}

test "subsectionIterator finds nothing under a section with no subsections" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[core]\n\tbare = true\n", null);

    var it = c.subsectionIterator(gpa, "core");
    defer it.deinit();
    try std.testing.expect((try it.next()) == null);
}

// suspicious

test "section names compare case insensitively" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[Core]\n\tfoo = 1\n", null);
    try std.testing.expectEqualStrings("1", c.getString("core.foo").?);
    try std.testing.expectEqualStrings("1", c.getString("CORE.foo").?);
}

test "subsection names compare case sensitively" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[user \"Alice\"]\n\temail = a@x\n", null);
    try std.testing.expectEqualStrings("a@x", c.getString("user.Alice.email").?);
    try std.testing.expect(c.getString("user.alice.email") == null);
}

test "getBool reads bare = with nothing after the equals as false" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.addText(.local, "[core]\n\tbare =\n", null);
    try std.testing.expect(!c.getBool("core.bare").?);
}

test "use_system false ignores a system level file entirely" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Content that would fail to parse if this were ever read: the real
    // assertion is that `addFile` succeeds anyway, which it can only do
    // by never opening the file.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gitconfig", .data = "[core\n" });

    var c = Config.init(gpa);
    defer c.deinit();
    c.options.use_system = false;
    try c.addFile(std.testing.io, .system, tmp.dir, "gitconfig", null);
    try std.testing.expect(c.getString("core.anything") == null);
}

test "an include cycle fails with IncludeCycle rather than recursing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "[include]\n\tpath = b\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "[include]\n\tpath = a\n" });

    var c = Config.init(gpa);
    defer c.deinit();
    try std.testing.expectError(error.IncludeCycle, c.addFile(std.testing.io, .local, tmp.dir, "a", null));
}

// regression

test "a config level file that does not exist is not an error" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var c = Config.init(gpa);
    defer c.deinit();
    try c.addFile(std.testing.io, .local, tmp.dir, "does-not-exist", null);
    try std.testing.expect(c.getString("core.anything") == null);
}

test "a level added after a lower one still wins when added out of enum order" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    // The override test above adds `.local` after `.system`, so call order
    // and level order agree there. Here `.local` is added first and
    // `.system` second, so a regression that picked the winner by call
    // order instead of `Level`'s ordinal would pick `.system` and fail
    // this test.
    try c.addText(.local, "[core]\n\teditor = vim\n", null);
    try c.addText(.system, "[core]\n\teditor = ed\n", null);
    try std.testing.expectEqualStrings("vim", c.getString("core.editor").?);
}

test "load follows a plain include.path and the included value lands" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.conf",
        .data = "[include]\n\tpath = other.conf\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "other.conf",
        .data = "[user]\n\tname = included\n",
    });

    var c = Config.init(gpa);
    defer c.deinit();
    try c.addFile(std.testing.io, .local, tmp.dir, "main.conf", null);
    try std.testing.expectEqualStrings("included", c.getString("user.name").?);
}

test "load follows an includeIf gitdir entry that matches" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.conf",
        .data = "[includeIf \"gitdir:/home/ross/work/\"]\n\tpath = other.conf\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "other.conf",
        .data = "[found]\n\tvalue = yes\n",
    });

    var c = Config.init(gpa);
    defer c.deinit();
    c.gitdir = "/home/ross/work/sub/project";
    try c.addFile(std.testing.io, .local, tmp.dir, "main.conf", null);
    try std.testing.expectEqualStrings("yes", c.getString("found.value").?);
}

test "load skips an includeIf gitdir entry that does not match" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.conf",
        .data = "[includeIf \"gitdir:/home/ross/work/\"]\n\tpath = other.conf\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "other.conf",
        .data = "[found]\n\tvalue = yes\n",
    });

    var c = Config.init(gpa);
    defer c.deinit();
    c.gitdir = "/home/ross/elsewhere";
    try c.addFile(std.testing.io, .local, tmp.dir, "main.conf", null);
    try std.testing.expect(c.getString("found.value") == null);
}

test "load follows an includeIf onbranch entry that matches" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.conf",
        .data = "[includeIf \"onbranch:main\"]\n\tpath = other.conf\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "other.conf",
        .data = "[found]\n\tvalue = yes\n",
    });

    var c = Config.init(gpa);
    defer c.deinit();
    c.branch = "main";
    try c.addFile(std.testing.io, .local, tmp.dir, "main.conf", null);
    try std.testing.expectEqualStrings("yes", c.getString("found.value").?);
}

test "an include cycle with a diag names the file that closed the loop" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "[include]\n\tpath = b\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "[include]\n\tpath = a\n" });

    var c = Config.init(gpa);
    defer c.deinit();
    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.IncludeCycle, c.addFile(std.testing.io, .local, tmp.dir, "a", &diag));
    try std.testing.expect(diag != null);
    try std.testing.expectEqual(Diagnostic.Kind.corrupt_config, diag.?.kind);
    try std.testing.expectEqualStrings("a", diag.?.path.?);
    diag.?.deinit(gpa);
}

test "an include cycle with no diag allocates nothing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "[include]\n\tpath = b\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "[include]\n\tpath = a\n" });

    var c = Config.init(gpa);
    defer c.deinit();
    // `std.testing.allocator` panics on a leak at test teardown. Reaching
    // teardown clean, with `diag` null, is the proof that reporting a
    // cycle allocates nothing when no caller asked for detail.
    try std.testing.expectError(error.IncludeCycle, c.addFile(std.testing.io, .local, tmp.dir, "a", null));
}
