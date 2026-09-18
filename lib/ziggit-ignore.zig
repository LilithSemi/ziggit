//! gitignore matching: which worktree paths git leaves untracked.
//!
//! Imports nothing. Pattern text and relative paths are all it needs, so it
//! takes no object database, no repository and no config, and a caller
//! decides where the patterns came from.

const matcher_mod = @import("ziggit-ignore/Matcher.zig");
pub const Matcher = matcher_mod.Matcher;
pub const Error = matcher_mod.Error;

test {
    _ = matcher_mod;
}
