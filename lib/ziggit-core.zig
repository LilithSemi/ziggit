//! Shared vocabulary for every layer above `ziggit-oid`: object kinds, file
//! modes, authorship identity, the diagnostic channel, ref name
//! validation, and the one directory-path convention every layer above
//! needs (`openDirRelative`).

const oid_mod = @import("ziggit-oid");

const object_kind_mod = @import("ziggit-core/object_kind.zig");
pub const ObjectKind = object_kind_mod.ObjectKind;

const file_mode_mod = @import("ziggit-core/FileMode.zig");
pub const FileMode = file_mode_mod.FileMode;

const identity_mod = @import("ziggit-core/Identity.zig");
pub const Identity = identity_mod.Identity;

const committer_mod = @import("ziggit-core/Committer.zig");
pub const Committer = committer_mod.Committer;

const tzif_mod = @import("ziggit-core/tzif.zig");
pub const offsetFromTzif = tzif_mod.offsetFromTzif;
pub const TzifError = tzif_mod.Error;

const diagnostic_mod = @import("ziggit-core/Diagnostic.zig");
pub const Diagnostic = diagnostic_mod.Diagnostic;
pub const wants = diagnostic_mod.wants;
pub const report = diagnostic_mod.report;

const refname_mod = @import("ziggit-core/refname.zig");
pub const refname = refname_mod.refname;

const dir_mod = @import("ziggit-core/dir.zig");
pub const openDirRelative = dir_mod.openDirRelative;

test {
    _ = object_kind_mod;
    _ = file_mode_mod;
    _ = identity_mod;
    _ = committer_mod;
    _ = tzif_mod;
    _ = diagnostic_mod;
    _ = refname_mod;
    _ = dir_mod;
}
