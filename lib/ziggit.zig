//! Git in Zig. This is the supported surface. A caller that imports a
//! ziggit-* module directly is reaching past what this package promises.

const std = @import("std");

pub const Format = @import("ziggit-oid").Format;
pub const Oid = @import("ziggit-oid").Oid;
pub const Hasher = @import("ziggit-oid").Hasher;
pub const Diagnostic = @import("ziggit-core").Diagnostic;
pub const ObjectKind = @import("ziggit-core").ObjectKind;
pub const FileMode = @import("ziggit-core").FileMode;
pub const Identity = @import("ziggit-core").Identity;
pub const Committer = @import("ziggit-core").Committer;
pub const offsetFromTzif = @import("ziggit-core").offsetFromTzif;
pub const Commit = @import("ziggit-object").Commit;
pub const Tree = @import("ziggit-object").Tree;
pub const Tag = @import("ziggit-object").Tag;
pub const Pack = @import("ziggit-pack").Pack;
pub const Index = @import("ziggit-pack").Index;
pub const Odb = @import("ziggit-odb").Odb;
pub const Store = @import("ziggit-refs").Store;
pub const Target = @import("ziggit-refs").Target;
pub const Reference = @import("ziggit-refs").Reference;
pub const Config = @import("ziggit-config").Config;
pub const Level = @import("ziggit-config").Level;
pub const Layout = @import("ziggit-repo").Layout;
pub const Repository = @import("ziggit-repo").Repository;
pub const discover = @import("ziggit-repo").discover;
pub const DiscoverOptions = @import("ziggit-repo").DiscoverOptions;

// `.git/index`, git's staged snapshot of the working tree. Named
// `WorktreeIndex` here, not `Index`: `ziggit-pack` already exports an
// `Index` (the `.idx` file's own type), and this package flattens every
// module's surface into one namespace, so the two cannot share a name.
pub const WorktreeIndex = @import("ziggit-index").Index;
pub const stageWorktree = @import("ziggit-index").stageWorktree;
pub const writeWorktreeIndex = @import("ziggit-index").write;
// `WorktreeIndex.find` returns `?IndexEntry`, and its `entries` field is
// `[]const IndexEntry`; renamed here for the same reason as
// `WorktreeIndex` itself, so the pairing reads as one thing rather than a
// bare `Entry`/`Stage` sitting unexplained next to `Tree`'s own nested
// (and differently shaped) `Entry`.
pub const IndexEntry = @import("ziggit-index").Entry;
pub const IndexStage = @import("ziggit-index").Stage;

pub const Transport = @import("ziggit-transport").Transport;
pub const Http = @import("ziggit-transport").Http;
pub const Ssh = @import("ziggit-transport").Ssh;
pub const Credential = @import("ziggit-transport").Credential;
pub const CredentialCallback = @import("ziggit-transport").CredentialCallback;
pub const AllowedTypes = @import("ziggit-transport").AllowedTypes;
pub const Progress = @import("ziggit-transport").Progress;
pub const isTransient = @import("ziggit-transport").isTransient;
// `Http.open` and `Ssh.open` both take one of these as their settings
// argument; a caller building anything but the all-defaults `.{}` needs
// to name it.
pub const TransportOptions = @import("ziggit-transport").Options;

pub const writeTreeFromIndex = @import("ziggit-odb").writeTreeFromIndex;

pub const checkoutTree = @import("ziggit-checkout").checkoutTree;
pub const Strategy = @import("ziggit-checkout").Strategy;

pub const resolve = @import("ziggit-revwalk").resolve;
pub const peel = @import("ziggit-revwalk").peel;
pub const Walk = @import("ziggit-revwalk").Walk;
pub const countReachable = @import("ziggit-revwalk").countReachable;

pub const fetch = @import("ziggit-fetch").fetch;
pub const fetchLocal = @import("ziggit-fetch").fetchLocal;
pub const fetchRemote = @import("ziggit-fetch").fetchRemote;
pub const FetchOptions = @import("ziggit-fetch").FetchOptions;
pub const Refspec = @import("ziggit-fetch").Refspec;
pub const Result = @import("ziggit-fetch").Result;
pub const UpdatedRef = @import("ziggit-fetch").UpdatedRef;
pub const RefOutcome = @import("ziggit-fetch").RefOutcome;

pub const Submodule = @import("ziggit-submodule").Submodule;
pub const parseGitmodules = @import("ziggit-submodule").parseGitmodules;
pub const updateAll = @import("ziggit-submodule").updateAll;
pub const UpdateOptions = @import("ziggit-submodule").UpdateOptions;

test {
    _ = @import("ziggit-oid");
    _ = @import("ziggit-core");
    _ = @import("ziggit-object");
    _ = @import("ziggit-pack");
    _ = @import("ziggit-refs");
    _ = @import("ziggit-config");
    _ = @import("ziggit-odb");
    _ = @import("ziggit-repo");
    _ = @import("ziggit-index");
    _ = @import("ziggit-transport");
    _ = @import("ziggit-checkout");
    _ = @import("ziggit-revwalk");
    _ = @import("ziggit-fetch");
    _ = @import("ziggit-submodule");
}

// A function is not a type: `discover` being exported gives a consumer no
// path to `DiscoverOptions` on its own. This compiles only when every one
// of these is genuinely reachable from `ziggit` itself, proving a
// consumer can write a signature over each without reaching past this
// package into a `ziggit-*` module directly.
const SurfaceCheck = struct {
    // Every function below must stay `pub`: `std.testing.refAllDecls` walks
    // `@typeInfo(SurfaceCheck).@"struct".decls`, and that list holds only a
    // container's public declarations. A non-pub function here would sit
    // outside that list, silently un-checked, exactly the failure mode this
    // struct exists to close off.
    pub fn takesDiscoverOptions(_: DiscoverOptions) void {}
    pub fn takesStore(_: *Store) void {}
    pub fn takesTarget(_: Target) void {}
    pub fn takesHasher(_: Hasher) void {}
    pub fn takesLevel(_: Level) void {}
    pub fn takesPack(_: *Pack) void {}
    pub fn takesIndex(_: *Index) void {}
    pub fn takesWorktreeIndex(_: *WorktreeIndex) void {}
    pub fn takesIndexEntry(_: IndexEntry) void {}
    pub fn takesIndexStage(_: IndexStage) void {}
    pub fn takesTransport(_: Transport) void {}
    pub fn takesHttp(_: *Http) void {}
    pub fn takesSsh(_: *Ssh) void {}
    pub fn takesCredential(_: Credential) void {}
    pub fn takesCredentialCallback(_: CredentialCallback) void {}
    pub fn takesAllowedTypes(_: AllowedTypes) void {}
    pub fn takesProgress(_: Progress) void {}
    pub fn takesTransportOptions(_: TransportOptions) void {}
    pub fn takesStrategy(_: Strategy) void {}
    pub fn takesWalk(_: *Walk) void {}
    pub fn takesFetchOptions(_: FetchOptions) void {}
    pub fn takesRefspec(_: Refspec) void {}
    pub fn takesResult(_: *Result) void {}
    pub fn takesUpdatedRef(_: *UpdatedRef) void {}
    pub fn takesRefOutcome(_: RefOutcome) void {}
    pub fn takesSubmodule(_: *Submodule) void {}
    pub fn takesUpdateOptions(_: UpdateOptions) void {}
};

test "the front package's re-exports are usable as types in a signature" {
    // `_ = SurfaceCheck;` alone would only reference the struct's type value,
    // never its member functions: Zig analyses a container's declarations
    // lazily, on first reference, so an unreachable function's signature --
    // and the re-export type it names -- is never even type-checked. That
    // let a re-export naming a member absent from its own module sit here
    // with every test passing (see `RefOutcome`, fixed in `ziggit-fetch.zig`
    // alongside this test). `refAllDecls` takes each function's address in
    // turn, which forces its signature, and so the re-export type it names,
    // to be resolved.
    std.testing.refAllDecls(SurfaceCheck);
}

test "every top-level re-export of the front package resolves" {
    // Broader than the check above: `SurfaceCheck` only wraps the
    // re-exports that need proving usable as a type in a signature (see its
    // own doc comment). A re-exported function, or a type nobody wrapped,
    // is a top-level declaration of this file either way, so referencing
    // every declaration of `@This()` forces each one to resolve, function
    // and type alike, with no per-export wrapper to remember to add.
    std.testing.refAllDecls(@This());
}
