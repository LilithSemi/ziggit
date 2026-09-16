//! Validates a full ref name per `git-check-ref-format`.

const std = @import("std");

pub const refname = struct {
    pub const Error = error{InvalidRefName};

    /// Validates `name` against the rules `git-check-ref-format` enforces:
    /// no empty component, no component starting with a dot, no component
    /// ending in `.lock`, no two consecutive dots, no ASCII control
    /// character, no space, none of `~ ^ : ? * [ \`, no `@{` sequence, no
    /// trailing dot, no leading or trailing slash, no two consecutive
    /// slashes, and the single character `@` is never valid. A single
    /// component with no slash is allowed, which is what `HEAD` is.
    pub fn validate(name: []const u8) Error!void {
        if (name.len == 0) return error.InvalidRefName;
        if (std.mem.eql(u8, name, "@")) return error.InvalidRefName;
        if (name[0] == '/' or name[name.len - 1] == '/') return error.InvalidRefName;
        if (name[name.len - 1] == '.') return error.InvalidRefName;
        if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidRefName;
        if (std.mem.indexOf(u8, name, "//") != null) return error.InvalidRefName;
        if (std.mem.indexOf(u8, name, "@{") != null) return error.InvalidRefName;

        for (name) |c| {
            if (c < 0x20 or c == 0x7f) return error.InvalidRefName;
            switch (c) {
                ' ', '~', '^', ':', '?', '*', '[', '\\' => return error.InvalidRefName,
                else => {},
            }
        }

        var it = std.mem.splitScalar(u8, name, '/');
        while (it.next()) |component| {
            // Empty components would mean a leading, trailing, or doubled
            // slash, all already rejected above; this guard only protects
            // the indexing below from ever seeing one.
            if (component.len == 0) return error.InvalidRefName;
            if (component[0] == '.') return error.InvalidRefName;
            if (std.mem.endsWith(u8, component, ".lock")) return error.InvalidRefName;
        }
    }

    pub fn isValid(name: []const u8) bool {
        validate(name) catch return false;
        return true;
    }
};

// expected

test "refname accepts refs/heads/main" {
    try std.testing.expect(refname.isValid("refs/heads/main"));
}

test "refname accepts a single component HEAD" {
    try std.testing.expect(refname.isValid("HEAD"));
}

// suspicious

test "refname rejects a name ending in .lock" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/branch.lock"));
}

test "refname rejects a name containing two consecutive dots" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/foo..bar"));
}

test "refname rejects a component starting with a dot" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/.foo"));
}

test "refname rejects an ascii control character" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/foo\x01bar"));
}

test "refname rejects the single character @" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("@"));
}

test "refname rejects a trailing slash" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/"));
}

test "refname rejects a leading slash" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("/refs/heads/main"));
}

test "refname rejects two consecutive slashes" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs//heads/main"));
}

test "refname rejects an at-brace sequence" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/main@{0}"));
}

test "refname rejects a trailing dot" {
    try std.testing.expectError(error.InvalidRefName, refname.validate("refs/heads/main."));
}

test "refname rejects a backslash, space, tilde, caret, colon, question mark, asterisk or open bracket" {
    const bad_chars = "\\ ~^:?*[";
    for (bad_chars) |c| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "refs/heads/foo{c}bar", .{c});
        try std.testing.expectError(error.InvalidRefName, refname.validate(name));
    }
}
