//! The credential shapes every transport implementation asks for, and the
//! callback a caller answers with.
//!
//! A transport never reads a credential store itself. It asks the
//! caller's callback, once per host, and the caller decides where the
//! answer comes from: a keychain, an environment variable, a prompt. This
//! keeps a credential store out of every transport and out of `fix`.

const std = @import("std");

/// One credential a caller may answer a challenge with.
pub const Credential = union(enum) {
    /// The caller has a credential and it is deliberately none: proceed
    /// with no `Authorization` at all. Distinct from the callback
    /// returning `null`, which means "I have nothing to offer".
    none,
    bearer: []const u8,
    basic: struct { username: []const u8, password: []const u8 },
    ssh_key: struct { path: []const u8, passphrase: ?[]const u8 },
    /// Sign with a key an SSH agent holds, reading no key file at all.
    ///
    /// `socket_path` is the agent's unix socket. **This library does not
    /// read `SSH_AUTH_SOCK`,** or any other environment variable: a binary
    /// reads it and passes the answer here. The spelling of that variable
    /// is `zurl_ssh.agent.auth_socket_variable` for a caller that wants it.
    /// A library that reaches for the environment behind a caller's back
    /// defeats a curated environment, which is the case this project's
    /// main consumer runs in.
    ///
    /// The agent does the signing, so this needs no RSA signer of our own.
    /// RSA remains a limit on HOST KEY verification alone; see
    /// `UnsupportedKeyType`.
    ssh_agent: struct { socket_path: []const u8 },
};

/// Which credential shapes a transport may use for the request in hand.
///
/// HTTP never sets `ssh_key` or `ssh_agent`; SSH never sets `bearer` or
/// `basic`. A callback that answers with a shape the caller did not allow
/// is a callback that misread this struct, not a transport that misbehaved.
pub const AllowedTypes = packed struct {
    bearer: bool,
    basic: bool,
    ssh_key: bool,
    ssh_agent: bool = false,
};

/// Asked once per host, never more than once per challenge. `url` is the
/// full request target; `host` is `url`'s host alone, so a caller that
/// keys credentials by host need not parse `url` itself.
///
/// A `null` return means "I have nothing", and every transport in this
/// project turns that into `error.AuthRequired` rather than a silent
/// anonymous retry.
pub const CredentialCallback = *const fn (
    ctx: ?*anyopaque,
    url: []const u8,
    host: []const u8,
    allowed: AllowedTypes,
) ?Credential;
