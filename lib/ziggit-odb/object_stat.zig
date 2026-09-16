//! The kind and size of an object, before its payload is read. Shared
//! shape returned internally by the loose and packed backends and by
//! `Odb`'s own diagnostic path; not part of this package's public surface,
//! which keeps its own anonymous literal of the same two fields.

const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;

pub const ObjectStat = struct {
    kind: ObjectKind,
    size: u64,
};
