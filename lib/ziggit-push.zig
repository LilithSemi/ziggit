//! Sending refs and objects to a remote.
//!
//! Receive-pack has no protocol v2, so nothing here shares the v2
//! advertisement `ziggit-proto` parses for fetch. The old ref
//! advertisement, the ref update commands and the status report live in
//! this module instead.

const objects_mod = @import("ziggit-push/objects.zig");
pub const ObjectsError = objects_mod.Error;
pub const collectObjects = objects_mod.collect;
pub const OdbSource = objects_mod.OdbSource;

test {
    _ = objects_mod;
}
