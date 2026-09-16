//! The error taxonomy every transport implementation reports through, and
//! the transient/permanent split a retry loop keys on.
//!
//! A fault a caller retries and a fault a caller must not retry are
//! different things, and a caller that cannot tell them apart either
//! retries forever or gives up on a fault that would have cleared on its
//! own. `isTransient` is that answer, stated once here rather than
//! guessed at every call site.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    // transient: the same request may succeed on a later try.
    NetworkFailed,
    Timeout,
    ConnectionLost,
    ServerBusy,
    // permanent: a retry of the same request answers the same way.
    AuthRequired,
    AuthFailed,
    NotFound,
    ProtocolError,
    UnsupportedProtocol,
    HostKeyRejected,
    UnsupportedKeyType,
    /// The SSH agent at the socket the caller named could not be reached,
    /// or stopped answering. Named apart from `AuthRequired` because the
    /// cause is a missing or dead agent, not a caller who offered no
    /// credential, and the fix is different: start an agent, or correct
    /// the socket path.
    SshAgentUnavailable,
    /// The agent answered and holds no key this build can use. It signs
    /// with ed25519 only, so an agent carrying RSA keys alone lands here.
    /// Keys of other types are skipped rather than refused, so this means
    /// the agent had NONE that fit, not that it had a wrong one.
    NoUsableAgentKey,
    /// The peer's certificate failed verification: expired, untrusted, or
    /// forged, which is what a machine-in-the-middle presents. Distinct
    /// from `NetworkFailed` so a retry loop never spins on a fault that a
    /// later attempt cannot fix and treats as what it is instead: a trust
    /// failure to report, not a flaky connection to retry.
    TlsVerificationFailed,
} || Allocator.Error;

/// Whether `err` is worth retrying.
///
/// Total over `Error`: a member added to the set above and left out of
/// this `switch` fails the build, not a caller at run time. `fix` keys its
/// retry loop on this answer, so a fault miscategorised here costs a user
/// either a hang, on a permanent fault called transient, or a spurious
/// failure, on a transient fault called permanent.
pub fn isTransient(err: Error) bool {
    return switch (err) {
        error.NetworkFailed,
        error.Timeout,
        error.ConnectionLost,
        error.ServerBusy,
        => true,

        error.AuthRequired,
        error.AuthFailed,
        error.NotFound,
        error.ProtocolError,
        error.UnsupportedProtocol,
        error.HostKeyRejected,
        error.UnsupportedKeyType,
        error.SshAgentUnavailable,
        error.NoUsableAgentKey,
        error.TlsVerificationFailed,
        error.OutOfMemory,
        => false,
    };
}

const testing = std.testing;

// expected

test "isTransient is true for NetworkFailed and false for AuthFailed" {
    try testing.expect(isTransient(error.NetworkFailed));
    try testing.expect(!isTransient(error.AuthFailed));
}

// suspicious

test "a 404 is NotFound and is not transient" {
    try testing.expect(!isTransient(error.NotFound));
}

test "a 503 is ServerBusy and is transient" {
    try testing.expect(isTransient(error.ServerBusy));
}

test "a TLS trust failure is permanent, never retried" {
    try testing.expect(!isTransient(error.TlsVerificationFailed));
}

test "isTransient covers every transient name and no permanent one" {
    inline for ([_]Error{ error.NetworkFailed, error.Timeout, error.ConnectionLost, error.ServerBusy }) |err| {
        try testing.expect(isTransient(err));
    }
    inline for ([_]Error{
        error.AuthRequired,
        error.AuthFailed,
        error.NotFound,
        error.ProtocolError,
        error.UnsupportedProtocol,
        error.HostKeyRejected,
        error.UnsupportedKeyType,
        error.SshAgentUnavailable,
        error.NoUsableAgentKey,
        error.TlsVerificationFailed,
        error.OutOfMemory,
    }) |err| {
        try testing.expect(!isTransient(err));
    }
}
