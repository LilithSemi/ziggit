//! Loose object framing and the typed parsers and serializers for commit,
//! tree, and tag objects.
//!
//! This module is the object formats alone: how a commit, a tree, a tag,
//! and the loose object envelope around any of them turn into bytes and
//! back. It holds no database policy (no `.git/objects` layout, no
//! deduplication) and no packs; those arrive in later modules.

const std = @import("std");

const loose_mod = @import("ziggit-object/loose.zig");
pub const Header = loose_mod.Header;
pub const loose = loose_mod.loose;

const commit_mod = @import("ziggit-object/Commit.zig");
pub const Commit = commit_mod.Commit;
pub const ExtraHeader = commit_mod.ExtraHeader;

const tree_mod = @import("ziggit-object/Tree.zig");
pub const Tree = tree_mod.Tree;

const tag_mod = @import("ziggit-object/Tag.zig");
pub const Tag = tag_mod.Tag;

test {
    _ = loose_mod;
    _ = commit_mod;
    _ = tree_mod;
    _ = tag_mod;
}
