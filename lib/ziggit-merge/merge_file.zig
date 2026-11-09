//! The file-level three-way merge: `git merge-file` on its own.
//!
//! Lines carry their own terminator, so a side with no final newline keeps
//! it missing through a clean merge. Inside a conflict region a side that
//! lacks one still gets a newline before the marker, which is what git
//! does, because a marker has to start its own line.
//!
//! Two changed regions merge cleanly only when an unchanged base line
//! separates them. Changes on adjacent base lines conflict, and the
//! conflict covers the union of both spans. That is git's rule and it is
//! stricter than overlap alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");
const FileMode = core_mod.FileMode;

const diff_mod = @import("ziggit-diff");

pub const Error = error{
    /// A side is larger than the diff machinery will take. Reported rather
    /// than silently turned into a conflict, because the caller may want to
    /// treat a file it cannot merge differently from one that conflicts.
    FileTooLarge,
} || Allocator.Error;

pub const Input = struct {
    path: []const u8 = "",
    mode: FileMode = .blob,
    content: []const u8,
};

pub const FileOptions = struct {
    /// Written after `<<<<<<<` and `>>>>>>>`. Git uses the revision names
    /// it was given; these are libgit2's defaults.
    our_label: []const u8 = "ours",
    their_label: []const u8 = "theirs",
    /// Marker length. Seven is `GIT_MERGE_CONFLICT_MARKER_SIZE`.
    marker_size: u8 = 7,
};

pub const FileResult = struct {
    /// False when `content` carries conflict markers. The field libgit2
    /// spells the same way.
    automergeable: bool,
    content: []u8,
    mode: FileMode,

    pub fn deinit(r: *FileResult, gpa: Allocator) void {
        gpa.free(r.content);
        r.* = undefined;
    }
};

/// Merges `ours` and `theirs` over `base`. A null `base` merges against an
/// empty file, which makes every line of both sides an addition.
pub fn mergeFile(
    gpa: Allocator,
    base: ?Input,
    ours: Input,
    theirs: Input,
    options: FileOptions,
) Error!FileResult {
    const base_content = if (base) |b| b.content else "";
    const mode = mergeMode(if (base) |b| b.mode else null, ours.mode, theirs.mode);

    // Settled without looking at lines at all.
    if (std.mem.eql(u8, ours.content, theirs.content)) {
        return .{ .automergeable = true, .content = try gpa.dupe(u8, ours.content), .mode = mode };
    }
    if (std.mem.eql(u8, base_content, ours.content)) {
        return .{ .automergeable = true, .content = try gpa.dupe(u8, theirs.content), .mode = mode };
    }
    if (std.mem.eql(u8, base_content, theirs.content)) {
        return .{ .automergeable = true, .content = try gpa.dupe(u8, ours.content), .mode = mode };
    }

    // The text driver bows out of a file it would corrupt, so a binary side
    // conflicts whole rather than by lines.
    if (isBinary(base_content) or isBinary(ours.content) or isBinary(theirs.content)) {
        const content = try wholeFileConflict(gpa, ours.content, theirs.content, options);
        return .{ .automergeable = false, .content = content, .mode = mode };
    }

    var base_lines = try splitLines(gpa, base_content);
    defer base_lines.deinit(gpa);
    var our_lines = try splitLines(gpa, ours.content);
    defer our_lines.deinit(gpa);
    var their_lines = try splitLines(gpa, theirs.content);
    defer their_lines.deinit(gpa);

    var our_regions = try changedRegions(gpa, base_content, ours.content);
    defer our_regions.deinit(gpa);
    var their_regions = try changedRegions(gpa, base_content, theirs.content);
    defer their_regions.deinit(gpa);

    var groups = try buildGroups(gpa, our_regions.items, their_regions.items);
    defer groups.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var clean = true;
    var at: usize = 0;

    for (groups.items) |group| {
        while (at < group.base_start) : (at += 1) try writeLine(&out.writer, base_lines.items[at]);

        const our_slice = our_regions.items[group.our_start..group.our_end];
        const their_slice = their_regions.items[group.their_start..group.their_end];

        if (!group.conflicted) {
            // One side only, so its lines simply replace the base run.
            const side = if (our_slice.len > 0) our_slice else their_slice;
            for (side) |region| {
                while (at < region.base_start) : (at += 1) try writeLine(&out.writer, base_lines.items[at]);
                for (region.lines) |line| try writeLine(&out.writer, line);
                at = region.base_end;
            }
            at = group.base_end;
            continue;
        }

        const our_text = try sideText(gpa, base_lines.items, our_slice, group.base_start, group.base_end);
        defer gpa.free(our_text);
        const their_text = try sideText(gpa, base_lines.items, their_slice, group.base_start, group.base_end);
        defer gpa.free(their_text);

        if (std.mem.eql(u8, our_text, their_text)) {
            try writeLine(&out.writer, our_text);
        } else if (try narrowConflict(gpa, &out.writer, our_text, their_text, options)) {
            clean = false;
        }
        at = group.base_end;
    }

    while (at < base_lines.items.len) : (at += 1) try writeLine(&out.writer, base_lines.items[at]);

    return .{
        .automergeable = clean,
        .content = try gpa.dupe(u8, out.written()),
        .mode = mode,
    };
}

/// One run of base lines a side replaced, with the lines it put there.
/// `base_start` and `base_end` bound the replaced run; they are equal for a
/// pure insertion.
const Region = struct {
    base_start: usize,
    base_end: usize,
    lines: []const []const u8,
};

const Regions = struct {
    items: []Region,
    /// Backs every `Region.lines` and the line slices inside them.
    patch: diff_mod.Patch,

    fn deinit(r: *Regions, gpa: Allocator) void {
        for (r.items) |region| gpa.free(region.lines);
        gpa.free(r.items);
        r.patch.deinit(gpa);
        r.* = undefined;
    }
};

/// The runs `new` changed relative to `old`, in base order.
///
/// Zero context is what makes each hunk exactly one changed run: the
/// default three lines of context would merge neighbouring changes into one
/// hunk and lose the boundary this merge needs.
fn changedRegions(gpa: Allocator, old: []const u8, new: []const u8) Error!Regions {
    var patch = diff_mod.diffBlobs(gpa, "", "", old, new, .{ .context_lines = 0 }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileTooLarge,
    };
    errdefer patch.deinit(gpa);

    var items: std.ArrayList(Region) = .empty;
    errdefer {
        for (items.items) |region| gpa.free(region.lines);
        items.deinit(gpa);
    }

    for (patch.hunks) |hunk| {
        var added: std.ArrayList([]const u8) = .empty;
        errdefer added.deinit(gpa);
        var removed: usize = 0;
        for (hunk.lines) |line| switch (line.origin) {
            .addition => try added.append(gpa, line.content),
            .deletion => removed += 1,
            .context => {},
        };

        // `old_start` is one-based, and a hunk that only adds reports the
        // line before the insertion point, so its run is empty and begins
        // after that line.
        const start = if (removed == 0) hunk.old_start else hunk.old_start - 1;
        try items.append(gpa, .{
            .base_start = start,
            .base_end = start + removed,
            .lines = try added.toOwnedSlice(gpa),
        });
    }

    return .{ .items = try items.toOwnedSlice(gpa), .patch = patch };
}

/// One side's own text for base lines `[span_start, span_end)`: its regions
/// inside that span, with the side's unchanged base lines between them.
fn sideText(
    gpa: Allocator,
    base_lines: []const []const u8,
    regions: []const Region,
    span_start: usize,
    span_end: usize,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var at = span_start;
    for (regions) |region| {
        while (at < region.base_start) : (at += 1) try writeLine(&out.writer, base_lines[at]);
        for (region.lines) |line| try writeLine(&out.writer, line);
        at = region.base_end;
    }
    while (at < span_end) : (at += 1) try writeLine(&out.writer, base_lines[at]);

    return gpa.dupe(u8, out.written());
}

fn writeLine(w: *std.Io.Writer, line: []const u8) Allocator.Error!void {
    w.writeAll(line) catch return error.OutOfMemory;
}

/// Writes a conflict region. A side with no final newline gets one first,
/// so the marker that follows starts its own line.
fn writeConflict(
    w: *std.Io.Writer,
    our_text: []const u8,
    their_text: []const u8,
    options: FileOptions,
) Allocator.Error!void {
    try writeMarker(w, '<', options.marker_size, options.our_label);
    try writeTerminated(w, our_text);
    try writeMarker(w, '=', options.marker_size, "");
    try writeTerminated(w, their_text);
    try writeMarker(w, '>', options.marker_size, options.their_label);
}

fn writeMarker(w: *std.Io.Writer, c: u8, size: u8, label: []const u8) Allocator.Error!void {
    var i: u8 = 0;
    while (i < size) : (i += 1) w.writeByte(c) catch return error.OutOfMemory;
    if (label.len > 0) {
        w.writeByte(' ') catch return error.OutOfMemory;
        w.writeAll(label) catch return error.OutOfMemory;
    }
    w.writeByte('\n') catch return error.OutOfMemory;
}

fn writeTerminated(w: *std.Io.Writer, text: []const u8) Allocator.Error!void {
    w.writeAll(text) catch return error.OutOfMemory;
    if (text.len > 0 and text[text.len - 1] != '\n') w.writeByte('\n') catch return error.OutOfMemory;
}

/// A conflict covering both whole files, for content lines cannot be
/// merged.
fn wholeFileConflict(
    gpa: Allocator,
    ours: []const u8,
    theirs: []const u8,
    options: FileOptions,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeConflict(&out.writer, ours, theirs, options);
    return gpa.dupe(u8, out.written());
}

/// Git calls content binary when a NUL appears early in it. The same test
/// decides whether the text driver will touch a file at all.
fn isBinary(content: []const u8) bool {
    const window = @min(content.len, 8000);
    return std.mem.indexOfScalar(u8, content[0..window], 0) != null;
}

/// Splits into lines that keep their own terminator. A final line with no
/// newline keeps none, which is how a missing final newline survives.
fn splitLines(gpa: Allocator, bytes: []const u8) Error!std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var start: usize = 0;
    while (start < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const end = if (nl) |at| at + 1 else bytes.len;
        try lines.append(gpa, bytes[start..end]);
        start = end;
    }
    return lines;
}

/// A mode changed on one side follows that side. Differing changes keep
/// ours, which is the side a caller is merging into.
fn mergeMode(base: ?FileMode, ours: FileMode, theirs: FileMode) FileMode {
    if (ours == theirs) return ours;
    if (base) |b| {
        if (ours == b) return theirs;
        if (theirs == b) return ours;
    }
    return ours;
}

const testing = std.testing;

fn expectMerge(
    base: ?[]const u8,
    ours: []const u8,
    theirs: []const u8,
    clean: bool,
    want: []const u8,
) !void {
    const gpa = testing.allocator;
    var result = try mergeFile(
        gpa,
        if (base) |b| Input{ .content = b } else null,
        .{ .content = ours },
        .{ .content = theirs },
        .{},
    );
    defer result.deinit(gpa);
    try testing.expectEqual(clean, result.automergeable);
    try testing.expectEqualStrings(want, result.content);
}

test "changes separated by an unchanged line merge cleanly" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "L1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "l1\nl2\nl3\nl4\nl5\nl6\nL7\n",
        true,
        "L1\nl2\nl3\nl4\nl5\nl6\nL7\n",
    );
}

test "changes one line apart still merge cleanly" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "L1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "l1\nl2\nL3\nl4\nl5\nl6\nl7\n",
        true,
        "L1\nl2\nL3\nl4\nl5\nl6\nl7\n",
    );
}

test "changes on adjacent lines conflict over the union of both spans" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "L1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "l1\nL2\nl3\nl4\nl5\nl6\nl7\n",
        false,
        "<<<<<<< ours\nL1\nl2\n=======\nl1\nL2\n>>>>>>> theirs\nl3\nl4\nl5\nl6\nl7\n",
    );
}

test "the same change on both sides lands once" {
    try expectMerge("one\ntwo\n", "one\nSAME\n", "one\nSAME\n", true, "one\nSAME\n");
}

test "both sides deleting the same lines delete them once" {
    try expectMerge("a\nb\nc\n", "a\nc\n", "a\nc\n", true, "a\nc\n");
}

test "a conflict at the first line emits the marker as line one" {
    try expectMerge(
        "a\nb\n",
        "A\nb\n",
        "X\nb\n",
        false,
        "<<<<<<< ours\nA\n=======\nX\n>>>>>>> theirs\nb\n",
    );
}

test "delete against modify writes an empty region for the deleting side" {
    try expectMerge(
        "a\nb\nc\n",
        "a\nc\n",
        "a\nB\nc\n",
        false,
        "a\n<<<<<<< ours\n=======\nB\n>>>>>>> theirs\nc\n",
    );
}

test "a clean merge keeps a missing final newline" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
        true,
        "l1\nl2\nl3\nl4\nl5\nl6\nl7",
    );
}

test "a conflicting side with no final newline still gets one before the marker" {
    const gpa = testing.allocator;
    var result = try mergeFile(
        gpa,
        Input{ .content = "a\nb\n" },
        .{ .content = "a\nB" },
        .{ .content = "a\nY\n" },
        .{},
    );
    defer result.deinit(gpa);
    try testing.expect(!result.automergeable);
    try testing.expectEqualStrings("a\n<<<<<<< ours\nB\n=======\nY\n>>>>>>> theirs\n", result.content);
}

test "a null base merges against an empty file" {
    try expectMerge(null, "only\n", "only\n", true, "only\n");
}

test "binary content conflicts whole rather than by lines" {
    const gpa = testing.allocator;
    var result = try mergeFile(
        gpa,
        Input{ .content = "a\x00b" },
        .{ .content = "a\x00OURS" },
        .{ .content = "a\x00THEIRS" },
        .{},
    );
    defer result.deinit(gpa);
    try testing.expect(!result.automergeable);
    try testing.expect(std.mem.indexOf(u8, result.content, "<<<<<<< ours") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "a\x00OURS") != null);
}

test "marker_size is honoured" {
    const gpa = testing.allocator;
    var result = try mergeFile(
        gpa,
        Input{ .content = "a\nb\n" },
        .{ .content = "a\nB\n" },
        .{ .content = "a\nY\n" },
        .{ .marker_size = 3 },
    );
    defer result.deinit(gpa);
    try testing.expectEqualStrings("a\n<<< ours\nB\n===\nY\n>>> theirs\n", result.content);
}

test "one side unchanged takes the other side whole" {
    try expectMerge("a\nb\n", "a\nb\n", "a\nB\n", true, "a\nB\n");
    try expectMerge("a\nb\n", "a\nB\n", "a\nb\n", true, "a\nB\n");
}

test "a mode changed on one side follows that side" {
    const gpa = testing.allocator;
    var result = try mergeFile(
        gpa,
        Input{ .mode = .blob, .content = "a\n" },
        .{ .mode = .blob, .content = "a\n" },
        .{ .mode = .blob_executable, .content = "a\n" },
        .{},
    );
    defer result.deinit(gpa);
    try testing.expectEqual(FileMode.blob_executable, result.mode);
}

/// Writes a conflict span, first moving the lines both sides agree on out
/// of it. Returns true when anything was still in conflict.
///
/// A span where both sides changed does not mean every line in it differs.
/// With base `l1,l2`, ours `L1,l2` and theirs `L1,L2`, the span covers both
/// lines but the sides agree on `L1`, and git emits that line plainly and
/// conflicts only on the second. Leaving the agreed lines inside the
/// markers would report a conflict wider than the disagreement.
fn narrowConflict(
    gpa: Allocator,
    w: *std.Io.Writer,
    our_text: []const u8,
    their_text: []const u8,
    options: FileOptions,
) Error!bool {
    var ours = try splitLines(gpa, our_text);
    defer ours.deinit(gpa);
    var theirs = try splitLines(gpa, their_text);
    defer theirs.deinit(gpa);

    var lead: usize = 0;
    while (lead < ours.items.len and lead < theirs.items.len and
        std.mem.eql(u8, ours.items[lead], theirs.items[lead])) : (lead += 1)
    {}

    var trail: usize = 0;
    while (trail < ours.items.len - lead and trail < theirs.items.len - lead and
        std.mem.eql(u8, ours.items[ours.items.len - 1 - trail], theirs.items[theirs.items.len - 1 - trail])) : (trail += 1)
    {}

    for (ours.items[0..lead]) |line| try writeLine(w, line);

    const our_mid = ours.items[lead .. ours.items.len - trail];
    const their_mid = theirs.items[lead .. theirs.items.len - trail];

    var conflicted = false;
    if (our_mid.len > 0 or their_mid.len > 0) {
        conflicted = true;
        const our_mid_text = try joinLines(gpa, our_mid);
        defer gpa.free(our_mid_text);
        const their_mid_text = try joinLines(gpa, their_mid);
        defer gpa.free(their_mid_text);
        try writeConflict(w, our_mid_text, their_mid_text, options);
    }

    for (ours.items[ours.items.len - trail ..]) |line| try writeLine(w, line);
    return conflicted;
}

fn joinLines(gpa: Allocator, lines: []const []const u8) Error![]u8 {
    var total: usize = 0;
    for (lines) |line| total += line.len;
    const out = try gpa.alloc(u8, total);
    var at: usize = 0;
    for (lines) |line| {
        @memcpy(out[at..][0..line.len], line);
        at += line.len;
    }
    return out;
}

/// One run of base lines that one or both sides changed, with the regions
/// that fall inside it.
const Group = struct {
    base_start: usize,
    base_end: usize,
    our_start: usize,
    our_end: usize,
    their_start: usize,
    their_end: usize,
    /// Both sides reach into this run.
    conflicted: bool,
};

/// How many unchanged base lines may sit between two conflicts before git
/// leaves them as separate conflicts.
///
/// Three or fewer and git writes one conflict across the gap; four or more
/// and it writes two. The gap lines stay inside the markers, since
/// `narrowConflict` only strips from the ends. Both sides' diffs report two
/// separate runs either way, so this joining belongs to the merge and not
/// to the diff.
const max_joined_gap: usize = 3;

fn buildGroups(
    gpa: Allocator,
    our_regions: []const Region,
    their_regions: []const Region,
) Error!std.ArrayList(Group) {
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(gpa);

    var oi: usize = 0;
    var ti: usize = 0;
    while (oi < our_regions.len or ti < their_regions.len) {
        const our_next: ?usize = if (oi < our_regions.len) our_regions[oi].base_start else null;
        const their_next: ?usize = if (ti < their_regions.len) their_regions[ti].base_start else null;
        const from_ours = if (our_next) |o| (their_next == null or o <= their_next.?) else false;

        var group: Group = .{
            .base_start = if (from_ours) our_regions[oi].base_start else their_regions[ti].base_start,
            .base_end = if (from_ours) our_regions[oi].base_end else their_regions[ti].base_end,
            .our_start = oi,
            .our_end = oi,
            .their_start = ti,
            .their_end = ti,
            .conflicted = false,
        };
        if (from_ours) group.our_end += 1 else group.their_end += 1;

        // Take every later region that touches the run. An unchanged base
        // line between two regions keeps them apart; adjacency does not.
        while (true) {
            var grew = false;
            if (group.our_end < our_regions.len and our_regions[group.our_end].base_start <= group.base_end) {
                group.base_end = @max(group.base_end, our_regions[group.our_end].base_end);
                group.our_end += 1;
                grew = true;
            }
            if (group.their_end < their_regions.len and their_regions[group.their_end].base_start <= group.base_end) {
                group.base_end = @max(group.base_end, their_regions[group.their_end].base_end);
                group.their_end += 1;
                grew = true;
            }
            if (!grew) break;
        }
        group.conflicted = group.our_end > group.our_start and group.their_end > group.their_start;
        oi = group.our_end;
        ti = group.their_end;

        // Two conflicts close together become one, which is what git does
        // and why `max_joined_gap` exists.
        if (groups.items.len > 0) {
            const last = &groups.items[groups.items.len - 1];
            if (last.conflicted and group.conflicted and
                group.base_start <= last.base_end + max_joined_gap)
            {
                last.base_end = group.base_end;
                last.our_end = group.our_end;
                last.their_end = group.their_end;
                continue;
            }
        }
        try groups.append(gpa, group);
    }

    return groups;
}

test "a span both sides changed conflicts only where they disagree" {
    // Both sides change the first line the same way. Git emits that line
    // plainly and conflicts on the second alone, rather than wrapping the
    // whole span in markers.
    try expectMerge(
        "l1\nl2\n",
        "L1\nl2\n",
        "L1\nL2\n",
        false,
        "L1\n<<<<<<< ours\nl2\n=======\nL2\n>>>>>>> theirs\n",
    );
}

test "two conflicts three or fewer lines apart become one" {
    // Git joins them, and the unchanged lines in the gap stay inside the
    // markers because narrowing only strips from the ends.
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\n",
        "L1\nl2\nl3\nl4\nL5\n",
        "X1\nl2\nl3\nl4\nX5\n",
        false,
        "<<<<<<< ours\nL1\nl2\nl3\nl4\nL5\n=======\nX1\nl2\nl3\nl4\nX5\n>>>>>>> theirs\n",
    );
}

test "two conflicts four or more lines apart stay separate" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\n",
        "L1\nl2\nl3\nl4\nl5\nL6\n",
        "X1\nl2\nl3\nl4\nl5\nX6\n",
        false,
        "<<<<<<< ours\nL1\n=======\nX1\n>>>>>>> theirs\n" ++
            "l2\nl3\nl4\nl5\n" ++
            "<<<<<<< ours\nL6\n=======\nX6\n>>>>>>> theirs\n",
    );
}

test "a one-sided change far from a conflict is applied, not joined to it" {
    try expectMerge(
        "l1\nl2\nl3\nl4\nl5\nl6\n",
        "L1\nl2\nl3\nl4\nl5\nMINE\n",
        "X1\nl2\nl3\nl4\nl5\nl6\n",
        false,
        "<<<<<<< ours\nL1\n=======\nX1\n>>>>>>> theirs\nl2\nl3\nl4\nl5\nMINE\n",
    );
}
