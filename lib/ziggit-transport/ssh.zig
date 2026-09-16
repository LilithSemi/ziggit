//! `git-upload-pack` over one SSH `exec` channel, driven over `zurl-ssh`.
//!
//! **The vtable is at the command level, and SSH keeps one channel open
//! for the whole session.** `Ssh.open` dials, checks the host key, logs
//! in, and runs `git-upload-pack '<path>'` on one long-lived `exec`
//! channel. `Http` posts once per command; `Ssh` writes each command's
//! pkt-line body to that same channel and answers with a reader over the
//! same channel, because one remote `git-upload-pack` process serves
//! every v2 command of the session. `Command.name` names which command is
//! on the wire, for this module's own diagnostics: `Http` never reads it.
//!
//! **One `zurl_ssh.Client` per `Ssh`, owned by it.** The client and the
//! host-key checker it uses cannot move once they are running, so both
//! live in one heap block (`State`) that this value only ever reaches
//! through a stable pointer; `Ssh` itself stays a small, freely copyable
//! handle.
//!
//! **Host key trust has no default.** `SshOptions.verifier` is required.
//! When `known_hosts_path` is set, the file decides on its own: a
//! record that matches is trusted, anything else is refused, and the
//! caller's own verifier is never asked. A file that cannot be read is a
//! refusal before any socket opens, never a fall-through to trust. When no
//! path is given, every decision goes straight to the caller's verifier.
//!
//! **The repository path is quoted with `zurl_scp.command`'s rule and no
//! other.** That module's own header says a second command builder is how
//! the next injection gets in; this file reuses `command.quote` rather
//! than writing one.
//!
//! **This sends `GIT_PROTOCOL=version=2` as an SSH `env` request, after
//! `open` and before `exec`.** RFC 4254 section 6.4 is git's only way to
//! ask for wire protocol v2 over SSH. There is no other channel for it.
//! **A refusal is the common case, not a fault.** Most `sshd` config
//! (`AcceptEnv`) names no such variable, so a stock server answers
//! `SSH_MSG_CHANNEL_FAILURE`. This treats that one answer as expected: it
//! is not raised past `open`, and the `exec` request after it still runs
//! on the same channel.
//!
//! **This does not make v2 reachable everywhere.** A server that refuses
//! the `env` request answers wire protocol v0, and `ziggit-proto` refuses
//! v0 by design. So this transport reaches a host whose shell reads
//! `GIT_PROTOCOL` (GitHub, GitLab and Gitea all do), and fails, clearly,
//! against a stock `sshd` with a default `AcceptEnv`: `capabilitiesImpl`
//! names the protocol mismatch rather than reporting a bare parse fault.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zurl_ssh = @import("zurl-ssh");
const zurl_scp = @import("zurl-scp");

const core = @import("ziggit-core");
const proto = @import("ziggit-proto");
const pktline_mod = @import("ziggit-pktline");

const transport_mod = @import("Transport.zig");
const Transport = transport_mod.Transport;
const Options = transport_mod.Options;
const Command = transport_mod.Command;
const Capabilities = transport_mod.Capabilities;
const Diagnostic = transport_mod.Diagnostic;
const Error = transport_mod.Error;

const credentials_mod = @import("credentials.zig");
const Credential = credentials_mod.Credential;

/// A reader over one SSH channel, adapting `zurl_ssh.Channel.read` to
/// `std.Io.Reader`.
///
/// One instance lives for the whole session, reused across every
/// `capabilities` and `command` call: the underlying channel is the same
/// long-lived process for all of them. `Ssh.open`'s doc explains why. A
/// caller that has not drained a previous response gives up whatever was
/// left in it the moment the next call resets `seek`/`end`, which the
/// `Transport` contract already allows.
const ChannelReader = struct {
    channel: *zurl_ssh.Channel,
    /// The concrete fault behind the last `error.ReadFailed` this
    /// reported, or null. Read by whoever wants more than that one name.
    last_error: ?zurl_ssh.Channel.Error = null,
    interface: std.Io.Reader,

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn init(channel: *zurl_ssh.Channel, buffer: []u8) ChannelReader {
        return .{
            .channel = channel,
            .last_error = null,
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const cr: *ChannelReader = @alignCast(@fieldParentPtr("interface", r));
        var scratch: [4096]u8 = undefined;
        const want = limit.minInt(scratch.len);
        if (want == 0) return 0;
        const got = cr.channel.read(scratch[0..want]) catch |err| {
            cr.last_error = err;
            return error.ReadFailed;
        };
        // `Channel.read` returning zero means the peer will send no more:
        // it has sent `SSH_MSG_CHANNEL_EOF` or `_CLOSE` and nothing is
        // left buffered. That is exactly what `std.Io.Reader.stream`
        // reports as `error.EndOfStream`.
        if (got == 0) return error.EndOfStream;
        w.writeAll(scratch[0..got]) catch return error.WriteFailed;
        return got;
    }
};

/// Everything this session owns that must not move once it is running:
/// the client (its `Transport` and `Channel` hold pointers into each
/// other), the host-key checker a `Verifier` may point at, and the reader
/// built over the client's own channel.
///
/// Allocated once with `gpa.create` so that `Ssh`, which the brief's
/// signature returns by value, can be copied and moved freely: it only
/// ever carries a pointer to this block.
const State = struct {
    gpa: Allocator,
    client: zurl_ssh.Client,
    /// The SSH agent this session signs through, when the caller answered
    /// with an `ssh_agent` credential. Null for every other credential.
    ///
    /// Allocated rather than held by value: `zurl_ssh.AgentClient` is tens
    /// of kilobytes and **must not move once `connect` has run**, and it
    /// is only worth that space on the sessions that use it. `Client`
    /// borrows the `Signer` this hands out for the whole session, so it
    /// must outlive the client and is closed after it in `deinit`.
    agent: ?*zurl_ssh.AgentClient,
    checker: ?zurl_ssh.knownhosts.Checker,
    /// Owned; the text `checker.policy.known_hosts` borrows. Freed at
    /// `deinit`.
    known_hosts_text: ?[]u8,
    ssh_options: Ssh.SshOptions,
    /// Owned; `Client.Options.peer.host` borrows it for the session's
    /// whole life, including every rekey, so it cannot be a slice into a
    /// caller's `url`.
    host: []u8,
    /// What the remote command has written to standard error, accumulated
    /// across the whole session. Never mixed into a `capabilities` or
    /// `command` reader.
    stderr_buf: std.ArrayList(u8),
    /// The `diag` of whichever `capabilities`/`command` call is current,
    /// so the stderr sink (called from inside a channel read, at any
    /// point during that call) has somewhere to report through.
    pending_diag: ?*?Diagnostic,
    reader: ChannelReader,
    reader_buffer: [8192]u8,
};

pub const Ssh = struct {
    gpa: Allocator,
    io: std.Io,
    state: *State,

    /// Decides whether `key`, of `key_type` (the wire algorithm name, e.g.
    /// `"ssh-ed25519"`), belongs to `host`. True trusts it.
    pub const HostKeyVerifier = *const fn (
        ctx: ?*anyopaque,
        host: []const u8,
        key_type: []const u8,
        key: []const u8,
    ) bool;

    pub const SshOptions = struct {
        /// A `known_hosts` file that decides host key trust on its own. A
        /// match trusts the key; anything else, including a file that
        /// cannot be read, refuses it and never reaches `verifier`. Null
        /// sends every host key straight to `verifier` instead.
        known_hosts_path: ?[]const u8 = null,
        /// No default and no bypass. A caller must decide host key trust.
        verifier: HostKeyVerifier,
        verifier_ctx: ?*anyopaque = null,
    };

    /// Dials `url` (`ssh://user@host[:port]/path`), checks the host key,
    /// logs in, and runs `git-upload-pack '<path>'` on one `exec` channel.
    ///
    /// `options.credentials` is asked once, for an `ssh_key` credential;
    /// a `null` callback, a `null` answer, or an answer of a shape this
    /// transport cannot use is `error.AuthRequired`.
    pub fn open(gpa: Allocator, io: std.Io, url: []const u8, options: Options, ssh: SshOptions) Error!Ssh {
        const parsed = try parseUrl(url);

        const cb = options.credentials orelse return error.AuthRequired;
        const cred = cb(options.credentials_ctx, url, parsed.host, .{
            .bearer = false,
            .basic = false,
            .ssh_key = true,
            .ssh_agent = true,
        }) orelse return error.AuthRequired;

        var key_location: zurl_ssh.keyfile.Location = .{};
        var key_passphrase: ?[]const u8 = null;
        var key_required = false;
        var agent_socket: ?[]const u8 = null;
        switch (cred) {
            .none => {},
            .ssh_key => |k| {
                key_location = .{ .path = k.path };
                key_passphrase = k.passphrase;
                key_required = true;
            },
            .ssh_agent => |a| agent_socket = a.socket_path,
            .bearer, .basic => return error.AuthRequired,
        }

        const state = gpa.create(State) catch return error.OutOfMemory;
        errdefer gpa.destroy(state);
        state.agent = null;
        errdefer if (state.agent) |a| {
            a.close();
            gpa.destroy(a);
        };
        state.gpa = gpa;
        state.ssh_options = ssh;
        state.known_hosts_text = null;
        state.checker = null;
        state.stderr_buf = .empty;
        state.pending_diag = null;

        state.host = gpa.dupe(u8, parsed.host) catch return error.OutOfMemory;
        errdefer gpa.free(state.host);

        if (ssh.known_hosts_path) |path| {
            var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const opened = zurl_ssh.knownhosts.read(gpa, io, .{ .path = path }, &path_storage) catch
                return error.HostKeyRejected;
            state.known_hosts_text = opened.text;
            state.checker = .{ .policy = .{ .known_hosts = opened.text } };
        }
        errdefer if (state.known_hosts_text) |text| gpa.free(text);

        const verifier: zurl_ssh.hostkey.Verifier = if (state.checker) |*checker|
            checker.verifier()
        else
            .{ .ctx = state, .decide = callerVerifierDecide };

        // Connected and asked for an identity BEFORE the client dials, so
        // an agent that is missing or holds no usable key is reported
        // without first spending a round trip on the git host.
        //
        // The order of these two calls is load bearing: `signer()` answers
        // null until `selectIdentity` has run, and a null signer is not an
        // error, it is "sign with a key file" instead. Reversing them
        // would silently fall back rather than fault.
        var agent_signer: ?zurl_ssh.signer.Signer = null;
        if (agent_socket) |socket_path| {
            const agent = gpa.create(zurl_ssh.AgentClient) catch return error.OutOfMemory;
            agent.connect(io, socket_path, .{}) catch {
                gpa.destroy(agent);
                return error.SshAgentUnavailable;
            };
            state.agent = agent;
            _ = agent.selectIdentity() catch |err| switch (err) {
                error.NoUsableIdentity => return error.NoUsableAgentKey,
                else => return error.SshAgentUnavailable,
            };
            agent_signer = agent.signer();
        }

        state.client.open(gpa, io, .{
            .peer = .{ .host = state.host, .port = parsed.port },
            .verifier = verifier,
            .user = parsed.user,
            .signer = agent_signer,
            .key_location = key_location,
            .key_passphrase = key_passphrase,
            .key_required = key_required,
            .connect_timeout = .{
                .duration = .{ .raw = .fromMilliseconds(options.connect_timeout_ms), .clock = .awake },
            },
            .stall = .{ .duration = .{ .raw = .fromSeconds(options.stall_timeout_s), .clock = .awake } },
            .stderr = .{ .ctx = state, .write = showStderr },
        }) catch |err| return mapClientError(err);
        errdefer state.client.close();

        const env_buf = gpa.alloc(u8, git_protocol_name.len + git_protocol_value.len + zurl_ssh.connection.max_control_bytes) catch
            return error.OutOfMemory;
        defer gpa.free(env_buf);
        // A refusal here is not fatal: see this file's own doc comment.
        state.client.channel.requestEnv(env_buf, git_protocol_name, git_protocol_value) catch |err| switch (err) {
            error.ChannelRequestRefused => {},
            else => return mapChannelError(err),
        };

        const command_text = try buildExecCommand(parsed.path);
        const exec_buf = gpa.alloc(u8, command_text.len() + zurl_ssh.connection.max_control_bytes) catch
            return error.OutOfMemory;
        defer gpa.free(exec_buf);
        state.client.channel.requestExec(exec_buf, command_text.slice()) catch |err|
            return mapChannelError(err);

        state.reader = ChannelReader.init(&state.client.channel, &state.reader_buffer);

        return .{ .gpa = gpa, .io = io, .state = state };
    }

    pub fn transport(s: *Ssh) Transport {
        return .{ .ptr = s, .vtable = &vtable };
    }

    pub fn deinit(s: *Ssh) void {
        // The client first: it borrows the agent's `Signer` for the
        // whole session, so the agent has to outlive it.
        s.state.client.close();
        if (s.state.agent) |a| {
            a.close();
            s.gpa.destroy(a);
        }
        if (s.state.known_hosts_text) |text| s.gpa.free(text);
        s.gpa.free(s.state.host);
        s.state.stderr_buf.deinit(s.gpa);
        s.gpa.destroy(s.state);
        s.* = undefined;
    }

    const vtable: Transport.VTable = .{
        .capabilities = capabilitiesImpl,
        .command = commandImpl,
        .close = closeImpl,
    };

    fn capabilitiesImpl(ctx: *anyopaque, gpa: Allocator, diag: ?*?Diagnostic) Error!Capabilities {
        const s: *Ssh = @ptrCast(@alignCast(ctx));
        s.state.pending_diag = diag;
        s.state.reader.interface.seek = 0;
        s.state.reader.interface.end = 0;

        var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
        return proto.parseCapabilities(gpa, &s.state.reader.interface, &buf) catch |err| {
            // `UnsupportedProtocol` here almost always means the server
            // refused the `GIT_PROTOCOL` env request and answered wire
            // protocol v0, which this build does not implement. Name that,
            // rather than leave a user staring at a bare parse fault.
            const msg = switch (err) {
                error.UnsupportedProtocol => "the ssh server answered git protocol v0 or v1, which this build does not implement, most likely because it refused the GIT_PROTOCOL request",
                else => "reading the ssh capability advertisement failed",
            };
            recordMessage(gpa, diag, msg);
            return err;
        };
    }

    /// See `VTable.command`. The write goes to the one `exec` channel
    /// `open` started; the reader this hands back is the same one every
    /// call reuses, reset to read the reply to `cmd` from where the
    /// previous call's reply left off.
    fn commandImpl(ctx: *anyopaque, gpa: Allocator, cmd: Command, out: **std.Io.Reader, diag: ?*?Diagnostic) Error!void {
        const s: *Ssh = @ptrCast(@alignCast(ctx));
        s.state.pending_diag = diag;
        s.state.reader.interface.seek = 0;
        s.state.reader.interface.end = 0;

        s.state.client.channel.write(cmd.body) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "the ssh channel failed while writing the '{s}' command",
                .{cmd.name},
            ) catch "the ssh channel failed while writing the command";
            recordMessage(gpa, diag, msg);
            return mapChannelError(err);
        };

        out.* = &s.state.reader.interface;
    }

    /// Signals the remote `git-upload-pack` that no more commands are
    /// coming. Best effort: the session is torn down for good by
    /// `deinit`, which a caller must still call.
    fn closeImpl(ctx: *anyopaque) void {
        const s: *Ssh = @ptrCast(@alignCast(ctx));
        s.state.client.channel.sendEof() catch {};
    }
};

/// Wraps the caller's `HostKeyVerifier` as a `zurl_ssh.hostkey.Verifier`,
/// for when `SshOptions.known_hosts_path` is null. Reached only for a
/// `ssh-ed25519` key: `zurl_ssh` refuses every other type during
/// negotiation, before any `Verifier` is ever asked.
fn callerVerifierDecide(
    ctx: ?*anyopaque,
    peer: zurl_ssh.hostkey.Peer,
    key: zurl_ssh.hostkey.PublicKey,
    blob: []const u8,
) zurl_ssh.hostkey.TrustError!void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const key_type = zurl_ssh.hostkey.name(key.algorithm());
    const accepted = state.ssh_options.verifier(state.ssh_options.verifier_ctx, peer.host, key_type, blob);
    if (!accepted) return error.HostKeyRejected;
}

/// Routes the remote command's standard error into `diag`, rather than
/// discarding it or mixing it into the protocol stream. `ctx` is the
/// `State` the channel was opened with.
fn showStderr(ctx: ?*anyopaque, text: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.stderr_buf.appendSlice(state.gpa, text) catch return;
    const diag = state.pending_diag orelse return;
    const copy = state.gpa.dupe(u8, state.stderr_buf.items) catch return;
    core.report(diag, state.gpa, .{ .kind = .io, .path = null, .detail = copy });
}

/// A parsed `ssh://user@host[:port]/path` remote url.
///
/// **Minimal on purpose.** No `user@host:path` shorthand, no percent
/// decoding: nothing in the test list needs either, and each is a place
/// for a second, subtly different path-quoting question to creep in.
const ParsedUrl = struct {
    user: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) Error!ParsedUrl {
    const prefix = "ssh://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.UnsupportedProtocol;
    const rest = url[prefix.len..];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.ProtocolError;
    const authority = rest[0..slash];
    const path = rest[slash..];
    // The bare "/" a url with no path at all would leave.
    if (path.len <= 1) return error.ProtocolError;

    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return error.ProtocolError;
    const user = authority[0..at];
    const hostport = authority[at + 1 ..];
    if (user.len == 0 or hostport.len == 0) return error.ProtocolError;

    var host = hostport;
    var port: u16 = zurl_ssh.Client.default_port;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        host = hostport[0..colon];
        port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.ProtocolError;
    }
    if (host.len == 0) return error.ProtocolError;

    return .{ .user = user, .host = host, .port = port, .path = path };
}

/// `"git-upload-pack "` followed by `path` quoted with `zurl_scp.command`'s
/// rule. Its module header states that rule once; nothing here writes a
/// second one.
const ExecCommand = struct {
    storage: [exec_prefix.len + 2 + zurl_scp.command.max_path_bytes * zurl_scp.command.quote_growth]u8,
    text_len: usize,

    fn slice(c: *const ExecCommand) []const u8 {
        return c.storage[0..c.text_len];
    }

    fn len(c: *const ExecCommand) usize {
        return c.text_len;
    }
};

const exec_prefix = "git-upload-pack ";

/// The `env` request name and value git sends to ask for wire protocol
/// v2 over SSH. See this file's module doc comment for why a refusal of
/// this request is expected and not an error.
const git_protocol_name = "GIT_PROTOCOL";
const git_protocol_value = "version=2";

fn buildExecCommand(path: []const u8) Error!ExecCommand {
    // Checked before any quoting runs, so a path far past what this
    // build ever sends cannot make `quote` walk megabytes of input first.
    if (path.len == 0 or path.len > zurl_scp.command.max_path_bytes) return error.ProtocolError;

    var out: ExecCommand = .{ .storage = undefined, .text_len = 0 };
    @memcpy(out.storage[0..exec_prefix.len], exec_prefix);
    const quoted = zurl_scp.command.quote(out.storage[exec_prefix.len..], path) catch
        return error.ProtocolError;
    out.text_len = exec_prefix.len + quoted.len;
    return out;
}

fn recordMessage(gpa: Allocator, diag: ?*?Diagnostic, msg: []const u8) void {
    if (!core.wants(diag)) return;
    const detail = gpa.dupe(u8, msg) catch return;
    core.report(diag, gpa, .{ .kind = .io, .path = null, .detail = detail });
}

/// Maps a fault from `zurl_ssh.Client.open` onto this project's taxonomy.
///
/// **`open` carries no `diag` parameter**, so none of these carries
/// detail text; only the error code says which. `PrivateKeyAlgorithmUnsupported`
/// covers the caller's own key (an RSA or other key this build cannot
/// sign with); `NoCommonHostKeyAlgorithm` covers the server's (it offered
/// no `ssh-ed25519` host key). Both are `UnsupportedKeyType`, because both
/// answers are the same one: `std.crypto` carries no RSA signer.
fn mapClientError(err: zurl_ssh.Client.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PrivateKeyAlgorithmUnsupported => error.UnsupportedKeyType,
        error.NoCommonHostKeyAlgorithm => error.UnsupportedKeyType,
        error.HostKeyUnknown,
        error.HostKeyChanged,
        error.HostKeyRejected,
        error.HostKeyAlgorithmUnknown,
        error.HostKeyCheckFailed,
        => error.HostKeyRejected,
        error.AuthenticationFailed, error.NoUsableAuthMethod => error.AuthFailed,
        else => error.NetworkFailed,
    };
}

fn mapChannelError(err: zurl_ssh.Channel.Error) Error {
    return switch (err) {
        error.ChannelOpenRefused, error.ChannelRequestRefused => error.ProtocolError,
        else => error.ConnectionLost,
    };
}

const testing = std.testing;

fn acceptAllVerifier(ctx: ?*anyopaque, host: []const u8, key_type: []const u8, key: []const u8) bool {
    _ = ctx;
    _ = host;
    _ = key_type;
    _ = key;
    return true;
}

fn rejectAllVerifier(ctx: ?*anyopaque, host: []const u8, key_type: []const u8, key: []const u8) bool {
    _ = ctx;
    _ = host;
    _ = key_type;
    _ = key;
    return false;
}

/// A temporary home for one private key file, so a credential callback
/// can name a real path on disk.
const TestKeyFile = struct {
    tmp: testing.TmpDir,
    storage: [std.Io.Dir.max_path_bytes]u8,
    len: usize,

    fn init(t: *TestKeyFile, name: []const u8, contents: []const u8) !void {
        t.tmp = testing.tmpDir(.{});
        errdefer t.tmp.cleanup();
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });

        var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_len = try t.tmp.dir.realPath(testing.io, &root_storage);
        const p = try std.fmt.bufPrint(&t.storage, "{s}/{s}", .{ root_storage[0..root_len], name });
        t.len = p.len;
    }

    fn deinit(t: *TestKeyFile) void {
        t.tmp.cleanup();
    }

    fn path(t: *const TestKeyFile) []const u8 {
        return t.storage[0..t.len];
    }
};

fn testUrl(buf: []u8, port: u16, repo_path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "ssh://alice@127.0.0.1:{d}{s}", .{ port, repo_path }) catch unreachable;
}

// expected

test "open runs git-upload-pack with the repository path" {
    const gpa = testing.allocator;
    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{ .service = .idle, .accept_request = "exec" },
    });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    var s = try Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    defer s.deinit();

    try testing.expectEqualStrings("git-upload-pack '/tmp/test-repo.git'", server.execCommand());
}

test "command writes to the exec channel and reads the reply" {
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";

    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{
            .service = .write_body,
            .body = packfile_response,
            .accept_request = "exec",
        },
    });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    var s = try Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    defer s.deinit();

    var out: *std.Io.Reader = undefined;
    try s.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    const body = try out.allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    try testing.expectEqualStrings(packfile_response, body);
}

test "a server that refuses the env request still runs the exec that follows it" {
    // **This is the case a real host meets in the field.** OpenSSH answers
    // an `env` request from `AcceptEnv`, which names nothing by default, so
    // the ordinary answer is `SSH_MSG_CHANNEL_FAILURE`. `Ssh.open` must not
    // treat that as a broken channel: the command still has to run and its
    // output still has to come back, on the very same channel.
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";

    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{
            .service = .write_body,
            .body = packfile_response,
            // Only "exec" is accepted, so the "env" request ahead of it is
            // refused: this is the fixture's own model of a stock `sshd`.
            .accept_request = "exec",
        },
    });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    var s = try Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    defer s.deinit();

    // The refused request still carried the right name and value: a
    // refusal is not a reason to have sent nothing, or the wrong thing.
    try testing.expectEqualStrings("GIT_PROTOCOL", server.envName());
    try testing.expectEqualStrings("version=2", server.envValue());
    try testing.expectEqualStrings("git-upload-pack '/tmp/test-repo.git'", server.execCommand());

    var out: *std.Io.Reader = undefined;
    try s.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, null);

    const body = try out.allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    try testing.expectEqualStrings(packfile_response, body);
}

test "a server that accepts the env request answers it with success, not a refusal" {
    // **The fixture accepts one named request per connection and stops
    // there** (see `zurl_ssh.Channel.requestEnv`'s own test of this exact
    // shape), so a server that accepts both `env` and the `exec` after it
    // cannot be modelled in one connection. This drives `zurl_ssh.Client`
    // directly, with the same name, value and buffer size `Ssh.open` uses,
    // to prove the accepting half of that same call: no
    // `ChannelRequestRefused`, and the name and value reach the wire
    // unchanged.
    const gpa = testing.allocator;

    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{ .service = .idle, .accept_request = "env" },
    });
    defer server.stop();

    var client: zurl_ssh.Client = undefined;
    try client.open(gpa, testing.io, .{
        .peer = .{ .host = "127.0.0.1", .port = server.port() },
        .verifier = server.verifier(),
        .user = "alice",
    });
    defer client.close();

    var buf: [git_protocol_name.len + git_protocol_value.len + zurl_ssh.connection.max_control_bytes]u8 = undefined;
    try client.channel.requestEnv(&buf, git_protocol_name, git_protocol_value);

    try testing.expectEqualStrings(git_protocol_name, server.envName());
    try testing.expectEqualStrings(git_protocol_value, server.envValue());
}

test "the server's stderr is captured and not mixed into the protocol stream" {
    const gpa = testing.allocator;
    const packfile_response = "0008NAK\n0000";

    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{
            .service = .write_body,
            .body = packfile_response,
            .stderr_text = "remote: warning about something\n",
            .accept_request = "exec",
        },
    });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    var s = try Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    defer s.deinit();

    var diag: ?Diagnostic = null;
    defer if (diag) |*d| d.deinit(gpa);

    var out: *std.Io.Reader = undefined;
    try s.transport().command(gpa, .{ .name = "fetch", .body = "0000" }, &out, &diag);

    const body = try out.allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    // The body carries only what git-upload-pack itself wrote.
    try testing.expectEqualStrings(packfile_response, body);

    // The stderr text reached diag, and not the body above.
    try testing.expect(diag != null);
    try testing.expect(std.mem.indexOf(u8, diag.?.detail.?, "remote: warning about something") != null);
}

// suspicious

test "a host key that is not ed25519 is UnsupportedKeyType, not a handshake failure" {
    const gpa = testing.allocator;
    var server: zurl_ssh.test_server = undefined;
    // No ed25519 in the offer, so negotiation itself finds no common
    // host key algorithm: this build offers only ed25519.
    try server.start(.{ .host_key_names = "ssh-rsa" });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    const result = Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    try testing.expectError(error.UnsupportedKeyType, result);
}

test "a host key the verifier rejects is HostKeyRejected" {
    const gpa = testing.allocator;
    var server: zurl_ssh.test_server = undefined;
    try server.start(.{});
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    const result = Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = rejectAllVerifier });
    try testing.expectError(error.HostKeyRejected, result);
}

test "a repository path containing a single quote is quoted, not injected" {
    const gpa = testing.allocator;
    var server: zurl_ssh.test_server = undefined;
    try server.start(.{
        .auth = .{ .accept_none = true, .methods = "none" },
        .connection = .{ .service = .idle, .accept_request = "exec" },
    });
    defer server.stop();

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/it's-a-repo.git");

    var s = try Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    defer s.deinit();

    try testing.expectEqualStrings(
        "git-upload-pack '/tmp/it'\"'\"'s-a-repo.git'",
        server.execCommand(),
    );
}

test "a missing known_hosts file fails closed rather than trusting" {
    const gpa = testing.allocator;

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .none = {} };
        }
    };

    // No server: a missing file is refused before any socket opens, and
    // a verifier that would accept everything is never asked.
    const result = Ssh.open(
        gpa,
        testing.io,
        "ssh://alice@127.0.0.1:1/tmp/test-repo.git",
        .{ .credentials = Cb.get },
        .{ .verifier = acceptAllVerifier, .known_hosts_path = "/nonexistent/ziggit-test-known-hosts" },
    );
    try testing.expectError(error.HostKeyRejected, result);
}

test "an RSA client key is UnsupportedKeyType with a message naming the limit" {
    const gpa = testing.allocator;
    var key_file: TestKeyFile = undefined;
    try key_file.init("id_rsa", zurl_ssh.privatekey.test_rsa_key);
    defer key_file.deinit();

    var server: zurl_ssh.test_server = undefined;
    try server.start(.{});
    defer server.stop();

    const Cb = struct {
        var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var path_len: usize = 0;

        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .ssh_key = .{ .path = path_storage[0..path_len], .passphrase = null } };
        }
    };
    @memcpy(Cb.path_storage[0..key_file.path().len], key_file.path());
    Cb.path_len = key_file.path().len;

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, server.port(), "/tmp/test-repo.git");

    // `open` carries no `diag` parameter (see `mapClientError`'s doc), so
    // only the error code is checked here: this build has no way to hand
    // back the "std.crypto has no RSA signer" text from this call.
    const result = Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier });
    try testing.expectError(error.UnsupportedKeyType, result);
}

test "an ssh_agent credential naming a socket that is not there is SshAgentUnavailable" {
    // No server is started, and the port below has nothing listening. So
    // this also pins the ORDER: the agent is contacted before the client
    // dials, and a dial-first implementation would answer with a network
    // fault instead. Contacting a git host before reading the caller's own
    // arguments spends a round trip to learn something already knowable.
    const gpa = testing.allocator;

    const Cb = struct {
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            _ = allowed;
            return .{ .ssh_agent = .{ .socket_path = "/nonexistent/ziggit-test-agent.sock" } };
        }
    };

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, 1, "/tmp/test-repo.git");

    try testing.expectError(
        error.SshAgentUnavailable,
        Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier }),
    );
}

test "the ssh transport offers ssh_agent as an allowed credential shape" {
    // A caller cannot answer with a shape it is never told is allowed, so
    // this flag is the whole interface for reaching the agent.
    const gpa = testing.allocator;

    const Cb = struct {
        var saw_ssh_agent: bool = false;
        fn get(ctx: ?*anyopaque, url_: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?Credential {
            _ = ctx;
            _ = url_;
            _ = host;
            saw_ssh_agent = allowed.ssh_agent;
            return null;
        }
    };
    Cb.saw_ssh_agent = false;

    var url_buf: [128]u8 = undefined;
    const url = testUrl(&url_buf, 1, "/tmp/test-repo.git");

    try testing.expectError(
        error.AuthRequired,
        Ssh.open(gpa, testing.io, url, .{ .credentials = Cb.get }, .{ .verifier = acceptAllVerifier }),
    );
    try testing.expect(Cb.saw_ssh_agent);
}
