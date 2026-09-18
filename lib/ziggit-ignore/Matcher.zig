//! gitignore: which worktree paths git leaves untracked.
//!
//! Every rule below was measured against git 2.55 with `git check-ignore -v`,
//! which names the file, line and pattern that decided a path. The ones worth
//! stating up front, because each is silent when implemented wrongly:
//!
//! - **A pattern with no `/` matches a basename at any depth.** `*.log`
//!   ignores `deep/inside/f.log`. A pattern with a `/` anywhere but its end is
//!   anchored to the directory its file sits in, so `doc/*.txt` ignores
//!   `doc/a.txt` and never `sub/doc/b.txt`.
//! - **A trailing `/` means directories only**, and it ignores everything
//!   inside them.
//! - **The last matching pattern decides**, so a later `!name` re-includes.
//! - **A negation cannot re-include a file whose parent directory is
//!   excluded.** `excluded/` followed by `!excluded/keep.txt` still ignores
//!   `excluded/keep.txt`: git never descends into the directory, so the
//!   negation is never reached. This is the rule most often missed, and
//!   `isIgnored` implements it by testing every ancestor first.
//! - **`*` and `?` never cross a `/`.** `a?c` does not match `a/c`.
//! - **`**` spans directories**: `a/**/b` matches `a/x/y/b`.
//!
//! This module reads text and paths and nothing else. It has no object
//! database, no repository and no config: a caller supplies the patterns and
//! says where each set came from.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{} || Allocator.Error;

/// Allocation budget for one gitignore file. A real one is a handful of
/// kilobytes; this is a ceiling against a hostile one, not a spec limit.
pub const max_file_len: usize = 1 << 20;

/// One parsed line of a gitignore file.
const Pattern = struct {
    /// The pattern text, with the comment marker, the negation marker, the
    /// anchoring slash and the directory slash all removed, and any escapes
    /// resolved. Owned.
    text: []const u8,
    /// `!name`: this pattern re-includes rather than excludes.
    negated: bool,
    /// A trailing `/`: matches directories only.
    directory_only: bool,
    /// The pattern held a `/` somewhere other than its end, so it is matched
    /// against the whole path relative to `base` rather than against a
    /// basename.
    anchored: bool,
};

/// One gitignore file's patterns, and the directory its anchored patterns are
/// relative to.
const Source = struct {
    /// "" for the worktree root. Never has a leading or trailing `/`. Owned.
    base: []const u8,
    patterns: []Pattern,
};

pub const Matcher = struct {
    gpa: Allocator,
    /// In the order the caller added them, which must be lowest precedence
    /// first. `isIgnored` walks them backwards, so a source added later wins,
    /// and within one source the last matching pattern wins.
    ///
    /// Git's own precedence is by directory depth: a `sub/.gitignore` beats
    /// the worktree root's, which beats `.git/info/exclude`, which beats
    /// `core.excludesFile`. A caller that adds them in that order gets git's
    /// answer; one that does not, does not. Said here because nothing in this
    /// module can check it.
    sources: std.ArrayList(Source) = .empty,

    pub fn init(gpa: Allocator) Matcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Matcher) void {
        for (m.sources.items) |s| {
            for (s.patterns) |p| m.gpa.free(p.text);
            m.gpa.free(s.patterns);
            m.gpa.free(s.base);
        }
        m.sources.deinit(m.gpa);
        m.* = undefined;
    }

    /// Adds one gitignore file's text. `base` is the directory the file sits
    /// in, relative to the worktree root, with no leading or trailing `/`;
    /// pass "" for the root.
    pub fn addText(m: *Matcher, text: []const u8, base: []const u8) Error!void {
        var patterns: std.ArrayList(Pattern) = .empty;
        errdefer {
            for (patterns.items) |p| m.gpa.free(p.text);
            patterns.deinit(m.gpa);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const parsed = try parseLine(m.gpa, raw) orelse continue;
            errdefer m.gpa.free(parsed.text);
            try patterns.append(m.gpa, parsed);
        }

        const base_owned = try m.gpa.dupe(u8, base);
        errdefer m.gpa.free(base_owned);
        const owned = try patterns.toOwnedSlice(m.gpa);
        errdefer m.gpa.free(owned);
        try m.sources.append(m.gpa, .{ .base = base_owned, .patterns = owned });
    }

    /// Adds one gitignore FILE. A file that is not there adds nothing and
    /// is not an error: an absent `.gitignore` is the ordinary case, not a
    /// fault, and so is an absent `.git/info/exclude`.
    ///
    /// `max_file_len` bounds the read. A gitignore past it is refused rather
    /// than read, the same defensive ceiling every other reader here uses.
    pub fn addFile(
        m: *Matcher,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        base: []const u8,
    ) (Error || error{IoFailed})!void {
        const text = dir.readFileAlloc(io, path, m.gpa, .limited(max_file_len)) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.IoFailed,
        };
        defer m.gpa.free(text);
        try m.addText(text, base);
    }

    /// How many sources are loaded. Paired with `truncate`, this is how a
    /// walk adds a directory's own `.gitignore` on the way in and drops it
    /// on the way out, so a sibling directory never inherits it.
    pub fn sourceCount(m: *const Matcher) usize {
        return m.sources.items.len;
    }

    /// Drops every source added after `count`. A `count` at or above the
    /// current number does nothing, so an unbalanced restore cannot remove
    /// a source it did not add.
    pub fn truncate(m: *Matcher, count: usize) void {
        while (m.sources.items.len > count) {
            const s = m.sources.pop().?;
            for (s.patterns) |p| m.gpa.free(p.text);
            m.gpa.free(s.patterns);
            m.gpa.free(s.base);
        }
    }

    /// Whether git would leave `path` untracked. `path` is relative to the
    /// worktree root and uses `/` separators.
    ///
    /// **Every ancestor directory is tested first.** A file under an excluded
    /// directory is excluded whatever the patterns say about the file itself,
    /// because git never descends to look. Without this, a `!excluded/keep.txt`
    /// after `excluded/` would wrongly re-include it.
    pub fn isIgnored(m: *const Matcher, path: []const u8, is_dir: bool) bool {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| {
            if (m.decide(path[0..slash], true) == .ignored) return true;
            i = slash + 1;
        }
        return m.decide(path, is_dir) == .ignored;
    }

    const Decision = enum { ignored, included, unmatched };

    /// The last matching pattern in the highest-precedence source that has
    /// one. Sources are walked newest first, and each source's patterns are
    /// walked last first, because in both cases the later entry wins.
    fn decide(m: *const Matcher, path: []const u8, is_dir: bool) Decision {
        var si = m.sources.items.len;
        while (si > 0) {
            si -= 1;
            const source = m.sources.items[si];
            const relative = relativeTo(source.base, path) orelse continue;

            var pi = source.patterns.len;
            while (pi > 0) {
                pi -= 1;
                const p = source.patterns[pi];
                if (p.directory_only and !is_dir) continue;
                if (!patternMatches(p, relative)) continue;
                return if (p.negated) .included else .ignored;
            }
        }
        return .unmatched;
    }
};

/// `path` with `base` and its separator removed, or null when `path` is not
/// under `base`. A source only ever decides paths beneath its own directory.
fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (path.len <= base.len) return null;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

fn patternMatches(p: Pattern, relative: []const u8) bool {
    if (p.anchored) return matchPath(p.text, relative);
    // Unanchored patterns match a basename at any depth.
    const basename = if (std.mem.lastIndexOfScalar(u8, relative, '/')) |i|
        relative[i + 1 ..]
    else
        relative;
    return matchPath(p.text, basename);
}

/// Splits both sides on `/` and matches segment by segment, so `*` and `?`
/// cannot cross a separator: that fall-through is what makes `a?c` wrongly
/// match `a/c`.
///
/// A `**` segment matches zero or more whole segments, which is what lets
/// `a/**/b` reach `a/x/y/b`.
fn matchPath(pattern: []const u8, path: []const u8) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var pat_buf: [64][]const u8 = undefined;
    var pat_n: usize = 0;
    while (pat_it.next()) |seg| {
        if (pat_n == pat_buf.len) return false;
        pat_buf[pat_n] = seg;
        pat_n += 1;
    }

    var path_it = std.mem.splitScalar(u8, path, '/');
    var path_buf: [256][]const u8 = undefined;
    var path_n: usize = 0;
    while (path_it.next()) |seg| {
        if (path_n == path_buf.len) return false;
        path_buf[path_n] = seg;
        path_n += 1;
    }

    return matchSegments(pat_buf[0..pat_n], path_buf[0..path_n]);
}

fn matchSegments(pat: []const []const u8, path: []const []const u8) bool {
    if (pat.len == 0) return path.len == 0;

    if (std.mem.eql(u8, pat[0], "**")) {
        // In the middle, `**` matches zero or more segments, which is how
        // `a/**/b` reaches `a/x/y/b` and also plain `a/b`.
        //
        // At the END it needs at least one: git's `baz/**` matches
        // everything INSIDE `baz` and not `baz` itself. Returning true for
        // nothing left made the directory match its own contents rule, and
        // `git check-ignore` disagreed on exactly that path.
        if (pat.len == 1) return path.len > 0;
        var skip: usize = 0;
        while (skip <= path.len) : (skip += 1) {
            if (matchSegments(pat[1..], path[skip..])) return true;
        }
        return false;
    }

    if (path.len == 0) return false;
    if (!matchSegment(pat[0], path[0])) return false;
    return matchSegments(pat[1..], path[1..]);
}

/// One path component against one pattern component: `*`, `?` and `[...]`,
/// none of which can match a `/`, because neither side holds one here.
fn matchSegment(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // The most recent `*` and where the text had reached, so a failed match
    // can resume by giving the `*` one more character.
    var star: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star = p;
                    p += 1;
                    star_t = t;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                '[' => {
                    if (matchClass(pattern[p..], text[t])) |consumed| {
                        p += consumed;
                        t += 1;
                        continue;
                    }
                },
                else => {
                    if (pattern[p] == text[t]) {
                        p += 1;
                        t += 1;
                        continue;
                    }
                },
            }
        }
        if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
            continue;
        }
        return false;
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Matches `c` against a `[...]` class at the front of `pattern`, returning
/// how many bytes the class occupied, or null when it does not match or the
/// class is unterminated.
fn matchClass(pattern: []const u8, c: u8) ?usize {
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == ']' and !first) {
            if (matched != negate) return i + 1;
            return null;
        }
        first = false;
        // A range, `a-z`, unless the `-` is the last character before `]`.
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (c >= pattern[i] and c <= pattern[i + 2]) matched = true;
            i += 2;
            continue;
        }
        if (pattern[i] == c) matched = true;
    }
    // Unterminated: git treats the `[` as a literal, which this reports as no
    // class match so the caller compares it byte for byte.
    return null;
}

/// Parses one line. Returns null for a line that holds no pattern: blank, or a
/// comment.
fn parseLine(gpa: Allocator, raw: []const u8) Error!?Pattern {
    var line = raw;
    // A carriage return from a CRLF file is not part of the pattern.
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len == 0) return null;
    // `#` starts a comment; `\#` is a literal `#`.
    if (line[0] == '#') return null;

    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
        if (line.len == 0) return null;
    }

    // Trailing spaces are not part of the pattern unless escaped, which is
    // why `trailing   ` matches `trailing`.
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        // An odd number of backslashes before the space escapes it.
        var backslashes: usize = 0;
        var k = end - 1;
        while (k > 0 and line[k - 1] == '\\') : (k -= 1) backslashes += 1;
        if (backslashes % 2 == 1) break;
        end -= 1;
    }
    line = line[0..end];
    if (line.len == 0) return null;

    var directory_only = false;
    if (line[line.len - 1] == '/') {
        directory_only = true;
        line = line[0 .. line.len - 1];
        if (line.len == 0) return null;
    }

    // A `/` anywhere but the end anchors the pattern to its own directory. A
    // leading one anchors it and is not part of the text.
    var anchored = std.mem.indexOfScalar(u8, line, '/') != null;
    if (line.len > 0 and line[0] == '/') {
        anchored = true;
        line = line[1..];
        if (line.len == 0) return null;
    }

    return .{
        .text = try unescape(gpa, line),
        .negated = negated,
        .directory_only = directory_only,
        .anchored = anchored,
    };
}

/// Resolves `\x` to `x`, so `escaped\ space` matches a name holding a space
/// and `lit\!bang` matches a literal `!`. A trailing lone backslash is kept.
fn unescape(gpa: Allocator, text: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            try out.append(gpa, text[i]);
            continue;
        }
        try out.append(gpa, text[i]);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

/// Builds a matcher from one root-level gitignore text.
fn rootMatcher(gpa: Allocator, text: []const u8) !Matcher {
    var m = Matcher.init(gpa);
    errdefer m.deinit();
    try m.addText(text, "");
    return m;
}

test "a pattern with no slash matches a basename at any depth" {
    var m = try rootMatcher(testing.allocator, "*.log\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("f.log", false));
    try testing.expect(m.isIgnored("deep/inside/f.log", false));
    try testing.expect(!m.isIgnored("f.txt", false));
}

test "a pattern holding a slash is anchored to its own directory" {
    // Measured: `doc/*.txt` ignores `doc/a.txt` and never `sub/doc/b.txt`.
    var m = try rootMatcher(testing.allocator, "doc/*.txt\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("doc/a.txt", false));
    try testing.expect(!m.isIgnored("sub/doc/b.txt", false));
}

test "a leading slash anchors without being part of the name" {
    var m = try rootMatcher(testing.allocator, "/root-only.txt\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("root-only.txt", false));
    try testing.expect(!m.isIgnored("sub/root-only.txt", false));
}

test "a trailing slash matches directories only, and everything inside them" {
    var m = try rootMatcher(testing.allocator, "build/\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("build", true));
    try testing.expect(m.isIgnored("build/out.o", false));
    // The same name as a file is not a directory, so it is not matched.
    try testing.expect(!m.isIgnored("build", false));
}

test "the last matching pattern decides" {
    var m = try rootMatcher(testing.allocator, "*.log\n!keep.log\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("f.log", false));
    try testing.expect(!m.isIgnored("keep.log", false));
}

test "a negation cannot re-include a file under an excluded directory" {
    // The rule most often missed. Git reports `excluded/` as the deciding
    // pattern for `excluded/keep.txt`, not the negation, because it never
    // descends into the directory to reach it. Measured against git 2.55.
    var m = try rootMatcher(testing.allocator, "excluded/\n!excluded/keep.txt\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("excluded/keep.txt", false));
}

test "a star and a question mark never cross a separator" {
    var m = try rootMatcher(testing.allocator, "a?c\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("abc", false));
    try testing.expect(m.isIgnored("axc", false));
    // Measured: `a/c` is NOT ignored by `a?c`.
    try testing.expect(!m.isIgnored("a/c", false));
}

test "a double star spans directories" {
    var m = try rootMatcher(testing.allocator, "a/**/b\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("a/x/y/b", false));
    try testing.expect(m.isIgnored("a/b", false));
    try testing.expect(!m.isIgnored("z/x/b", false));
}

test "a trailing double star takes everything beneath it" {
    var m = try rootMatcher(testing.allocator, "logs/**\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("logs/one.txt", false));
    try testing.expect(m.isIgnored("logs/important/two.txt", false));
    try testing.expect(!m.isIgnored("other/one.txt", false));
}

test "a character class matches a set and a range" {
    var m = try rootMatcher(testing.allocator, "[Tt]emp\n[0-9].bin\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("Temp", false));
    try testing.expect(m.isIgnored("temp", false));
    try testing.expect(!m.isIgnored("Xemp", false));
    try testing.expect(m.isIgnored("7.bin", false));
    try testing.expect(!m.isIgnored("x.bin", false));
}

test "trailing spaces are dropped unless escaped" {
    var m = try rootMatcher(testing.allocator, "trailing   \nescaped\\ space\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("trailing", false));
    try testing.expect(m.isIgnored("escaped space", false));
}

test "a comment and a blank line hold no pattern" {
    var m = try rootMatcher(testing.allocator, "# a comment\n\n*.log\n");
    defer m.deinit();
    try testing.expect(!m.isIgnored("# a comment", false));
    try testing.expect(m.isIgnored("f.log", false));
}

test "an escaped bang is a literal, not a negation" {
    var m = try rootMatcher(testing.allocator, "lit\\!bang\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("lit!bang", false));
}

test "a deeper gitignore overrides a shallower one" {
    // Added lowest precedence first, which is the order this type documents.
    var m = Matcher.init(testing.allocator);
    defer m.deinit();
    try m.addText("*.txt\n", "");
    try m.addText("!important.txt\n", "sub");
    try m.addText("*.txt\n", "sub/deeper");

    try testing.expect(m.isIgnored("a.txt", false));
    try testing.expect(!m.isIgnored("sub/important.txt", false));
    try testing.expect(m.isIgnored("sub/other.txt", false));
    // The deepest file re-ignores what its parent had excepted.
    try testing.expect(m.isIgnored("sub/deeper/important.txt", false));
}

test "a source decides nothing outside its own directory" {
    var m = Matcher.init(testing.allocator);
    defer m.deinit();
    try m.addText("*.txt\n", "sub");
    try testing.expect(m.isIgnored("sub/a.txt", false));
    try testing.expect(!m.isIgnored("a.txt", false));
    try testing.expect(!m.isIgnored("other/a.txt", false));
}

test "a trailing double star matches what is inside, not the directory itself" {
    // `git check-ignore` disagreed with the first version of this on exactly
    // one path out of twenty-two: `baz/**` does not match `baz`.
    var m = try rootMatcher(testing.allocator, "baz/**\n");
    defer m.deinit();
    try testing.expect(!m.isIgnored("baz", true));
    try testing.expect(m.isIgnored("baz/x", true));
    try testing.expect(m.isIgnored("baz/x/f", false));
}

test "a bare double star still matches a top-level entry" {
    // The other side of the fix above: requiring a remaining segment must
    // not stop `**` on its own from matching anything at all.
    var m = try rootMatcher(testing.allocator, "**\n");
    defer m.deinit();
    try testing.expect(m.isIgnored("f", false));
    try testing.expect(m.isIgnored("sub/f", false));
}
