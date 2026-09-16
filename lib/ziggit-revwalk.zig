//! Revision resolution and commit graph walking: turning a revision
//! string into an object id, peeling an annotated tag to the object kind
//! a caller asked for, and walking the commit graph forward from a set of
//! starting points while excluding another set and everything it reaches.

const revparse_mod = @import("ziggit-revwalk/revparse.zig");
pub const Error = revparse_mod.Error;
pub const resolve = revparse_mod.resolve;
pub const peel = revparse_mod.peel;

const walk_mod = @import("ziggit-revwalk/Walk.zig");
pub const Walk = walk_mod.Walk;
pub const countReachable = walk_mod.countReachable;
/// The bounded ancestry check `ziggit-fetch`'s fast-forward decision
/// uses. Not part of this module's own revision-resolution or
/// graph-walking surface; exported here purely so `ziggit-fetch` has one
/// shared implementation to call instead of keeping its own copy.
pub const isAncestor = walk_mod.isAncestor;

test {
    _ = revparse_mod;
    _ = walk_mod;
}
