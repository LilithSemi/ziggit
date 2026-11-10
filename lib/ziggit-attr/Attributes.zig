//! `.gitattributes` parsing and lookup.
//!
//! Precedence, measured rather than read: `$GIT_DIR/info/attributes` is
//! highest and beats even a `.gitattributes` in the path's own directory.
//! Below it, the nearer `.gitattributes` wins over a further one, and
//! within one file the last matching line wins. Each attribute resolves on
//! its own, so one file can decide `text` while another decides `eol`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const ignore_mod = @import("ziggit-ignore");

const convert_mod = @import("convert.zig");
const Eol = convert_mod.Eol;

pub const Error = error{IoFailed} || Allocator.Error;

/// The largest attributes file this reads. Matches `ziggit-ignore`'s own
/// ceiling for the same kind of file.
pub const max_file_len: usize = 1 << 20;

/// What a line says about one attribute name.
const Value = union(enum) {
    set,
    unset,
    /// `!name`, which puts the attribute back to having no opinion.
    unspecified,
    string: []const u8, // borrowed from the source text
};

const Assignment = struct {
    name: []const u8, // borrowed from the source text
    value: Value,
};

const Line = struct {
    pattern: []const u8, // borrowed from the source text
    anchored: bool,
    assignments: []Assignment, // owned
};

/// One attributes file: its lines and the directory its patterns are
/// relative to.
const Source = struct {
    /// "" for the worktree root. Never has a leading or trailing `/`.
    base: []const u8, // owned
    text: []u8, // owned, every borrowed slice above points into this
    lines: []Line, // owned
    /// How deep the file sits. `info/attributes` uses `info_depth` so it
    /// sorts above every tree file.
    depth: usize,
};

/// `info/attributes` outranks every `.gitattributes`, so it is given a
/// depth no directory can reach.
const info_depth: usize = std.math.maxInt(usize);

pub const TextSetting = enum { unspecified, set, unset, auto };

/// What one path's attributes say, before config is folded in.
pub const PathAttrs = struct {
    text: TextSetting = .unspecified,
    eol: ?Eol = null,
    working_tree_encoding: ?[]const u8 = null,
    ident: bool = false,
    /// The named clean/smudge driver. This library runs none of them.
    filter: ?[]const u8 = null,
};

pub const Attributes = struct {
    gpa: Allocator,
    sources: std.ArrayList(Source),
    /// `[attr]name a b c` definitions, expanded one level deep.
    macros: std.ArrayList(Line),

    pub fn init(gpa: Allocator) Attributes {
        return .{ .gpa = gpa, .sources = .empty, .macros = .empty };
    }

    pub fn deinit(a: *Attributes) void {
        for (a.sources.items) |s| {
            a.gpa.free(s.base);
            a.gpa.free(s.text);
            for (s.lines) |l| a.gpa.free(l.assignments);
            a.gpa.free(s.lines);
        }
        a.sources.deinit(a.gpa);
        for (a.macros.items) |m| a.gpa.free(m.assignments);
        a.macros.deinit(a.gpa);
        a.* = undefined;
    }

    /// Adds one attributes file's text. `base` is the directory it sits in,
    /// relative to the worktree root, "" for the root itself.
    pub fn addText(a: *Attributes, text: []const u8, base: []const u8) Error!void {
        return a.addTextDepth(text, base, depthOf(base));
    }

    /// Adds `$GIT_DIR/info/attributes`, which outranks every
    /// `.gitattributes` whatever directory it sits in.
    pub fn addInfoText(a: *Attributes, text: []const u8) Error!void {
        return a.addTextDepth(text, "", info_depth);
    }

    fn addTextDepth(a: *Attributes, text: []const u8, base: []const u8, depth: usize) Error!void {
        const owned_text = try a.gpa.dupe(u8, text);
        errdefer a.gpa.free(owned_text);
        const owned_base = try a.gpa.dupe(u8, base);
        errdefer a.gpa.free(owned_base);

        var lines: std.ArrayList(Line) = .empty;
        errdefer {
            for (lines.items) |l| a.gpa.free(l.assignments);
            lines.deinit(a.gpa);
        }

        var it = std.mem.splitScalar(u8, owned_text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.startsWith(u8, line, "[attr]")) {
                const parsed = try a.parseLine(line["[attr]".len..]) orelse continue;
                try a.macros.append(a.gpa, parsed);
                continue;
            }
            const parsed = try a.parseLine(line) orelse continue;
            try lines.append(a.gpa, parsed);
        }

        try a.sources.append(a.gpa, .{
            .base = owned_base,
            .text = owned_text,
            .lines = try lines.toOwnedSlice(a.gpa),
            .depth = depth,
        });
    }

    /// Splits `pattern attr...`. Answers null for a line naming no
    /// attributes, which says nothing and is not worth keeping.
    fn parseLine(a: *Attributes, line: []const u8) Error!?Line {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const pattern = fields.next() orelse return null;

        var assignments: std.ArrayList(Assignment) = .empty;
        errdefer assignments.deinit(a.gpa);
        while (fields.next()) |token| {
            try assignments.append(a.gpa, parseAssignment(token));
        }
        if (assignments.items.len == 0) {
            assignments.deinit(a.gpa);
            return null;
        }

        // A pattern holding a slash anywhere but its end is matched
        // against the whole relative path, the same rule gitignore uses.
        const trimmed = std.mem.trimEnd(u8, pattern, "/");
        const slash = std.mem.indexOfScalar(u8, trimmed, '/');
        return .{
            .pattern = std.mem.trimStart(u8, pattern, "/"),
            .anchored = slash != null,
            .assignments = try assignments.toOwnedSlice(a.gpa),
        };
    }

    /// Resolves every attribute this library acts on for `path`, which is
    /// relative to the worktree root and uses `/` separators.
    pub fn lookup(a: *const Attributes, path: []const u8) PathAttrs {
        var out: PathAttrs = .{};

        if (a.resolve(path, "text")) |v| out.text = switch (v) {
            .set => .set,
            .unset => .unset,
            .unspecified => .unspecified,
            .string => |s| if (std.mem.eql(u8, s, "auto")) .auto else .unspecified,
        };
        if (a.resolve(path, "eol")) |v| switch (v) {
            .string => |s| {
                if (std.mem.eql(u8, s, "lf")) out.eol = .lf;
                if (std.mem.eql(u8, s, "crlf")) out.eol = .crlf;
            },
            else => {},
        };
        if (a.resolve(path, "working-tree-encoding")) |v| switch (v) {
            .string => |s| out.working_tree_encoding = s,
            else => {},
        };
        if (a.resolve(path, "ident")) |v| out.ident = v == .set;
        if (a.resolve(path, "filter")) |v| switch (v) {
            .string => |s| out.filter = s,
            else => {},
        };
        return out;
    }

    /// The winning value for one attribute name, or null when nothing sets
    /// it. Sources are walked highest depth first, and each source's lines
    /// last first, because the later line wins.
    fn resolve(a: *const Attributes, path: []const u8, name: []const u8) ?Value {
        var best: ?Value = null;
        var best_depth: ?usize = null;

        for (a.sources.items) |source| {
            if (best_depth) |bd| {
                if (source.depth < bd) continue;
            }
            const relative = relativeTo(source.base, path) orelse continue;

            var li = source.lines.len;
            while (li > 0) {
                li -= 1;
                const line = source.lines[li];
                if (!ignore_mod.matchesPattern(line.pattern, relative, line.anchored)) continue;
                if (a.valueIn(line, name)) |v| {
                    // Equal depth means a later source of the same rank,
                    // which this never has: one directory holds one file.
                    best = v;
                    best_depth = source.depth;
                    break;
                }
            }
        }
        return best;
    }

    /// The value `line` gives `name`, directly or through a macro it
    /// names. Macros expand one level: a macro naming another macro is not
    /// followed, which real attribute files do not do.
    fn valueIn(a: *const Attributes, line: Line, name: []const u8) ?Value {
        var i = line.assignments.len;
        while (i > 0) {
            i -= 1;
            const as = line.assignments[i];
            if (std.mem.eql(u8, as.name, name)) return as.value;
            if (builtinMacro(as.name, name)) |v| return v;
            for (a.macros.items) |macro| {
                if (!std.mem.eql(u8, macro.pattern, as.name)) continue;
                var mi = macro.assignments.len;
                while (mi > 0) {
                    mi -= 1;
                    if (std.mem.eql(u8, macro.assignments[mi].name, name)) {
                        return macro.assignments[mi].value;
                    }
                }
            }
        }
        return null;
    }
    /// How many attribute files have been added. A walk records this before it
    /// descends and hands it back to `truncate` on the way out, the same shape
    /// `ziggit-ignore`'s `Matcher` uses.
    pub fn sourceCount(a: *const Attributes) usize {
        return a.sources.items.len;
    }

    /// Drops every source added after `count`, so a sibling directory never
    /// inherits a rule written for another one.
    pub fn truncate(a: *Attributes, count: usize) void {
        while (a.sources.items.len > count) {
            const s = a.sources.pop().?;
            a.gpa.free(s.base);
            a.gpa.free(s.text);
            for (s.lines) |l| a.gpa.free(l.assignments);
            a.gpa.free(s.lines);
        }
    }

    /// Adds `name` out of `dir` when it is there. A missing file is not an
    /// error: most directories have no attributes file.
    pub fn addFile(
        a: *Attributes,
        io: std.Io,
        dir: std.Io.Dir,
        name: []const u8,
        base: []const u8,
    ) Error!void {
        const text = dir.readFileAlloc(io, name, a.gpa, .limited(max_file_len)) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.IoFailed,
        };
        defer a.gpa.free(text);
        try a.addText(text, base);
    }
};

/// Git's one built-in macro. `git check-attr -a` on `* binary` reports
/// `binary: set, diff: unset, merge: unset, text: unset`.
fn builtinMacro(macro_name: []const u8, wanted: []const u8) ?Value {
    if (!std.mem.eql(u8, macro_name, "binary")) return null;
    for ([_][]const u8{ "text", "diff", "merge" }) |n| {
        if (std.mem.eql(u8, wanted, n)) return .unset;
    }
    return null;
}

fn parseAssignment(token: []const u8) Assignment {
    if (token.len == 0) return .{ .name = token, .value = .set };
    if (token[0] == '-') return .{ .name = token[1..], .value = .unset };
    if (token[0] == '!') return .{ .name = token[1..], .value = .unspecified };
    if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
        return .{ .name = token[0..eq], .value = .{ .string = token[eq + 1 ..] } };
    }
    return .{ .name = token, .value = .set };
}

/// How many directories deep `base` sits. The worktree root is zero, so a
/// nearer file always has the higher number.
fn depthOf(base: []const u8) usize {
    if (base.len == 0) return 0;
    return std.mem.count(u8, base, "/") + 1;
}

/// `path` with `base` and its separator removed, or null when `path` is not
/// under `base`.
fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (path.len <= base.len) return null;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

pub const Autocrlf = enum { off, on, input };

/// The two core config values that decide line endings for a path no
/// attribute speaks for.
pub const CoreConfig = struct {
    autocrlf: Autocrlf = .off,
    /// `core.eol`. `native` is LF on every platform this builds for, so a
    /// caller maps it to `.lf` before it gets here.
    eol: ?Eol = null,
};

/// What to actually do with one path's bytes.
pub const Plan = struct {
    kind: convert_mod.TextKind,
    worktree_eol: Eol,
    ident: bool,
    encoding: ?[]const u8,
    /// A clean/smudge driver this library cannot run.
    filter: ?[]const u8,
};

/// Folds config under the attributes.
///
/// Text-ness: `-text` is binary, `text` is forced text, `text=auto` is
/// content-decided, and a path no attribute speaks for is content-decided
/// when `core.autocrlf` is on or input, and left alone otherwise.
///
/// The worktree ending, measured rather than assumed, because two of these
/// went the other way in the first attempt:
///
/// 1. A path-level `eol=` wins outright, even over `core.autocrlf`.
/// 2. Otherwise `core.autocrlf` decides and **overrides `core.eol`
///    entirely**: `true` gives CRLF even with `core.eol=lf`, and `input`
///    gives LF even with `core.eol=crlf`.
/// 3. `core.eol` decides only when `core.autocrlf` is off.
/// 4. LF otherwise.
///
/// `core.eol` alone does nothing to a path that is not text, which falls
/// out of `kind` rather than needing its own rule.
pub fn plan(attrs: PathAttrs, cfg: CoreConfig) Plan {
    const kind: convert_mod.TextKind = switch (attrs.text) {
        .unset => .binary,
        .set => .text,
        .auto => .auto,
        .unspecified => switch (cfg.autocrlf) {
            .on, .input => .auto,
            .off => .unset,
        },
    };

    const worktree_eol: Eol = attrs.eol orelse switch (cfg.autocrlf) {
        .on => .crlf,
        .input => .lf,
        .off => cfg.eol orelse .lf,
    };

    return .{
        .kind = kind,
        .worktree_eol = worktree_eol,
        .ident = attrs.ident,
        .encoding = attrs.working_tree_encoding,
        .filter = attrs.filter,
    };
}

const testing = std.testing;

test "the last matching line in a file wins" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("* text\n*.bin -text\n", "");

    // Measured: x.bin keeps CRLF while y.txt is converted.
    try testing.expectEqual(TextSetting.unset, a.lookup("x.bin").text);
    try testing.expectEqual(TextSetting.set, a.lookup("y.txt").text);
}

test "a nearer gitattributes beats a further one" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("* text\n", "");
    try a.addText("* -text\n", "d");

    // Measured: top.txt converted, d/in.txt kept, d/e/deep.txt kept.
    try testing.expectEqual(TextSetting.set, a.lookup("top.txt").text);
    try testing.expectEqual(TextSetting.unset, a.lookup("d/in.txt").text);
    try testing.expectEqual(TextSetting.unset, a.lookup("d/e/deep.txt").text);
}

test "info attributes outrank even a gitattributes in the path's own directory" {
    const gpa = testing.allocator;
    // The first draft of this spec had this precedence the wrong way
    // round. Measured both ways: `info/attributes` wins either way, and it
    // beats a `.gitattributes` sitting beside the path.
    {
        var a = Attributes.init(gpa);
        defer a.deinit();
        try a.addText("* text\n", "");
        try a.addInfoText("* -text\n");
        try testing.expectEqual(TextSetting.unset, a.lookup("f.txt").text);
    }
    {
        var a = Attributes.init(gpa);
        defer a.deinit();
        try a.addText("* -text\n", "");
        try a.addInfoText("* text\n");
        try testing.expectEqual(TextSetting.set, a.lookup("f.txt").text);
    }
    {
        var a = Attributes.init(gpa);
        defer a.deinit();
        try a.addInfoText("* -text\n");
        try a.addText("* text\n", "d");
        try testing.expectEqual(TextSetting.unset, a.lookup("d/f.txt").text);
    }
}

test "each attribute resolves on its own" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("* text\n", "");
    try a.addText("* eol=crlf\n", "d");

    // The deeper file speaks only for `eol`, so `text` still comes from
    // the root rather than being wiped out with it.
    const attrs = a.lookup("d/f.txt");
    try testing.expectEqual(TextSetting.set, attrs.text);
    try testing.expectEqual(Eol.crlf, attrs.eol.?);
}

test "the binary macro unsets text" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("* binary\n", "");
    // Measured: `git check-attr -a` on `* binary` reports `text: unset`,
    // and a CRLF file stays CRLF with autocrlf true.
    try testing.expectEqual(TextSetting.unset, a.lookup("f.bin").text);
}

test "a user macro expands one level" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("[attr]mine -text ident\n*.dat mine\n", "");
    const attrs = a.lookup("x.dat");
    try testing.expectEqual(TextSetting.unset, attrs.text);
    try testing.expect(attrs.ident);
}

test "a filter driver is reported by name" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    // The one line that declares a repository uses Git LFS.
    try a.addText("*.psd filter=lfs diff=lfs merge=lfs -text\n", "");
    const attrs = a.lookup("art/logo.psd");
    try testing.expectEqualStrings("lfs", attrs.filter.?);
    try testing.expectEqual(TextSetting.unset, attrs.text);
    try testing.expect(a.lookup("README.md").filter == null);
}

test "comments and blank lines say nothing" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("# a comment\n\n   \n* text\n", "");
    try testing.expectEqual(TextSetting.set, a.lookup("f.txt").text);
}

test "a bang value puts an attribute back to having no opinion" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("* text\nf.txt !text\n", "");
    try testing.expectEqual(TextSetting.unspecified, a.lookup("f.txt").text);
    try testing.expectEqual(TextSetting.set, a.lookup("g.txt").text);
}

test "an anchored pattern matches a whole path, an unanchored one a basename" {
    const gpa = testing.allocator;
    var a = Attributes.init(gpa);
    defer a.deinit();
    try a.addText("d/f.txt text\n", "");
    try testing.expectEqual(TextSetting.set, a.lookup("d/f.txt").text);
    try testing.expectEqual(TextSetting.unspecified, a.lookup("e/f.txt").text);

    var b = Attributes.init(gpa);
    defer b.deinit();
    try b.addText("f.txt text\n", "");
    try testing.expectEqual(TextSetting.set, b.lookup("deep/down/f.txt").text);
}

test "plan without attributes follows core.autocrlf" {
    // Measured: autocrlf true turns an LF blob into CRLF on the way out
    // and a CRLF worktree file into LF on the way in. autocrlf input
    // normalises going in and writes LF going out. Unset does neither.
    const none: PathAttrs = .{};

    const on = plan(none, .{ .autocrlf = .on });
    try testing.expectEqual(convert_mod.TextKind.auto, on.kind);
    try testing.expectEqual(Eol.crlf, on.worktree_eol);

    const input = plan(none, .{ .autocrlf = .input });
    try testing.expectEqual(convert_mod.TextKind.auto, input.kind);
    try testing.expectEqual(Eol.lf, input.worktree_eol);

    const off = plan(none, .{ .autocrlf = .off });
    try testing.expectEqual(convert_mod.TextKind.unset, off.kind);
}

test "a path level eol beats core.eol and core.autocrlf" {
    // Measured: `* text eol=lf` with autocrlf true writes LF.
    const p = plan(.{ .text = .set, .eol = .lf }, .{ .autocrlf = .on, .eol = .crlf });
    try testing.expectEqual(Eol.lf, p.worktree_eol);
    try testing.expectEqual(convert_mod.TextKind.text, p.kind);
}

test "core.eol decides a text path when no attribute names an ending" {
    // Measured: `* text` with core.eol=crlf writes CRLF.
    const p = plan(.{ .text = .set }, .{ .eol = .crlf });
    try testing.expectEqual(Eol.crlf, p.worktree_eol);
}

test "a binary path is never translated whatever the config says" {
    // Measured: `* -text` with autocrlf true and core.eol crlf leaves an
    // LF blob as LF.
    const p = plan(.{ .text = .unset }, .{ .autocrlf = .on, .eol = .crlf });
    try testing.expectEqual(convert_mod.TextKind.binary, p.kind);
    try testing.expect(!convert_mod.smudgeTranslates(p.kind, "a\nb\n"));
    try testing.expect(!convert_mod.cleanTranslates(p.kind, "a\r\nb\r\n"));
}

test "a text path with nothing else set writes LF" {
    // Measured on linux: `* text` with everything unset writes LF, which
    // is what core.eol=native resolves to here.
    const p = plan(.{ .text = .set }, .{});
    try testing.expectEqual(Eol.lf, p.worktree_eol);
}

test "core.autocrlf overrides core.eol in both directions" {
    // Both measured, and both were wrong in the first attempt. A matrix
    // differential against git's own worktree is what found them.
    // `input` with `core.eol=crlf` writes LF:
    const in_crlf = plan(.{ .text = .set }, .{ .autocrlf = .input, .eol = .crlf });
    try testing.expectEqual(Eol.lf, in_crlf.worktree_eol);
    // and `true` with `core.eol=lf` writes CRLF.
    const on_lf = plan(.{ .text = .set }, .{ .autocrlf = .on, .eol = .lf });
    try testing.expectEqual(Eol.crlf, on_lf.worktree_eol);
}

test "a path level eol still wins over autocrlf input" {
    // Measured: `* text eol=crlf` with autocrlf input writes CRLF, so the
    // path attribute sits above the config even here.
    const p = plan(.{ .text = .set, .eol = .crlf }, .{ .autocrlf = .input, .eol = .crlf });
    try testing.expectEqual(Eol.crlf, p.worktree_eol);
}

test "core.eol decides only when autocrlf is off" {
    // Measured: autocrlf false with core.eol=crlf writes CRLF.
    const p = plan(.{ .text = .set }, .{ .autocrlf = .off, .eol = .crlf });
    try testing.expectEqual(Eol.crlf, p.worktree_eol);
}
