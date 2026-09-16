//! The lexer and parser for one config buffer: git's INI dialect, not a
//! generic one.
//!
//! A section name and a key name are folded to lower case here, since git
//! compares both case insensitively; a subsection name is kept exactly as
//! written, since git compares it case sensitively. `Config.zig` decides
//! what the parsed entries mean across levels and includes; this file only
//! turns bytes into a flat, ordered list of them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One `key = value` line, with the section and subsection it appeared
/// under. `section` and `key` are owned, lower case. `subsection` is
/// owned, exact case, null when the line's section had none. `value` is
/// owned, already unescaped and unquoted; empty for a bare key, which
/// `is_bare` tells apart from a key explicitly set to the empty string.
pub const Entry = struct {
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
    value: []const u8,
    is_bare: bool,

    /// Frees every owned field. Call this on an `Entry` this file
    /// produced that no caller went on to store, for example one
    /// `Config.zig` consumed by acting on an `include` directive instead
    /// of keeping.
    pub fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.section);
        if (e.subsection) |s| gpa.free(s);
        gpa.free(e.key);
        gpa.free(e.value);
        e.* = undefined;
    }
};

pub const Error = error{CorruptConfig} || Allocator.Error;

/// Parses `bytes` and appends one `Entry` per `key = value` (or bare key)
/// line to `entries`, in file order. A key line before any section header,
/// a `[section` with no closing `]`, an unterminated quoted string, and an
/// unrecognized backslash escape are all `error.CorruptConfig`.
///
/// On error, every `Entry` already appended to `entries` is left intact
/// for the caller to free; this frees only what it has not yet handed
/// over.
pub fn parse(gpa: Allocator, bytes: []const u8, entries: *std.ArrayList(Entry)) Error!void {
    var current_section: ?[]u8 = null;
    var current_subsection: ?[]u8 = null;
    defer if (current_section) |s| gpa.free(s);
    defer if (current_subsection) |s| gpa.free(s);

    var i: usize = 0;
    while (true) {
        while (i < bytes.len and isBlank(bytes[i])) i += 1;
        if (i >= bytes.len) break;

        if (bytes[i] == '#' or bytes[i] == ';') {
            i = skipToEol(bytes, i);
            continue;
        }

        if (bytes[i] == '[') {
            i += 1;
            try parseSectionHeader(gpa, bytes, &i, &current_section, &current_subsection);
            i = skipToEol(bytes, i);
            continue;
        }

        if (current_section == null) return error.CorruptConfig;

        const key_start = i;
        while (i < bytes.len and isKeyChar(bytes[i])) i += 1;
        if (i == key_start) return error.CorruptConfig;
        const key_lower = try toLowerOwned(gpa, bytes[key_start..i]);
        errdefer gpa.free(key_lower);

        while (i < bytes.len and isSpaceOrTab(bytes[i])) i += 1;

        var is_bare = true;
        var value: []u8 = undefined;
        if (i < bytes.len and bytes[i] == '=') {
            is_bare = false;
            i += 1;
            while (i < bytes.len and isSpaceOrTab(bytes[i])) i += 1;
            value = try scanValue(gpa, bytes, &i);
        } else {
            value = try gpa.dupe(u8, "");
        }
        errdefer gpa.free(value);

        if (i < bytes.len and bytes[i] != '\n' and bytes[i] != '\r' and bytes[i] != '#' and bytes[i] != ';') {
            return error.CorruptConfig;
        }
        i = skipToEol(bytes, i);

        const section_dup = try gpa.dupe(u8, current_section.?);
        errdefer gpa.free(section_dup);
        const subsection_dup: ?[]u8 = if (current_subsection) |s| try gpa.dupe(u8, s) else null;
        errdefer if (subsection_dup) |s| gpa.free(s);

        try entries.append(gpa, .{
            .section = section_dup,
            .subsection = subsection_dup,
            .key = key_lower,
            .value = value,
            .is_bare = is_bare,
        });
    }
}

/// Parses the inside of `[section]` or `[section "sub"]`, `i` already past
/// the opening `[`. Replaces `*section` and `*subsection` with freshly
/// owned copies, freeing whatever they held before.
fn parseSectionHeader(
    gpa: Allocator,
    bytes: []const u8,
    i: *usize,
    section: *?[]u8,
    subsection: *?[]u8,
) Error!void {
    const name_start = i.*;
    while (i.* < bytes.len and isSectionNameChar(bytes[i.*])) i.* += 1;
    if (i.* == name_start) return error.CorruptConfig;
    const name_lower = try toLowerOwned(gpa, bytes[name_start..i.*]);
    errdefer gpa.free(name_lower);

    while (i.* < bytes.len and isSpaceOrTab(bytes[i.*])) i.* += 1;

    var sub: ?[]u8 = null;
    errdefer if (sub) |s| gpa.free(s);
    if (i.* < bytes.len and bytes[i.*] == '"') {
        i.* += 1;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        while (true) {
            if (i.* >= bytes.len or bytes[i.*] == '\n') return error.CorruptConfig;
            const c = bytes[i.*];
            if (c == '"') {
                i.* += 1;
                break;
            }
            if (c == '\\') {
                if (i.* + 1 >= bytes.len) return error.CorruptConfig;
                const esc = bytes[i.* + 1];
                const actual: u8 = switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    else => return error.CorruptConfig,
                };
                try buf.append(gpa, actual);
                i.* += 2;
                continue;
            }
            try buf.append(gpa, c);
            i.* += 1;
        }
        sub = try buf.toOwnedSlice(gpa);
        while (i.* < bytes.len and isSpaceOrTab(bytes[i.*])) i.* += 1;
    }

    if (i.* >= bytes.len or bytes[i.*] != ']') return error.CorruptConfig;
    i.* += 1;

    if (section.*) |s| gpa.free(s);
    section.* = name_lower;
    if (subsection.*) |s| gpa.free(s);
    subsection.* = sub;
}

/// Scans a value starting at `i.*`, up to (not including) an unescaped
/// end of line or an unquoted `#`/`;` comment, and advances `i.*` past it.
/// Leading whitespace has already been skipped by the caller; trailing
/// unquoted whitespace is trimmed here, but a quoted value keeps its own
/// leading and trailing spaces since a quote suspends trimming while it
/// is open.
fn scanValue(gpa: Allocator, bytes: []const u8, i: *usize) Error![]u8 {
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(gpa);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var in_quotes = false;

    while (i.* < bytes.len) {
        const c = bytes[i.*];
        if (in_quotes) {
            if (c == '"') {
                in_quotes = false;
                i.* += 1;
                continue;
            }
            if (c == '\n') return error.CorruptConfig;
            if (c == '\\') {
                if (i.* + 1 >= bytes.len) return error.CorruptConfig;
                const esc = bytes[i.* + 1];
                const actual: u8 = switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    else => return error.CorruptConfig,
                };
                try value.append(gpa, actual);
                i.* += 2;
                continue;
            }
            try value.append(gpa, c);
            i.* += 1;
            continue;
        }

        if (c == '\n' or c == '\r' or c == '#' or c == ';') break;
        if (c == '"') {
            in_quotes = true;
            i.* += 1;
            continue;
        }
        if (c == '\\') {
            if (i.* + 1 < bytes.len and bytes[i.* + 1] == '\n') {
                i.* += 2;
                continue;
            }
            if (i.* + 2 < bytes.len and bytes[i.* + 1] == '\r' and bytes[i.* + 2] == '\n') {
                i.* += 3;
                continue;
            }
            return error.CorruptConfig;
        }
        if (c == ' ' or c == '\t') {
            try pending.append(gpa, c);
            i.* += 1;
            continue;
        }
        if (pending.items.len != 0) {
            try value.appendSlice(gpa, pending.items);
            pending.clearRetainingCapacity();
        }
        try value.append(gpa, c);
        i.* += 1;
    }
    if (in_quotes) return error.CorruptConfig;
    return value.toOwnedSlice(gpa);
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isSectionNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn toLowerOwned(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// Advances to the index of the line's `\n`, or to `bytes.len` if the
/// buffer ends first. Does not consume the `\n` itself.
fn skipToEol(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len and bytes[i] != '\n') i += 1;
    return i;
}

fn deinitEntries(gpa: Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |*e| e.deinit(gpa);
    entries.deinit(gpa);
}

// expected

test "parse reads a plain key from a section" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tbare = true\n", &entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("core", entries.items[0].section);
    try std.testing.expect(entries.items[0].subsection == null);
    try std.testing.expectEqualStrings("bare", entries.items[0].key);
    try std.testing.expectEqualStrings("true", entries.items[0].value);
    try std.testing.expect(!entries.items[0].is_bare);
}

test "parse reads a quoted subsection exactly as written" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[user \"Alice Doe\"]\n\temail = alice@example.com\n", &entries);
    try std.testing.expectEqualStrings("Alice Doe", entries.items[0].subsection.?);
}

test "parse marks a bare key as bare with an empty value" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tbare\n", &entries);
    try std.testing.expect(entries.items[0].is_bare);
    try std.testing.expectEqualStrings("", entries.items[0].value);
}

// suspicious

test "parse lower cases the section and key but not the subsection" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[Core]\n\tBare = 1\n", &entries);
    try std.testing.expectEqualStrings("core", entries.items[0].section);
    try std.testing.expectEqualStrings("bare", entries.items[0].key);
}

test "a value continued with a trailing backslash joins the next line" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = abc\\\ndef\n", &entries);
    try std.testing.expectEqualStrings("abcdef", entries.items[0].value);
}

test "a quoted value keeps its leading and trailing spaces" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = \"  hi  \"\n", &entries);
    try std.testing.expectEqualStrings("  hi  ", entries.items[0].value);
}

test "an escaped quote inside a quoted value is kept" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = \"a\\\"b\"\n", &entries);
    try std.testing.expectEqualStrings("a\"b", entries.items[0].value);
}

test "an escaped \\n in a value becomes a newline" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = \"a\\nb\"\n", &entries);
    try std.testing.expectEqualStrings("a\nb", entries.items[0].value);
}

test "a comment after a value is not part of the value" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = bar # comment\n", &entries);
    try std.testing.expectEqualStrings("bar", entries.items[0].value);
}

test "a semicolon comment is stripped" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = bar ; comment\n", &entries);
    try std.testing.expectEqualStrings("bar", entries.items[0].value);
}

test "a # inside a quoted value is not a comment" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try parse(gpa, "[core]\n\tfoo = \"a#b\"\n", &entries);
    try std.testing.expectEqualStrings("a#b", entries.items[0].value);
}

test "a section header with no closing bracket is CorruptConfig" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try std.testing.expectError(error.CorruptConfig, parse(gpa, "[core\n\tfoo = 1\n", &entries));
}

test "a key line before any section header is CorruptConfig" {
    const gpa = std.testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    try std.testing.expectError(error.CorruptConfig, parse(gpa, "foo = 1\n", &entries));
}
