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

    pub fn close(t: Transport) void {
        t.vtable.close(t.ptr);
    }
};
