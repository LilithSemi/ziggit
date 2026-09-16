//! git's wire protocol version 2 grammar: the capability advertisement,
//! `ls-refs`, `fetch`, and the sideband that demultiplexes a fetch
//! response's packfile section. No sockets, no transport, no repository:
//! every function here reads from or writes to a caller-supplied
//! `std.Io.Reader` or `std.Io.Writer`, never opens a connection, and never
//! touches a `.git` directory.

const capability_mod = @import("ziggit-proto/Capability.zig");
pub const Capability = capability_mod.Capability;
pub const Capabilities = capability_mod.Capabilities;
pub const ParseError = capability_mod.ParseError;
pub const parseCapabilities = capability_mod.parseCapabilities;

const ls_refs_mod = @import("ziggit-proto/ls_refs.zig");
pub const RefLine = ls_refs_mod.RefLine;
pub const LsRefsOptions = ls_refs_mod.LsRefsOptions;
pub const writeLsRefs = ls_refs_mod.writeLsRefs;
pub const readLsRefs = ls_refs_mod.readLsRefs;

const fetch_mod = @import("ziggit-proto/fetch.zig");
pub const FetchRequest = fetch_mod.FetchRequest;
pub const writeFetch = fetch_mod.writeFetch;
pub const FetchSection = fetch_mod.FetchSection;
pub const readFetchSection = fetch_mod.readFetchSection;

const negotiation_mod = @import("ziggit-proto/Negotiation.zig");
pub const Sideband = negotiation_mod.Sideband;

test {
    _ = capability_mod;
    _ = ls_refs_mod;
    _ = fetch_mod;
    _ = negotiation_mod;
}
