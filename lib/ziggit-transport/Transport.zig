//! The transport interface every backend implements, and the settings
//! bag every operation carries.
//!
//! The vtable is at the command level, not the byte level. `command`
//! sends one whole v2 command (`ls-refs` or `fetch`) and answers with a
//! reader over the whole response. `Http` implements it as one POST per
//! call, which is what git calls stateless-rpc. A later SSH
//! implementation implements it as a write on a long-lived channel
//! instead; that difference stays inside each implementation and never
//! reaches this interface.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("ziggit-core");
const proto = @import("ziggit-proto");

const errors_mod = @import("errors.zig");
const credentials_mod = @import("credentials.zig");

pub const Error = errors_mod.Error;
pub const isTransient = errors_mod.isTransient;

pub const Credential = credentials_mod.Credential;
pub const AllowedTypes = credentials_mod.AllowedTypes;
pub const CredentialCallback = credentials_mod.CredentialCallback;

pub const Diagnostic = core.Diagnostic;
pub const Capabilities = proto.Capabilities;

/// Reports transfer progress. Called from inside a read, so it must not
/// block and must not allocate: a caller that needs either does its own
/// work on another task and treats this as a signal, not a hook to run
/// work from.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    onBytes: *const fn (ctx: ?*anyopaque, received: u64, total: ?u64) void,
};

/// Every network setting one operation uses. Nothing here is a process
/// global: a caller that runs two fetches at once, against two hosts,
/// gives each its own `Options` and never reaches for a shared one.
pub const Options = struct {
    /// Which remote service this transport talks to. It picks the url, the
    /// daemon request line or the ssh command, so it is fixed when the
    /// transport opens rather than per call: ssh runs one remote process
    /// for the life of its channel.
    service: Service = .upload_pack,
    credentials: ?CredentialCallback = null,
    credentials_ctx: ?*anyopaque = null,
    progress: ?Progress = null,
    /// A CA bundle file, as curl's `--cacert`. Null uses zurl's embedded
    /// roots.
    ca_cert_file: ?[]const u8 = null,
    /// A directory of CA certificates, as curl's `--capath`.
    ca_cert_dir: ?[]const u8 = null,
    connect_timeout_ms: u32 = 15_000,
    stall_timeout_s: u32 = 300,
    proxy_url: ?[]const u8 = null,
    follow_redirects: u8 = 10,
};

/// Which git service a transport talks to. Fetch uses `upload_pack` and
/// protocol v2. Push uses `receive_pack`, which has no v2 at all, so a
/// caller asking for it reads a v1 ref advertisement and must not send
/// the v2 protocol header.
pub const Service = enum {
    upload_pack,
    receive_pack,

    /// The name git puts on the wire, in a url, a daemon request line or
    /// an ssh exec command.
    pub fn wireName(s: Service) []const u8 {
        return switch (s) {
            .upload_pack => "git-upload-pack",
            .receive_pack => "git-receive-pack",
        };
    }
};

/// One v2 command: its name, for the implementation's own bookkeeping,
/// and the pre-encoded pkt-line body `ziggit-proto` already wrote.
pub const Command = struct {
    // "ls-refs" or "fetch". `Http` hardcodes the one url every command
    // posts to and never reads this; it exists so the SSH transport,
    // which must pick the channel command a name selects, has the same
    // shape to read as `Http` does.
    name: []const u8,
    body: []const u8,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (ctx: *anyopaque, gpa: Allocator, diag: ?*?Diagnostic) Error!Capabilities,
        /// The reader written to `out` is valid only until the next
        /// `capabilities` or `command` call on the same `Transport`. A
        /// caller must drain it, or copy what it needs out of it, before
        /// making that next call; the implementation is free to reuse or
        /// free the memory behind it once that call starts.
        command: *const fn (ctx: *anyopaque, gpa: Allocator, cmd: Command, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void,
        /// The v1 ref advertisement, for a service with no v2 form. The
        /// reader is positioned at the first advertisement pkt-line, with
        /// any transport specific prefix already consumed, and is
        /// invalidated by the next call on the same `Transport` exactly as
        /// `command`'s is.
        advertiseRefs: *const fn (ctx: *anyopaque, gpa: Allocator, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn capabilities(t: Transport, gpa: Allocator, diag: ?*?Diagnostic) Error!Capabilities {
        return t.vtable.capabilities(t.ptr, gpa, diag);
    }

    /// See `VTable.command`: the reader this writes to `out` is
    /// invalidated by the next `capabilities` or `command` call on `t`.
    pub fn command(t: Transport, gpa: Allocator, cmd: Command, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void {
        return t.vtable.command(t.ptr, gpa, cmd, out, diag);
    }

    /// See `VTable.advertiseRefs`.
    pub fn advertiseRefs(t: Transport, gpa: Allocator, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void {
        return t.vtable.advertiseRefs(t.ptr, gpa, out, diag);
    }

    pub fn close(t: Transport) void {
        t.vtable.close(t.ptr);
    }
};
