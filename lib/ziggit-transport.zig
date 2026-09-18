//! The `Transport` interface, and the smart-HTTP implementation over
//! `zurl`.
//!
//! **This is the only module in the project that imports `zurl`.** Every
//! module below it speaks git's on-disk formats and wire grammar with no
//! socket anywhere in the call stack; this is where a socket first
//! appears, and nothing above the network belongs down there. A later SSH
//! implementation lives here too, beside `Http`, and imports `zurl` for
//! the same reason.

const transport_mod = @import("ziggit-transport/Transport.zig");
pub const Transport = transport_mod.Transport;
pub const Options = transport_mod.Options;
pub const Command = transport_mod.Command;
pub const Progress = transport_mod.Progress;
pub const Diagnostic = transport_mod.Diagnostic;
pub const Capabilities = transport_mod.Capabilities;

const errors_mod = @import("ziggit-transport/errors.zig");
pub const Error = errors_mod.Error;
pub const isTransient = errors_mod.isTransient;

const credentials_mod = @import("ziggit-transport/credentials.zig");
pub const Credential = credentials_mod.Credential;
pub const AllowedTypes = credentials_mod.AllowedTypes;
pub const CredentialCallback = credentials_mod.CredentialCallback;

const http_mod = @import("ziggit-transport/http.zig");
pub const Http = http_mod.Http;

const ssh_mod = @import("ziggit-transport/ssh.zig");
pub const Ssh = ssh_mod.Ssh;

const git_mod = @import("ziggit-transport/git.zig");
pub const Git = git_mod.Git;
/// True for git's scp-like remote spelling, `user@host:path`. Exported so
/// `ziggit-fetch` can route that spelling to the ssh transport instead of
/// opening it as a directory, without writing a second rule for it.
pub const isScpLike = ssh_mod.isScpLike;

test {
    _ = transport_mod;
    _ = errors_mod;
    _ = credentials_mod;
    _ = http_mod;
    _ = ssh_mod;
    _ = git_mod;
}
