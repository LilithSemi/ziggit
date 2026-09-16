//! Render and edit config files on disk. This module operates on raw bytes,
//! never on the merged in-memory Config object, to avoid collapsing multiple
//! config files into one.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Render a config file from a list of section/key/value entries.
/// Owned result. Caller frees with gpa.free(result).
pub fn renderEntries(
    gpa: Allocator,
    entries: []const Entry,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    var last_section: ?[]const u8 = null;
    var last_subsection: ?[]const u8 = null;

    for (entries) |e| {
        const section_changed = last_section == null or !std.mem.eql(u8, last_section.?, e.section);
        const subsection_same = (last_subsection == null and e.subsection == null) or
            (last_subsection != null and e.subsection != null and std.mem.eql(u8, last_subsection.?, e.subsection.?));
        const subsection_changed = !subsection_same;

        if (section_changed or subsection_changed) {
            if (last_section != null) {
                try buf.append(gpa, '\n');
            }
            try buf.append(gpa, '[');
            try buf.appendSlice(gpa, e.section);
            if (e.subsection) |sub| {
                try buf.appendSlice(gpa, " \"");
                try buf.appendSlice(gpa, sub);
                try buf.append(gpa, '"');
            }
            try buf.appendSlice(gpa, "]\n");
        }

        try buf.append(gpa, '\t');
        try buf.appendSlice(gpa, e.key);
        if (!e.is_bare) {
            try buf.appendSlice(gpa, " = ");
            try buf.appendSlice(gpa, e.value);
        }
        try buf.append(gpa, '\n');

        last_section = e.section;
        last_subsection = e.subsection;
    }

    return buf.toOwnedSlice(gpa);
}

/// Entry to write. Section, subsection, key, value, and whether this is a bare
/// key (no `=` at all). This is a simple structure for renderEntries input.
/// Does not own its strings (unlike the Parser's Entry).
pub const Entry = struct {
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
    value: []const u8,
    is_bare: bool = false,
};

// tests

test "render single entry in plain section" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .section = "core", .subsection = null, .key = "bare", .value = "true", .is_bare = false },
    };
    const result = try renderEntries(gpa, entries[0..]);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("[core]\n\tbare = true\n", result);
}

test "render entry in subsection" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .section = "remote", .subsection = "origin", .key = "url", .value = "https://github.com/example/repo", .is_bare = false },
    };
    const result = try renderEntries(gpa, entries[0..]);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("[remote \"origin\"]\n\turl = https://github.com/example/repo\n", result);
}

test "render multiple entries in same section" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .section = "core", .subsection = null, .key = "bare", .value = "false", .is_bare = false },
        .{ .section = "core", .subsection = null, .key = "logallrefupdates", .value = "true", .is_bare = false },
    };
    const result = try renderEntries(gpa, entries[0..]);
    defer gpa.free(result);
    const expected = "[core]\n\tbare = false\n\tlogallrefupdates = true\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "render bare key without value" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .section = "core", .subsection = null, .key = "worktreeConfig", .value = "", .is_bare = true },
    };
    const result = try renderEntries(gpa, entries[0..]);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("[core]\n\tworktreeConfig\n", result);
}

/// A key that appears more than once in one section is `AmbiguousKey`, and
/// the file is not changed. Git refuses the same case, saying it "cannot
/// overwrite multiple values with a single value", so replacing one of them
/// or both would quietly disagree with the tool a person checks the result
/// with.
pub const EditError = error{ CorruptConfig, AmbiguousKey } || Allocator.Error;

/// The section a header line opens. `subsection` is the text inside the
/// quotes, when the header carries one.
const Header = struct {
    section: []const u8,
    subsection: ?[]const u8,
};

/// What one line declares. A line can declare both, because a section
/// header and a key on one line is legal: `[core] bare = true` is a file
/// git reads without complaint.
const Line = struct {
    header: ?Header = null,
    /// Offset just past the header's `]`, inside the line.
    header_end: usize = 0,
    key: ?[]const u8 = null,
    /// Offset where the key's text starts, inside the line.
    key_at: usize = 0,
};

fn isSectionNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

fn isKeyNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Reads one line and reports the section it opens and the key it defines.
/// A blank line and a comment line declare neither.
fn classifyLine(line: []const u8) error{CorruptConfig}!Line {
    var out: Line = .{};
    var i: usize = 0;
    while (i < line.len and isBlank(line[i])) i += 1;
    if (i >= line.len or line[i] == '#' or line[i] == ';') return out;

    if (line[i] == '[') {
        const close = std.mem.indexOfScalarPos(u8, line, i, ']') orelse return error.CorruptConfig;
        const inside = line[i + 1 .. close];

        var name_end: usize = 0;
        while (name_end < inside.len and isSectionNameChar(inside[name_end])) name_end += 1;
        // `[ core ]` is not legal. Git refuses the whole file with "bad
        // config line", so a space where the name must start is corrupt
        // rather than something to trim.
        if (name_end == 0) return error.CorruptConfig;

        var header: Header = .{ .section = inside[0..name_end], .subsection = null };
        var j = name_end;
        while (j < inside.len and isBlank(inside[j])) j += 1;
        if (j < inside.len) {
            if (inside[j] != '"') return error.CorruptConfig;
            const quote_end = std.mem.indexOfScalarPos(u8, inside, j + 1, '"') orelse return error.CorruptConfig;
            header.subsection = inside[j + 1 .. quote_end];
        }
        out.header = header;
        out.header_end = close + 1;

        i = close + 1;
        while (i < line.len and isBlank(line[i])) i += 1;
        if (i >= line.len or line[i] == '#' or line[i] == ';') return out;
    }

    var key_end = i;
    while (key_end < line.len and isKeyNameChar(line[key_end])) key_end += 1;
    if (key_end == i) return error.CorruptConfig;
    out.key = line[i..key_end];
    out.key_at = i;
    return out;
}

/// Git compares a section name without case, and a subsection with case.
/// Encoded here so the rule sits in one place.
fn sameSection(current: ?Header, section: []const u8, subsection: ?[]const u8) bool {
    const cur = current orelse return false;
    if (!std.ascii.eqlIgnoreCase(cur.section, section)) return false;
    if (cur.subsection == null and subsection != null) return false;
    if (cur.subsection != null and subsection == null) return false;
    if (cur.subsection) |cs| {
        if (!std.mem.eql(u8, cs, subsection.?)) return false;
    }
    return true;
}

/// A key line in the target section whose key name matches. Git compares
/// a key name without case too.
fn sameTarget(
    current: ?Header,
    line_key: []const u8,
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
) bool {
    if (!sameSection(current, section, subsection)) return false;
    return std.ascii.eqlIgnoreCase(line_key, key);
}

const Span = struct { start: usize, end: usize };

/// Walks `bytes` one line at a time. `end` excludes the newline, so a file
/// with no final newline needs no special case at the call site.
const LineWalker = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(w: *LineWalker) ?Span {
        if (w.at >= w.bytes.len) return null;
        const start = w.at;
        var end = start;
        while (end < w.bytes.len and w.bytes[end] != '\n') end += 1;
        w.at = if (end < w.bytes.len) end + 1 else end;
        return .{ .start = start, .end = end };
    }
};

/// Sets one key in one file's text, and returns the new text. `value` of
/// null removes the key.
///
/// Every byte this does not have to change is kept: comments, blank lines,
/// key order, indentation and unrelated sections all survive. The key's own
/// line is rewritten as git rewrites it, which drops a trailing comment on
/// that line and puts a section header that shared the line back on a line
/// of its own. Both were measured against git 2.55.
///
/// A key that is not there is added to its section, and a section that is
/// not there is added at the end, which is what git does.
///
/// **This never renders from `Config`.** `Config` merges the system, global
/// and local files, so rendering it back would collapse three files into one
/// and copy a person's global settings into their repository. This works on
/// one file's bytes and nothing else.
///
/// Caller owns the result.
pub fn setKeyInFile(
    gpa: Allocator,
    bytes: []const u8,
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
    value: ?[]const u8,
) EditError![]const u8 {
    var match_count: usize = 0;
    var match_span: Span = .{ .start = 0, .end = 0 };
    var match_line: Line = .{};

    {
        var current: ?Header = null;
        var walker: LineWalker = .{ .bytes = bytes };
        while (walker.next()) |span| {
            const info = try classifyLine(bytes[span.start..span.end]);
            if (info.header) |h| current = h;
            if (info.key) |k| {
                if (sameTarget(current, k, section, subsection, key)) {
                    match_count += 1;
                    match_span = span;
                    match_line = info;
                }
            }
        }
    }

    if (match_count > 1) return error.AmbiguousKey;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (match_count == 1) {
        try out.appendSlice(gpa, bytes[0..match_span.start]);
        if (match_line.header != null) {
            const line = bytes[match_span.start..match_span.end];
            try out.appendSlice(gpa, line[0..match_line.header_end]);
            try out.append(gpa, '\n');
        }
        if (value) |v| {
            try out.append(gpa, '\t');
            try out.appendSlice(gpa, key);
            try out.appendSlice(gpa, " = ");
            try out.appendSlice(gpa, v);
            try out.appendSlice(gpa, bytes[match_span.end..]);
        } else {
            // Drop the line and the newline that ended it, so removing a
            // key does not leave an empty line behind.
            const after = if (match_span.end < bytes.len) match_span.end + 1 else match_span.end;
            try out.appendSlice(gpa, bytes[after..]);
        }
        return out.toOwnedSlice(gpa);
    }

    try out.appendSlice(gpa, bytes);
    if (value == null) return out.toOwnedSlice(gpa);

    // The key is absent. Put it in its section when that section is there,
    // and start the section at the end when it is not.
    var section_end: ?usize = null;
    {
        var current: ?Header = null;
        var walker: LineWalker = .{ .bytes = bytes };
        while (walker.next()) |span| {
            const info = try classifyLine(bytes[span.start..span.end]);
            if (info.header) |h| {
                // A new header closes the section before it.
                if (section_end == null and current != null and
                    sameSection(current, section, subsection))
                {
                    section_end = span.start;
                }
                current = h;
            }
        }
        if (section_end == null and current != null and
            sameSection(current, section, subsection))
        {
            section_end = bytes.len;
        }
    }

    if (section_end) |at| {
        var insert: std.ArrayList(u8) = .empty;
        defer insert.deinit(gpa);
        try insert.append(gpa, '\t');
        try insert.appendSlice(gpa, key);
        try insert.appendSlice(gpa, " = ");
        try insert.appendSlice(gpa, value.?);
        try insert.append(gpa, '\n');

        out.clearRetainingCapacity();
        try out.appendSlice(gpa, bytes[0..at]);
        if (at > 0 and bytes[at - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, insert.items);
        try out.appendSlice(gpa, bytes[at..]);
        return out.toOwnedSlice(gpa);
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    try out.append(gpa, '[');
    try out.appendSlice(gpa, section);
    if (subsection) |sub| {
        try out.appendSlice(gpa, " \"");
        try out.appendSlice(gpa, sub);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]\n\t");
    try out.appendSlice(gpa, key);
    try out.appendSlice(gpa, " = ");
    try out.appendSlice(gpa, value.?);
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

// Editing tests. Every case below asserts the WHOLE resulting text, never
// that the text contains something: a containment check passes even when
// the editor mangled every byte around the match, which is the one thing
// these tests exist to catch.

const expectEdit = struct {
    fn run(src: []const u8, section: []const u8, sub: ?[]const u8, key: []const u8, value: ?[]const u8, want: []const u8) !void {
        const gpa = std.testing.allocator;
        const got = try setKeyInFile(gpa, src, section, sub, key, value);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
}.run;

test "an existing key's value is replaced" {
    try expectEdit(
        "[core]\n\tbare = false\n",
        "core",
        null,
        "bare",
        "true",
        "[core]\n\tbare = true\n",
    );
}

test "a key is added to a section that already exists" {
    try expectEdit(
        "[core]\n\tbare = false\n",
        "core",
        null,
        "filemode",
        "true",
        "[core]\n\tbare = false\n\tfilemode = true\n",
    );
}

test "a key whose section is absent starts a new section at the end" {
    try expectEdit(
        "[core]\n\tbare = false\n",
        "remote",
        "origin",
        "url",
        "https://example.com/r.git",
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://example.com/r.git\n",
    );
}

test "a key is added to an existing subsection" {
    try expectEdit(
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = u\n",
        "remote",
        "origin",
        "fetch",
        "+refs/heads/*:refs/remotes/origin/*",
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = u\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
    );
}

test "a comment, a blank line and an unrelated section survive byte for byte" {
    try expectEdit(
        "# a leading comment\n[core]\n\tbare = false\n\n\t; indented comment\n\tfilemode = true\n[other]\n\tkeep = untouched\n",
        "core",
        null,
        "bare",
        "true",
        "# a leading comment\n[core]\n\tbare = true\n\n\t; indented comment\n\tfilemode = true\n[other]\n\tkeep = untouched\n",
    );
}

test "a blank line inside a section is not swallowed when a later key changes" {
    // The first version of this editor walked lines and parsed entries in
    // lockstep, one entry per line. A blank line advanced the entry index
    // without being an entry, so the two drifted apart and the blank line
    // was deleted outright.
    try expectEdit(
        "[core]\n\tfirst = 1\n\n\tsecond = 2\n",
        "core",
        null,
        "second",
        "CHANGED",
        "[core]\n\tfirst = 1\n\n\tsecond = CHANGED\n",
    );
}

test "a key that appears twice is refused and the file is not changed" {
    // Git refuses this too: "cannot overwrite multiple values with a single
    // value", exit 5, file untouched. Replacing one of them, or both, would
    // quietly disagree with the tool a person checks the result with.
    const gpa = std.testing.allocator;
    const src = "[core]\n\tdupe = first\n\tdupe = second\n";
    try std.testing.expectError(
        error.AmbiguousKey,
        setKeyInFile(gpa, src, "core", null, "dupe", "new"),
    );
}

test "a section header sharing a line with its key is split, as git splits it" {
    // `[core] bare = false` is a file git reads without complaint, and
    // rewriting the key moves the header onto its own line. Measured.
    try expectEdit(
        "[core] bare = false\n",
        "core",
        null,
        "bare",
        "true",
        "[core]\n\tbare = true\n",
    );
}

test "a file with no trailing newline keeps its shape when a key is replaced" {
    try expectEdit(
        "[core]\n\tbare = false",
        "core",
        null,
        "bare",
        "true",
        "[core]\n\tbare = true",
    );
}

test "a file with no trailing newline gains one when a key is appended" {
    try expectEdit(
        "[core]\n\tbare = false",
        "core",
        null,
        "filemode",
        "true",
        "[core]\n\tbare = false\n\tfilemode = true\n",
    );
}

test "a key name and a section name match without case, a subsection with case" {
    try expectEdit(
        "[CORE]\n\tBARE = false\n",
        "core",
        null,
        "bare",
        "true",
        "[CORE]\n\tbare = true\n",
    );
    // A subsection differing only in case is a DIFFERENT subsection, so
    // this adds one rather than editing the existing entry.
    try expectEdit(
        "[remote \"Origin\"]\n\turl = u\n",
        "remote",
        "origin",
        "url",
        "v",
        "[remote \"Origin\"]\n\turl = u\n[remote \"origin\"]\n\turl = v\n",
    );
}

test "a value of null removes the key and its line" {
    try expectEdit(
        "[core]\n\tbare = false\n\tfilemode = true\n",
        "core",
        null,
        "bare",
        null,
        "[core]\n\tfilemode = true\n",
    );
}

test "a header with a space before the section name is refused" {
    // `[ core ]` is not legal. Git refuses the whole file with "bad config
    // line", so this is corruption rather than something to trim.
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.CorruptConfig,
        setKeyInFile(gpa, "[ core ]\n\tbare = false\n", "core", null, "bare", "true"),
    );
}
