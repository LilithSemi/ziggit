//! Fetch: the remote strategy and the local strategy, tied together behind
//! one dispatcher. Refspec matching, protocol v2 negotiation, receiving a
//! packfile, and updating refs, for the remote strategy; opening a source
//! repository directly and copying reachable objects, for the local one.
//! `ziggit-proto` reads the wire grammar, `ziggit-transport` drives the
//! connection, `ziggit-pack` turns a stream of bytes into an indexed pack,
//! `ziggit-odb` and `ziggit-refs` read the local strategy's source and
//! commit either strategy's result; this module is what calls each of them
//! in the right order.

const refspec_mod = @import("ziggit-fetch/refspec.zig");
pub const Refspec = refspec_mod.Refspec;

const remote_mod = @import("ziggit-fetch/remote.zig");

const fetcher_mod = @import("ziggit-fetch/Fetcher.zig");
pub const FetchOptions = fetcher_mod.FetchOptions;
pub const UpdatedRef = fetcher_mod.UpdatedRef;
pub const RefOutcome = fetcher_mod.RefOutcome;
pub const Result = fetcher_mod.Result;
pub const fetchRemote = fetcher_mod.fetchRemote;

const local_mod = @import("ziggit-fetch/local.zig");
pub const Error = local_mod.Error;
pub const fetchLocal = local_mod.fetchLocal;
pub const fetch = local_mod.fetch;

test {
    _ = refspec_mod;
    _ = remote_mod;
    _ = fetcher_mod;
    _ = local_mod;
}
