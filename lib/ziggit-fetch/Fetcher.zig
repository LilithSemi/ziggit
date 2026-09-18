//! The fetch orchestration: drives `Transport` through the v2 capability
//! check, `ls-refs`, and a bounded `fetch` negotiation, streams the
//! resulting packfile straight into the object database, and updates the
//! local refs the caller's refspecs name.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");

const pack_mod = @import("ziggit-pack");
const writeIndex = pack_mod.writeIndex;
const Index = pack_mod.Index;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const refs_mod = @import("ziggit-refs");
const Store = refs_mod.Store;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

const proto = @import("ziggit-proto");
const Sideband = proto.Sideband;

const transport_mod = @import("ziggit-transport");
const Transport = transport_mod.Transport;

// Not in the brief's declared consumes list, but required structurally:
// `readLsRefs`, `readFetchSection` and `Sideband.init` all take a scratch
// buffer that must be at least `Packet.max_data_length` bytes, and that
// constant lives here.
const pktline_mod = @import("ziggit-pktline");

const refspec_mod = @import("refspec.zig");
const Refspec = refspec_mod.Refspec;

const remote_mod = @import("remote.zig");

const revwalk_mod = @import("ziggit-revwalk");

pub const FetchOptions = struct {
    refspecs: []const Refspec,
    depth: ?u32 = null,
    /// Carried for a caller that wants every fetch's settings in one
    /// place; `t` below already comes open with its own transport
    /// settings, so nothing in this file reads this field back out.
    transport: transport_mod.Options = .{},
    /// Update the local refs the refspecs name. False performs the transfer and
    /// reports what it saw without writing a ref.
    update_refs: bool = true,
    /// Settings for an `ssh://` fetch. `Ssh.open` requires a host key
    /// verifier, and this project supplies no default: trusting every
    /// host key, or refusing every one, are decisions only a caller can
    /// make. Null, the default, means `fetch` refuses any `ssh://` url
    /// with `error.SshVerifierRequired` instead of guessing one. Ignored
    /// for every other scheme.
    ssh: ?transport_mod.Ssh.SshOptions = null,
    /// The remote URL or local path as the caller gave it. Used to write
    /// FETCH_HEAD after a successful fetch. Null when FETCH_HEAD should not
    /// be written, such as in tests or when fetch is called without a URL.
    remote_url: ?[]const u8 = null,
};

/// What happened to one matched refspec's local destination. A written ref
/// is never rolled back once it lands, the same way `git fetch` itself
/// never unwinds one: `failed` names the fault that stopped this one ref
/// alone, and every other refspec still got its own attempt regardless.
pub const RefOutcome = union(enum) {
    updated: struct { old: ?Oid, new: Oid },
    up_to_date,
    rejected_non_fast_forward,
    /// The local ref already exists and is symbolic: it has no oid to
    /// compare or fast-forward from, so this refspec's write is left to
    /// whatever manages symrefs instead of attempted here.
    symbolic_ref_unchanged,
    failed: Error,
};

pub const UpdatedRef = struct {
    name: []const u8, // owned, freed by deinit
    outcome: RefOutcome,

    pub fn deinit(u: *UpdatedRef, gpa: Allocator) void {
        gpa.free(u.name);
        u.* = undefined;
    }
};

pub const Result = struct {
    /// One entry per refspec `fetch` matched against the server's
    /// listing, in the same order `options.refspecs` named them, never
    /// one entry per refspec that merely succeeded. A caller must inspect
    /// each entry's `outcome`: the pack can land safely while one ref
    /// among several is rejected or fails to write, and this is the only
    /// place that shows up. Owned; freed by `deinit`.
    ///
    /// A clean return from `fetchRemote` does NOT mean every ref moved:
    /// check `firstFailure` to know if every matched refspec actually
    /// landed.
    updated: []const UpdatedRef,
    objects_received: u32,
    bytes_received: u64,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        for (r.updated) |item| {
            var mutable = item;
            mutable.deinit(gpa);
        }
        gpa.free(r.updated);
        r.* = undefined;
    }

    /// The first entry whose outcome is not a success, or null when every
    /// matched refspec landed. A clean return from `fetchRemote` does NOT
    /// mean every ref moved: check this.
    pub fn firstFailure(r: Result) ?UpdatedRef {
        for (r.updated) |u| {
            switch (u.outcome) {
                .updated, .up_to_date => {},
                .rejected_non_fast_forward, .symbolic_ref_unchanged, .failed => return u,
            }
        }
        return null;
    }
};

pub const Error = transport_mod.Error || Odb.Error || Store.Error || error{ RefNotFound, CorruptPack, InvalidRefspec, ServerRefusesOidWant };

/// A server that keeps asking to negotiate again without ever reaching
/// `ready` or a packfile is refused after this many round trips, rather
/// than retried forever. This client sends every `have` it has, plus
/// `done`, on round one; a well behaved server always answers with
/// `ready` or `NAK` and a packfile in that very round, so this bound
/// exists only to catch a server that never does, not to budget for a
/// real multi-round negotiation.
const max_negotiation_rounds: usize = 8;

/// Allocation budget the tests below use to read one small object back.
/// A commit's headers and message comfortably fit; this is a policy
/// ceiling against a hostile commit, not a spec limit.
const max_commit_object_len: usize = 1 << 20;

/// Fetches into `repo` over `t`. Streams the packfile straight into the
/// object database; never buffers it whole.
///
/// A returned `Result` can carry a failure for one matched refspec in its
/// `updated` list even though the whole call succeeded: this never rolls
/// back a ref another refspec already wrote, so a caller must inspect
/// `Result.updated` rather than assume every matched refspec landed. This
/// function itself returns an error only for a fault that makes the whole
/// fetch meaningless, a corrupt pack or a transport fault, never for one
/// ref among several being rejected or failing to write.
pub fn fetchRemote(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    t: Transport,
    options: FetchOptions,
    diag: ?*?Diagnostic,
) Error!Result {
    var caps = try t.capabilities(gpa, diag);
    defer caps.deinit(gpa);
    if (!caps.isV2()) return error.UnsupportedProtocol;

    for (options.refspecs) |rs| {
        if (remote_mod.isObjectId(repo.format, rs.src)) {
            const has_tip = caps.has("allow-tip-sha1-in-want");
            const has_reachable = caps.has("allow-reachable-sha1-in-want");
            if (!has_tip and !has_reachable) return error.ServerRefusesOidWant;
        }
    }

    const listing = try lsRefs(gpa, repo.format, t, options.refspecs, diag);
    defer {
        for (listing) |*r| {
            var mutable = r.*;
            mutable.deinit(gpa);
        }
        gpa.free(listing);
    }

    var plan = try remote_mod.buildPlan(gpa, repo.format, options.refspecs, listing);
    defer plan.deinit(gpa);

    if (plan.wants.len == 0) {
        if (core_mod.wants(diag)) {
            const detail = try std.fmt.allocPrint(gpa, "refspec matched no remote refs", .{});
            core_mod.report(diag, gpa, .{ .kind = .io, .path = null, .detail = detail });
        }
        return .{ .updated = &.{}, .objects_received = 0, .bytes_received = 0 };
    }

    var haves: std.ArrayList(Oid) = .empty;
    defer haves.deinit(gpa);
    for (plan.updates) |pu| {
        var existing = repo.refs.lookup(pu.name, null) catch |err| switch (err) {
            error.RefNotFound => continue,
            else => return err,
        };
        defer existing.deinit(gpa);
        switch (existing.target) {
            .oid => |o| try haves.append(gpa, o),
            .symbolic => {},
        }
    }

    var shallow_boundary: std.ArrayList(Oid) = .empty;
    defer shallow_boundary.deinit(gpa);

    const received = try negotiateAndReceive(
        gpa,
        io,
        repo,
        t,
        plan.wants,
        haves.items,
        options.depth,
        &shallow_boundary,
        diag,
    );

    const updated = try applyRefUpdates(gpa, repo, plan.updates, options.update_refs, diag);
    errdefer {
        for (updated) |item| {
            var mutable = item;
            mutable.deinit(gpa);
        }
        gpa.free(updated);
    }

    // Written only once the objects it names are reachable from a ref
    // this fetch just updated, not before: recording a shallow boundary
    // ahead of the refs that reach it would describe history nothing yet
    // points at if this call were interrupted in between.
    if (options.depth != null and shallow_boundary.items.len != 0) {
        try recordShallowBoundary(gpa, io, repo.layout.common_dir, shallow_boundary.items);
    }

    // A caller that asked for no ref updates asked for a dry run, and git
    // writes no FETCH_HEAD for a dry run. Measured, not assumed.
    if (options.update_refs) {
        if (options.remote_url) |url| {
            try writeFetchHead(gpa, io, repo.layout.common_dir, repo.format, plan.updates, url);
        }
    }

    return .{
        .updated = updated,
        .objects_received = received.objects,
        .bytes_received = received.bytes,
    };
}

/// Applies every planned ref update in `updates` against `repo.refs`, in
/// order, never aborting on one ref's failure. Shared by both fetch
/// strategies: `fetchRemote` calls this once its packfile has landed, and
/// `local.zig`'s `fetchLocal` calls this once the objects it copied are
/// all in `repo.odb`. Both hand it the same `remote_mod.PlannedUpdate`
/// shape, so this is the one place the compare-and-swap, fast-forward,
/// and per-ref failure handling live; a second copy of this loop is
/// exactly the kind of drift two independent fetch strategies must not be
/// allowed to develop.
///
/// `update_refs` false skips every ref and returns an empty, still owned,
/// slice: the transfer already happened by the time this is called, and
/// this only decides whether to record it locally.
pub fn applyRefUpdates(
    gpa: Allocator,
    repo: *Repository,
    updates: []const remote_mod.PlannedUpdate,
    update_refs: bool,
    diag: ?*?Diagnostic,
) Error![]UpdatedRef {
    var updated: std.ArrayList(UpdatedRef) = .empty;
    errdefer {
        for (updated.items) |*u| u.deinit(gpa);
        updated.deinit(gpa);
    }
    if (!update_refs) return updated.toOwnedSlice(gpa);

    // Resolved once, here, rather than at the point of each write: a
    // `Store` with no committer refuses any update that carries a
    // reflog message with `error.NoCommitterIdentity`, so a fetch that
    // wants to keep writing refs even with no identity configured must
    // simply never ask for a reflog entry in that case, not discover the
    // refusal from `Store.update` itself.
    const reflog_message: ?[]const u8 = if (repo.refs.committer != null) "fetch" else null;

    for (updates) |pu| {
        var existing = repo.refs.lookup(pu.name, diag) catch |err| switch (err) {
            error.RefNotFound => null,
            else => return err,
        };
        defer if (existing) |*e| e.deinit(gpa);

        const old_oid: ?Oid = if (existing) |e| switch (e.target) {
            .oid => |o| o,
            .symbolic => null,
        } else null;

        const name_owned = try gpa.dupe(u8, pu.name);
        errdefer gpa.free(name_owned);

        // An existing symbolic ref has no oid to compare or
        // fast-forward from; leave it to whatever manages symrefs unless
        // force is set, which overwrites the symbolic ref.
        if (existing != null and old_oid == null) {
            if (!pu.force) {
                try updated.append(gpa, .{ .name = name_owned, .outcome = .symbolic_ref_unchanged });
                continue;
            }
            // Force: overwrite the symbolic ref with the OID, through the
            // same lock, atomic rename, and reflog discipline `update`
            // uses, rather than writing the ref file directly.
            if (repo.refs.forceReplaceSymbolic(pu.name, pu.remote_oid, reflog_message, diag)) |_| {
                try updated.append(gpa, .{
                    .name = name_owned,
                    .outcome = .{ .updated = .{ .old = null, .new = pu.remote_oid } },
                });
            } else |err| {
                // Matches the ordinary per-ref failure handling below:
                // this one ref's failure, a concurrent writer already
                // holding the lock, for example, must not stop the rest.
                try updated.append(gpa, .{ .name = name_owned, .outcome = .{ .failed = err } });
            }
            continue;
        }

        if (old_oid) |old| {
            if (old.eql(pu.remote_oid)) {
                try updated.append(gpa, .{ .name = name_owned, .outcome = .up_to_date });
                continue;
            }
            if (!pu.force) {
                const fast_forward = try revwalk_mod.isAncestor(gpa, repo, old, pu.remote_oid, diag);
                if (!fast_forward) {
                    // Refused; every other ref still proceeds.
                    try updated.append(gpa, .{ .name = name_owned, .outcome = .rejected_non_fast_forward });
                    continue;
                }
            }
        }

        if (repo.refs.update(pu.name, pu.remote_oid, old_oid, reflog_message, diag)) |_| {
            try updated.append(gpa, .{
                .name = name_owned,
                .outcome = .{ .updated = .{ .old = old_oid, .new = pu.remote_oid } },
            });
        } else |err| {
            // A single ref's write failing, a compare-and-swap conflict
            // from a concurrent writer, for example, must not stop the
            // rest: every other matched refspec still gets its own
            // attempt and its own outcome below.
            try updated.append(gpa, .{ .name = name_owned, .outcome = .{ .failed = err } });
        }
    }

    return updated.toOwnedSlice(gpa);
}

/// Runs `ls-refs`, narrowed to the refspecs' own prefixes, and returns the
/// listing. The reader `t.command` hands back is fully drained by
/// `proto.readLsRefs` before this returns, so it never survives past the
/// next `command` call this file makes. Object id sources are skipped: an
/// oid is not a ref name and is not sent as a prefix.
fn lsRefs(
    gpa: Allocator,
    format: Format,
    t: Transport,
    refspecs: []const Refspec,
    diag: ?*?Diagnostic,
) Error![]proto.RefLine {
    var prefixes: std.ArrayList([]const u8) = .empty;
    defer prefixes.deinit(gpa);
    for (refspecs) |rs| {
        if (remote_mod.isObjectId(format, rs.src)) continue;
        const prefix = if (std.mem.endsWith(u8, rs.src, "*")) rs.src[0 .. rs.src.len - 1] else rs.src;
        try prefixes.append(gpa, prefix);
    }

    var body_w: std.Io.Writer.Allocating = .init(gpa);
    defer body_w.deinit();
    proto.writeLsRefs(&body_w.writer, format, .{
        .prefixes = prefixes.items,
        .symrefs = false,
        .peel = false,
    }) catch return error.ProtocolError;

    var reader_ptr: *std.Io.Reader = undefined;
    try t.command(gpa, .{ .name = "ls-refs", .body = body_w.written() }, &reader_ptr, diag);

    var pkt_buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
    return proto.readLsRefs(gpa, format, reader_ptr, &pkt_buf);
}

const ReceivedPack = struct { objects: u32, bytes: u64 };

/// Negotiates with the server and, once it answers with a packfile,
/// streams that packfile into `repo`'s object database.
///
/// Bounded by `max_negotiation_rounds`: this client sends every `have` it
/// already has plus `done` on every round, so a well behaved server
/// always answers with a packfile in round one; retrying at all only
/// covers `fetch.zig`'s documented case of an acknowledgments section
/// followed by a flush with no packfile ("negotiate again"), including
/// the read fault that produces on an exhausted reader when that flush
/// also ends the whole response.
fn negotiateAndReceive(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    t: Transport,
    wants: []const Oid,
    haves: []const Oid,
    depth: ?u32,
    shallow_boundary: *std.ArrayList(Oid),
    diag: ?*?Diagnostic,
) Error!ReceivedPack {
    var pkt_buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    var round: usize = 0;
    while (true) {
        if (round >= max_negotiation_rounds) return error.ProtocolError;
        round += 1;

        var body_w: std.Io.Writer.Allocating = .init(gpa);
        defer body_w.deinit();
        proto.writeFetch(&body_w.writer, repo.format, .{
            .wants = wants,
            .haves = haves,
            .done = true,
            .depth = depth,
        }) catch return error.ProtocolError;

        var reader_ptr: *std.Io.Reader = undefined;
        try t.command(gpa, .{ .name = "fetch", .body = body_w.written() }, &reader_ptr, diag);

        // Once an acknowledgments or NAK section has been seen, a read
        // fault on the next section is indistinguishable from the
        // response simply ending there with no packfile: both consume
        // the same terminating flush. Before that point, a read fault is
        // a genuine protocol failure.
        var negotiate_again_on_fault = false;
        var got_packfile = false;

        section_loop: while (true) {
            if (negotiate_again_on_fault) {
                // Only a reader that has cleanly run dry means "no
                // packfile this round, negotiate again": that is exactly
                // what an acknowledgments or NAK section followed by the
                // response's own closing flush leaves behind. `peek`
                // consumes nothing, so a byte it does find is still there
                // for `readFetchSection` to parse normally; a genuine
                // corruption in that byte then fails this round at once
                // instead of being mistaken for "no packfile" and
                // burning every round the negotiation bound allows.
                _ = reader_ptr.peek(1) catch |err| switch (err) {
                    error.EndOfStream => break :section_loop,
                    error.ReadFailed => return error.ProtocolError,
                };
            }

            var section = try proto.readFetchSection(gpa, repo.format, reader_ptr, &pkt_buf);
            defer section.deinit(gpa);

            switch (section) {
                .acknowledgments => negotiate_again_on_fault = true,
                .nak => negotiate_again_on_fault = true,
                .shallow_info => |si| try shallow_boundary.appendSlice(gpa, si.shallow),
                .wanted_refs => {},
                .packfile => {
                    got_packfile = true;
                    break :section_loop;
                },
                .end => break :section_loop,
            }
        }

        if (got_packfile) {
            var sb = Sideband.init(reader_ptr, &pkt_buf, null);
            return receivePack(gpa, io, &repo.odb, &sb, diag);
        }
        // No packfile this round: negotiate again with the identical
        // request, up to the round bound above.
    }
}

/// Removes `name` from `dir` if it is there. Returns `true` when the
/// removal failed for a reason other than the file simply being absent, so
/// a caller can decide whether that failure is fatal, before writing a
/// fresh temp file, or only worth reporting, while unwinding from a worse
/// fault. `error.FileNotFound` is what a temp file that was never written,
/// or one a concurrent attempt already claimed and cleaned up, looks like:
/// not a fault.
fn removeTempFile(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.AccessDenied,
        error.PermissionDenied,
        error.FileBusy,
        error.FileSystem,
        error.IsDir,
        error.SymLinkLoop,
        error.NotDir,
        error.SystemResources,
        error.ReadOnlyFileSystem,
        error.NetworkNotFound,
        error.NameTooLong,
        error.BadPathName,
        error.Canceled,
        error.Unexpected,
        => return true,
    };
    return false;
}

/// Reports, through `diag` when the caller asked for detail, that `name`
/// could not be removed. `name` is left on disk; this only surfaces that
/// fact, it never retries or fails the caller over it.
fn reportStuckTempFile(diag: ?*?Diagnostic, gpa: Allocator, name: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const detail = std.fmt.allocPrint(gpa, "temp file '{s}' could not be removed", .{name}) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = null, .detail = detail });
}

/// Streams `sb`'s band 1 bytes into a temporary pack file, indexes it,
/// then renames both into `objects/pack`. Nothing lands under its final
/// name until indexing has fully succeeded: a truncated or malformed pack
/// leaves no trace a later `Odb.refreshPacks` would ever see.
///
/// The temp names below are derived from `sb`'s own address, so they are
/// unique to this call: `sb` is a stack value that lives only for this
/// call's own duration, and two live values are never at the same
/// address, so no two calls racing on the same object database, even two
/// fetches sharing one through `Odb.Options.object_directory`, ever pick
/// the same name.
///
/// The final name is the pack's own checksum, the way `git` names a pack:
/// collision free by construction, and it needs no clock and no counter.
/// Refetching identical content lands on the same final name a second
/// time; that is treated as success, not overwritten and not an error.
fn receivePack(gpa: Allocator, io: std.Io, odb: *Odb, sb: *Sideband, diag: ?*?Diagnostic) Error!ReceivedPack {
    var pack_dir = odb.write_dir.createDirPathOpen(io, "pack", .{}) catch return error.IoFailed;
    defer pack_dir.close(io);

    const nonce = @intFromPtr(sb);
    const tmp_pack_name = std.fmt.allocPrint(gpa, "fetch-incoming-{x}.pack.tmp", .{nonce}) catch return error.OutOfMemory;
    defer gpa.free(tmp_pack_name);
    const tmp_idx_name = std.fmt.allocPrint(gpa, "fetch-incoming-{x}.idx.tmp", .{nonce}) catch return error.OutOfMemory;
    defer gpa.free(tmp_idx_name);

    // Best-effort: clear away a temp file a crashed earlier attempt left
    // under this name. Absence is the expected outcome, not a fault;
    // anything else means this name is not actually free to reuse, and
    // that has to stop this call rather than being papered over.
    if (removeTempFile(pack_dir, io, tmp_pack_name)) {
        reportStuckTempFile(diag, gpa, tmp_pack_name);
        return error.IoFailed;
    }
    if (removeTempFile(pack_dir, io, tmp_idx_name)) {
        reportStuckTempFile(diag, gpa, tmp_idx_name);
        return error.IoFailed;
    }
    errdefer {
        if (removeTempFile(pack_dir, io, tmp_pack_name)) reportStuckTempFile(diag, gpa, tmp_pack_name);
        if (removeTempFile(pack_dir, io, tmp_idx_name)) reportStuckTempFile(diag, gpa, tmp_idx_name);
    }

    var bytes_written: u64 = 0;
    {
        const pack_file_w = pack_dir.createFile(io, tmp_pack_name, .{}) catch return error.IoFailed;
        defer pack_file_w.close(io);
        var write_buf: [8192]u8 = undefined;
        var pack_writer = pack_file_w.writer(io, &write_buf);
        bytes_written = sb.reader().streamRemaining(&pack_writer.interface) catch |err| switch (err) {
            error.ReadFailed => return error.CorruptPack,
            error.WriteFailed => return error.IoFailed,
        };
        pack_writer.end() catch return error.IoFailed;
    }

    const indexed = try indexIncomingPack(gpa, io, pack_dir, tmp_pack_name, tmp_idx_name, odb.format);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = indexed.checksum.toHex(&hex_buf);
    const final_pack = std.fmt.allocPrint(gpa, "pack-{s}.pack", .{hex}) catch return error.OutOfMemory;
    defer gpa.free(final_pack);
    const final_idx = std.fmt.allocPrint(gpa, "pack-{s}.idx", .{hex}) catch return error.OutOfMemory;
    defer gpa.free(final_idx);

    // The final name is the pack's own checksum, so a `.pack` already
    // sitting under it is (cryptographically) this same content, landed
    // by an earlier fetch of the identical set of objects or by a
    // concurrent one that got there first. Renaming onto it would only
    // ever replace it with an identical copy, but skipping the rename
    // outright avoids that redundant write and the window where a
    // concurrent reader would otherwise see the file disappear and
    // reappear. The temp files this call made are simply discarded, and
    // this reports the fetch as the success it was: the objects it
    // carried are already on disk.
    const already_landed = blk: {
        pack_dir.access(io, final_pack, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return error.IoFailed,
        };
        break :blk true;
    };
    if (already_landed) {
        if (removeTempFile(pack_dir, io, tmp_idx_name)) reportStuckTempFile(diag, gpa, tmp_idx_name);
        if (removeTempFile(pack_dir, io, tmp_pack_name)) reportStuckTempFile(diag, gpa, tmp_pack_name);
        return .{ .objects = indexed.object_count, .bytes = bytes_written };
    }

    // The `.idx` is renamed into place first. `Odb.refreshPacks` opens
    // every `.idx` it finds and fails its whole scan when the matching
    // `.pack` is missing, so an orphan in either direction is harmful
    // here, not only a pack with no index. Renaming the `.idx` first, and
    // removing it again below if the `.pack` rename then fails, keeps
    // either failure from leaving a half under a final name.
    pack_dir.rename(tmp_idx_name, pack_dir, final_idx, io) catch return error.IoFailed;
    errdefer {
        if (removeTempFile(pack_dir, io, final_idx)) reportStuckTempFile(diag, gpa, final_idx);
    }
    pack_dir.rename(tmp_pack_name, pack_dir, final_pack, io) catch return error.IoFailed;

    try odb.refreshPacks();

    return .{ .objects = indexed.object_count, .bytes = bytes_written };
}

/// What `indexIncomingPack` learned about the pack it just indexed: how
/// many objects it holds, and the checksum it carries over its own
/// trailing bytes. `receivePack` names the pack's final files after that
/// checksum rather than a wall clock reading, since two independent packs
/// built from the same objects always carry the same checksum and two
/// different packs (almost) never do.
const IndexedPack = struct { object_count: u32, checksum: Oid };

fn indexIncomingPack(
    gpa: Allocator,
    io: std.Io,
    pack_dir: std.Io.Dir,
    pack_name: []const u8,
    idx_name: []const u8,
    format: Format,
) Error!IndexedPack {
    const pack_file_r = pack_dir.openFile(io, pack_name, .{}) catch return error.IoFailed;
    defer pack_file_r.close(io);
    var pack_read_buf: [8192]u8 = undefined;
    var pack_reader = pack_file_r.reader(io, &pack_read_buf);

    const idx_file = pack_dir.createFile(io, idx_name, .{ .read = true }) catch return error.IoFailed;
    defer idx_file.close(io);
    var idx_write_buf: [8192]u8 = undefined;
    var idx_writer = idx_file.writer(io, &idx_write_buf);

    try writeIndex(gpa, format, &pack_reader, &idx_writer, null);
    const checksum = try readPackChecksum(&pack_reader, format);

    var idx = Index.open(gpa, io, idx_file, format) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptIndex, error.UnsupportedIndexVersion => return error.CorruptPack,
    };
    defer idx.deinit();
    return .{ .object_count = idx.count(), .checksum = checksum };
}

/// Reads the checksum a packfile carries over its own contents: the last
/// `format.byteLength()` bytes of the file. `writeIndex` has already read
/// through this same file, this trailer included, to build the index just
/// above; this reads the identical bytes back rather than hash the pack a
/// second time, so the pack can be named after the identity it already
/// carries.
fn readPackChecksum(pack_reader: *std.Io.File.Reader, format: Format) Error!Oid {
    const trailer_len = format.byteLength();
    const size = pack_reader.getSize() catch return error.CorruptPack;
    const trailer_start = std.math.sub(u64, size, @as(u64, trailer_len)) catch return error.CorruptPack;
    pack_reader.seekTo(trailer_start) catch return error.CorruptPack;
    var buf: [Oid.max_byte_length]u8 = undefined;
    const bytes = pack_reader.interface.take(trailer_len) catch return error.CorruptPack;
    @memcpy(buf[0..bytes.len], bytes);
    return Oid.fromBytes(format, buf[0..bytes.len]);
}

/// Records the shallow boundary a depth-limited fetch reported, so a
/// later fetch or a walk over history knows where this repository's
/// history is deliberately cut off. This always overwrites the file with
/// exactly the boundary this fetch just saw; it does not merge with an
/// existing one or act on an `unshallow` line, since no caller of this
/// task deepens an already-shallow repository yet.
pub fn recordShallowBoundary(gpa: Allocator, io: std.Io, common_dir: std.Io.Dir, shallow: []const Oid) Error!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (shallow) |oid| {
        var hex_buf: [Oid.max_formatted_length]u8 = undefined;
        out.writer.writeAll(oid.toHex(&hex_buf)) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    common_dir.writeFile(io, .{ .sub_path = "shallow", .data = out.written() }) catch return error.IoFailed;
}

/// Writes FETCH_HEAD, the record of what this fetch brought from the
/// remote. One line per planned update, in plan order. Format is:
///   <full hex oid>\t<merge field>\t<description>\n
///
/// Two rules here were measured against git rather than reasoned about.
///
/// The merge field is always empty. Git writes `not-for-merge` only for a
/// ref that a repository's CONFIGURED refspecs pulled in and that is not
/// the current branch's upstream. Ziggit always fetches with refspecs the
/// caller passed, and git treats every explicitly requested ref as a merge
/// candidate, so the field is empty and the line holds two tabs together.
///
/// The line records the oid the REMOTE advertised, and every planned
/// update gets one, whatever happened to the local ref. Git lists a ref
/// that was already up to date, and lists one whose local update it
/// rejected as a non-fast-forward. FETCH_HEAD says what the remote had,
/// not what changed here, so this takes the plan and never looks at an
/// outcome.
pub fn writeFetchHead(
    gpa: Allocator,
    io: std.Io,
    common_dir: std.Io.Dir,
    format: Format,
    plan_updates: []const remote_mod.PlannedUpdate,
    remote_url: []const u8,
) Error!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (plan_updates) |pu| {
        var hex_buf: [Oid.max_formatted_length]u8 = undefined;
        const oid_hex = pu.remote_oid.toHex(&hex_buf);

        const description = try buildDescription(gpa, format, pu.src_name, pu.src_full, remote_url);
        defer gpa.free(description);

        out.writer.writeAll(oid_hex) catch return error.OutOfMemory;
        out.writer.writeByte('\t') catch return error.OutOfMemory;
        out.writer.writeByte('\t') catch return error.OutOfMemory;
        out.writer.writeAll(description) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }

    common_dir.writeFile(io, .{ .sub_path = "FETCH_HEAD", .data = out.written() }) catch return error.IoFailed;
}

/// Builds the description field of one FETCH_HEAD line. Each form below is
/// git's, captured from real git at authoring time:
/// - a branch source: `branch 'main' of <url>`
/// - a tag source: `tag 'v1' of <url>`
/// - a raw object id source: `'<hex oid>' of <url>`, with no kind word
/// - `HEAD`: `<url>` alone, with no kind word, no name and no `of`
///
/// The last form looks like an omission and is not. Git has no name to
/// print for HEAD, so it prints the url by itself. This is the shape the
/// Nix evaluator asks for, because it fetches `+HEAD:refs/remotes/origin/HEAD`.
fn buildDescription(
    gpa: Allocator,
    format: Format,
    src_name: []const u8,
    src_full: []const u8,
    url: []const u8,
) Allocator.Error![]u8 {
    if (std.mem.eql(u8, src_full, "HEAD")) return gpa.dupe(u8, url);
    // `isObjectId` is the one place that knows how long a hex id is in
    // this repository's hash format. A second rule here, such as "no
    // slash", would call the ref named HEAD an object id and would call a
    // 64 character sha256 id a ref.
    if (remote_mod.isObjectId(format, src_full)) {
        return std.fmt.allocPrint(gpa, "'{s}' of {s}", .{ src_name, url });
    }
    if (std.mem.startsWith(u8, src_full, "refs/tags/")) {
        return std.fmt.allocPrint(gpa, "tag '{s}' of {s}", .{ src_name, url });
    }
    return std.fmt.allocPrint(gpa, "branch '{s}' of {s}", .{ src_name, url });
}

// Test helpers shared by every test below.

const testing = std.testing;

const dummy_tree_hex = "4" ** 40;
const identity_line = "A U Thor <author@example.com> 1700000000 +0000";

fn buildMinimalRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "objects/pack");
    try dir.createDirPath(io, "refs/heads");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
}

/// Builds a commit object payload (the bytes after the loose object
/// header) with `dummy_tree_hex` as its tree, `parent_hex` as its only
/// parent when given, and a fixed author/committer identity. Caller owns
/// and frees the returned slice.
fn buildCommitPayload(gpa: Allocator, parent_hex: ?[]const u8, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("tree {s}\n", .{dummy_tree_hex});
    if (parent_hex) |p| try out.writer.print("parent {s}\n", .{p});
    try out.writer.print("author {s}\n", .{identity_line});
    try out.writer.print("committer {s}\n", .{identity_line});
    try out.writer.print("\n{s}\n", .{message});
    return out.toOwnedSlice();
}

fn commitOid(payload: []const u8) Oid {
    return object_mod.loose.hash(.sha1, .commit, payload);
}

fn buildLsRefsResponse(gpa: Allocator, refs: []const struct { oid: Oid, name: []const u8 }) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    for (refs) |r| {
        var hex_buf: [Oid.max_formatted_length]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.oid.toHex(&hex_buf), r.name });
        defer gpa.free(line);
        try pktline_mod.writeLine(&aw.writer, line);
    }
    try pktline_mod.write(&aw.writer, .flush);
    return aw.toOwnedSlice();
}

fn buildReadyPackResponse(gpa: Allocator, ack_oid: Oid, pack_bytes: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try pktline_mod.writeLine(&aw.writer, "acknowledgments");
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const ack_line = try std.fmt.allocPrint(gpa, "ACK {s}", .{ack_oid.toHex(&hex_buf)});
    defer gpa.free(ack_line);
    try pktline_mod.writeLine(&aw.writer, ack_line);
    try pktline_mod.writeLine(&aw.writer, "ready");
    try pktline_mod.write(&aw.writer, .delimiter);
    try pktline_mod.writeLine(&aw.writer, "packfile");
    const band1 = try std.mem.concat(gpa, u8, &.{ &[_]u8{1}, pack_bytes });
    defer gpa.free(band1);
    try pktline_mod.write(&aw.writer, .{ .data = band1 });
    try pktline_mod.write(&aw.writer, .flush);
    return aw.toOwnedSlice();
}

fn buildShallowPackResponse(gpa: Allocator, shallow_oid: Oid, pack_bytes: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try pktline_mod.writeLine(&aw.writer, "shallow-info");
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const shallow_line = try std.fmt.allocPrint(gpa, "shallow {s}", .{shallow_oid.toHex(&hex_buf)});
    defer gpa.free(shallow_line);
    try pktline_mod.writeLine(&aw.writer, shallow_line);
    try pktline_mod.write(&aw.writer, .delimiter);
    try pktline_mod.writeLine(&aw.writer, "acknowledgments");
    try pktline_mod.writeLine(&aw.writer, "NAK");
    try pktline_mod.writeLine(&aw.writer, "ready");
    try pktline_mod.write(&aw.writer, .delimiter);
    try pktline_mod.writeLine(&aw.writer, "packfile");
    const band1 = try std.mem.concat(gpa, u8, &.{ &[_]u8{1}, pack_bytes });
    defer gpa.free(band1);
    try pktline_mod.write(&aw.writer, .{ .data = band1 });
    try pktline_mod.write(&aw.writer, .flush);
    return aw.toOwnedSlice();
}

/// A section that ends the response right after an acknowledgments
/// section with no `ready` and no packfile: the "negotiate again" shape
/// `fetch.zig`'s own doc comment describes, including the read fault a
/// naive driver hits because the section's own terminating flush is also
/// the response's last byte.
fn buildNegotiateAgainResponse(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try pktline_mod.writeLine(&aw.writer, "acknowledgments");
    try pktline_mod.writeLine(&aw.writer, "NAK");
    try pktline_mod.write(&aw.writer, .flush);
    return aw.toOwnedSlice();
}

/// An acknowledgments section, a delimiter promising more sections follow,
/// then bytes that are not a valid pkt-line at all. Bytes are genuinely
/// present after the delimiter, unlike `buildNegotiateAgainResponse`'s
/// clean run to the end of the reader, so this must fail the round at
/// once rather than being mistaken for "no packfile, negotiate again".
fn buildCorruptSectionResponse(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try pktline_mod.writeLine(&aw.writer, "acknowledgments");
    try pktline_mod.writeLine(&aw.writer, "NAK");
    try pktline_mod.write(&aw.writer, .delimiter);
    try aw.writer.writeAll("not-a-valid-pkt-line-header");
    return aw.toOwnedSlice();
}

fn buildTruncatedPackResponse(gpa: Allocator, ack_oid: Oid, whole_pack: []const u8) ![]u8 {
    // Keep only the 12 byte "PACK" header (magic, version, object count)
    // and drop every entry byte after it, so the pack claims an object
    // that never arrives: `computeOidOffsets` hits a truncated entry
    // header on its very first read. Cutting mid-entry instead risks
    // landing inside a deflate bit position that a File.Reader-backed
    // decompress trips an internal assertion on rather than returning a
    // clean error; the header boundary is deterministic and exercises
    // the same "this pack ends early" outcome.
    const pack_header_len = 12;
    return buildReadyPackResponse(gpa, ack_oid, whole_pack[0..pack_header_len]);
}

const FakeTransport = struct {
    gpa: Allocator,
    ls_refs_response: []const u8,
    /// One response per negotiation round; the last one repeats once
    /// exhausted, so a single entry can script "never converges".
    fetch_responses: []const []const u8,
    /// Extra capabilities to advertise beyond version 2.
    capabilities_extras: []const []const u8 = &.{},
    round: usize = 0,
    ls_reader: std.Io.Reader = undefined,
    fetch_reader: std.Io.Reader = undefined,
    fetch_bodies: std.ArrayList([]u8) = .empty,

    fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *FakeTransport) void {
        for (self.fetch_bodies.items) |b| self.gpa.free(b);
        self.fetch_bodies.deinit(self.gpa);
    }

    const vtable: Transport.VTable = .{
        .capabilities = capabilitiesImpl,
        .command = commandImpl,
        .close = closeImpl,
    };

    fn capabilitiesImpl(ctx: *anyopaque, gpa: Allocator, diag: ?*?Diagnostic) transport_mod.Error!proto.Capabilities {
        _ = diag;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        pktline_mod.writeLine(&aw.writer, "version 2") catch return error.ProtocolError;
        for (self.capabilities_extras) |cap| {
            pktline_mod.writeLine(&aw.writer, cap) catch return error.ProtocolError;
        }
        pktline_mod.write(&aw.writer, .flush) catch return error.ProtocolError;
        const bytes = aw.written();
        var r: std.Io.Reader = .fixed(bytes);
        var pkt_buf: [pktline_mod.Packet.max_data_length]u8 = undefined;
        var remote_message: ?[]u8 = null;
        defer if (remote_message) |m| gpa.free(m);
        return proto.parseCapabilities(gpa, &r, &pkt_buf, &remote_message) catch return error.ProtocolError;
    }

    fn commandImpl(
        ctx: *anyopaque,
        gpa: Allocator,
        cmd: transport_mod.Command,
        out: **std.Io.Reader,
        diag: ?*?Diagnostic,
    ) transport_mod.Error!void {
        _ = diag;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, cmd.name, "ls-refs")) {
            self.ls_reader = .fixed(self.ls_refs_response);
            out.* = &self.ls_reader;
            return;
        }

        const body_copy = gpa.dupe(u8, cmd.body) catch return error.OutOfMemory;
        self.fetch_bodies.append(gpa, body_copy) catch return error.OutOfMemory;

        const idx = @min(self.round, self.fetch_responses.len - 1);
        self.fetch_reader = .fixed(self.fetch_responses[idx]);
        self.round += 1;
        out.* = &self.fetch_reader;
    }

    fn closeImpl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

fn openTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir, committer: ?core_mod.Committer) !Repository {
    try buildMinimalRepo(io, dir);
    const layout = try repo_mod.discover(gpa, io, dir, .{}, null);
    return Repository.open(gpa, io, layout, .{ .committer = committer }, null);
}

const test_committer: core_mod.Committer = .{ .name = "A U Thor", .email = "author@example.com" };

// expected

test "fetchRemote sends a want for every matched ref" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const want_line = try std.fmt.allocPrint(gpa, "want {s}\n", .{new_oid.toHex(&hex_buf)});
    defer gpa.free(want_line);
    try testing.expect(fake.fetch_bodies.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, fake.fetch_bodies.items[0], want_line) != null);
}

test "fetchRemote sends haves from the refs we already have" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const old_payload = try buildCommitPayload(gpa, null, "old");
    defer gpa.free(old_payload);
    const old_oid = try repo.odb.write(.commit, old_payload, null);
    try repo.refs.update("refs/remotes/origin/main", old_oid, null, null, null);

    var old_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const old_hex = old_oid.toHex(&old_hex_buf);
    const new_payload = try buildCommitPayload(gpa, old_hex, "new");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    const have_line = try std.fmt.allocPrint(gpa, "have {s}\n", .{old_hex});
    defer gpa.free(have_line);
    try testing.expect(std.mem.indexOf(u8, fake.fetch_bodies.items[0], have_line) != null);
}

test "fetchRemote stops after the server says ready" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    // One round only: a driver that mishandled "ready" and kept
    // negotiating would have sent a second `fetch` command.
    try testing.expectEqual(@as(usize, 1), fake.fetch_bodies.items.len);
}

test "fetchRemote indexes the received pack and the objects are readable" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try repo.odb.exists(new_oid));
    const read_back = try repo.odb.readAlloc(gpa, new_oid, max_commit_object_len, null);
    defer gpa.free(read_back);
    try testing.expectEqualStrings(new_payload, read_back);
}

test "fetchRemote updates the local refs the refspecs name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
    try testing.expectEqualStrings("refs/remotes/origin/main", result.updated[0].name);
    try testing.expect(std.meta.activeTag(result.updated[0].outcome) == .updated);
    try testing.expect(result.updated[0].outcome.updated.old == null);
    try testing.expect(result.updated[0].outcome.updated.new.eql(new_oid));

    const resolved = try repo.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(new_oid));
}

test "fetchRemote reports bytes and objects received" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), result.objects_received);
    try testing.expectEqual(@as(u64, built.bytes.len), result.bytes_received);
}

test "a depth of one sends a deepen line and records the shallow boundary" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildShallowPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .depth = 1 }, null);
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, fake.fetch_bodies.items[0], "deepen 1\n") != null);

    const shallow_content = try tmp.dir.readFileAlloc(io, "shallow", gpa, .limited(4096));
    defer gpa.free(shallow_content);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, shallow_content, new_oid.toHex(&hex_buf)) != null);
}

// suspicious

test "a non-force refspec refuses a non-fast-forward update" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const old_payload = try buildCommitPayload(gpa, null, "old");
    defer gpa.free(old_payload);
    const old_oid = try repo.odb.write(.commit, old_payload, null);
    try repo.refs.update("refs/remotes/origin/main", old_oid, null, null, null);

    // Unrelated history: no parent line back to `old_oid` at all.
    const new_payload = try buildCommitPayload(gpa, null, "unrelated");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    // Not force: no leading "+".
    var rs = [_]Refspec{try Refspec.parse(gpa, "refs/heads/main:refs/remotes/origin/main")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    // The refspec still matched, so it still gets an entry; the outcome
    // is what says the write was refused.
    try testing.expectEqual(@as(usize, 1), result.updated.len);
    try testing.expect(std.meta.activeTag(result.updated[0].outcome) == .rejected_non_fast_forward);
    const resolved = try repo.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(old_oid));
}

test "a force refspec allows a non-fast-forward update" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const old_payload = try buildCommitPayload(gpa, null, "old");
    defer gpa.free(old_payload);
    const old_oid = try repo.odb.write(.commit, old_payload, null);
    try repo.refs.update("refs/remotes/origin/main", old_oid, null, null, null);

    const new_payload = try buildCommitPayload(gpa, null, "unrelated");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    // Force: leading "+".
    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/main:refs/remotes/origin/main")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
    const resolved = try repo.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(new_oid));
}

test "update_refs false performs the transfer and writes no ref" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .update_refs = false }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), result.updated.len);
    try testing.expect(try repo.odb.exists(new_oid));
    try testing.expectError(error.RefNotFound, repo.refs.resolve("refs/remotes/origin/main", null));
}

test "a pack that ends early is CorruptPack and no ref is updated" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "a rather longer message so the truncation lands mid entry rather than exactly on a boundary");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildTruncatedPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.CorruptPack,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );

    try testing.expectError(error.RefNotFound, repo.refs.resolve("refs/remotes/origin/main", null));
}

test "a ref that vanished between ls-refs and fetch is RefNotFound" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    // The ls-refs listing simply does not carry the ref this literal
    // refspec asks for: the same shape a concurrent delete on the remote
    // would leave behind.
    const other_oid = try Oid.parse(.sha1, "1" ** 40);
    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = other_oid, .name = "refs/heads/other" }});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "refs/heads/gone:refs/remotes/origin/gone")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.RefNotFound,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );
}

test "a server that never says ready fails rather than looping forever" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    const negotiate_again_bytes = try buildNegotiateAgainResponse(gpa);
    defer gpa.free(negotiate_again_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{negotiate_again_bytes},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.ProtocolError,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );
    try testing.expectEqual(max_negotiation_rounds, fake.fetch_bodies.items.len);
}

test "nothing is written when the fetch fails partway" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const old_payload = try buildCommitPayload(gpa, null, "old");
    defer gpa.free(old_payload);
    const old_oid = try repo.odb.write(.commit, old_payload, null);
    try repo.refs.update("refs/remotes/origin/main", old_oid, null, null, null);

    var old_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const old_hex = old_oid.toHex(&old_hex_buf);
    const new_payload = try buildCommitPayload(gpa, old_hex, "a rather longer message so the truncation lands mid entry rather than exactly on a boundary");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildTruncatedPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.CorruptPack,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );

    const resolved = try repo.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(old_oid));
    try testing.expect(!try repo.odb.exists(new_oid));
}

// regression

test "fetchRemote recovers from one negotiate-again round before the server is ready" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const negotiate_again_bytes = try buildNegotiateAgainResponse(gpa);
    defer gpa.free(negotiate_again_bytes);
    const ready_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(ready_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{ negotiate_again_bytes, ready_bytes },
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), fake.fetch_bodies.items.len);
    try testing.expectEqual(@as(usize, 1), result.updated.len);
}

test "a corrupt section after acknowledgments fails at once rather than retrying" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    const corrupt_bytes = try buildCorruptSectionResponse(gpa);
    defer gpa.free(corrupt_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{corrupt_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.ProtocolError,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );
    // One round only: a genuinely corrupt section must not be mistaken
    // for "no packfile, negotiate again" and retried up to the bound.
    try testing.expectEqual(@as(usize, 1), fake.fetch_bodies.items.len);
}

/// A `std.Io` identical to `std.testing.io`, except a rename whose
/// destination ends in ".pack" fails. `receivePack` renames the `.idx`
/// into place first and the `.pack` second, so this forces a failure in
/// the second half after the first half has already landed under its
/// final name.
const PackRenameFails = struct {
    var table: std.Io.VTable = undefined;
    var original: @TypeOf(std.testing.io.vtable.dirRename) = undefined;

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_sub_path: []const u8,
        new_dir: std.Io.Dir,
        new_sub_path: []const u8,
    ) std.Io.Dir.RenameError!void {
        if (std.mem.endsWith(u8, new_sub_path, ".pack")) return error.AccessDenied;
        return original(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }

    fn io() std.Io {
        original = std.testing.io.vtable.dirRename;
        table = std.testing.io.vtable.*;
        table.dirRename = rename;
        return .{ .userdata = std.testing.io.userdata, .vtable = &table };
    }
};

test "a failing second rename leaves neither a pack nor an index behind" {
    const gpa = testing.allocator;
    const io = PackRenameFails.io();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.IoFailed,
        fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null),
    );

    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var it = pack_dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 0), count);
}

test "one ref failing mid loop does not stop the others, and Result reports all three" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload_a = try buildCommitPayload(gpa, null, "a");
    defer gpa.free(payload_a);
    const oid_a = commitOid(payload_a);
    const payload_b = try buildCommitPayload(gpa, null, "b");
    defer gpa.free(payload_b);
    const oid_b = commitOid(payload_b);
    const payload_c = try buildCommitPayload(gpa, null, "c");
    defer gpa.free(payload_c);
    const oid_c = commitOid(payload_c);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{
        .{ .oid = oid_a, .name = "refs/heads/a" },
        .{ .oid = oid_b, .name = "refs/heads/b" },
        .{ .oid = oid_c, .name = "refs/heads/c" },
    });
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .commit, .payload = payload_a } },
        .{ .object = .{ .kind = .commit, .payload = payload_b } },
        .{ .object = .{ .kind = .commit, .payload = payload_c } },
    });
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid_a, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    // Simulate a concurrent writer already mid-update on "b": its lock
    // file is on disk before this fetch ever starts, so `Store.update`
    // for "b" alone reports `error.LockContended`, while "a" and "c" are
    // untouched by it.
    try tmp.dir.createDirPath(io, "refs/remotes/origin");
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/remotes/origin/b.lock", .data = "" });

    var rs = [_]Refspec{
        try Refspec.parse(gpa, "refs/heads/a:refs/remotes/origin/a"),
        try Refspec.parse(gpa, "refs/heads/b:refs/remotes/origin/b"),
        try Refspec.parse(gpa, "refs/heads/c:refs/remotes/origin/c"),
    };
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), result.updated.len);
    for (result.updated) |u| {
        if (std.mem.eql(u8, u.name, "refs/remotes/origin/a")) {
            try testing.expect(std.meta.activeTag(u.outcome) == .updated);
        } else if (std.mem.eql(u8, u.name, "refs/remotes/origin/b")) {
            try testing.expect(std.meta.activeTag(u.outcome) == .failed);
            try testing.expectEqual(Error.LockContended, u.outcome.failed);
        } else if (std.mem.eql(u8, u.name, "refs/remotes/origin/c")) {
            try testing.expect(std.meta.activeTag(u.outcome) == .updated);
        } else {
            try testing.expect(false);
        }
    }

    const resolved_a = try repo.refs.resolve("refs/remotes/origin/a", null);
    try testing.expect(resolved_a.eql(oid_a));
    const resolved_c = try repo.refs.resolve("refs/remotes/origin/c", null);
    try testing.expect(resolved_c.eql(oid_c));
    try testing.expectError(error.RefNotFound, repo.refs.resolve("refs/remotes/origin/b", null));
}

test "fetchRemote never needs a committer to write a ref, only to log one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, null);
    defer repo.deinit();
    try testing.expect(repo.refs.committer == null);

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
}

test "two fetches of the same pack produce one pack file, not two" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);

    // First fetch lands the pack under its checksum name.
    var fake1: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake1.deinit();
    var result1 = try fetchRemote(gpa, io, &repo, fake1.transport(), .{ .refspecs = &rs }, null);
    defer result1.deinit(gpa);

    // Second fetch of the identical content: a wall-clock name would
    // collide or differ by luck alone. A checksum name must land on the
    // very same file, and this fetch must still be reported as success.
    var fake2: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake2.deinit();
    var result2 = try fetchRemote(gpa, io, &repo, fake2.transport(), .{ .refspecs = &rs }, null);
    defer result2.deinit(gpa);

    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var pack_count: usize = 0;
    var idx_count: usize = 0;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) pack_count += 1;
        if (std.mem.endsWith(u8, entry.name, ".idx")) idx_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), pack_count);
    try testing.expectEqual(@as(usize, 1), idx_count);

    try testing.expect(try repo.odb.exists(new_oid));
    const read_back = try repo.odb.readAlloc(gpa, new_oid, max_commit_object_len, null);
    defer gpa.free(read_back);
    try testing.expectEqualStrings(new_payload, read_back);
}

test "the final pack name is the pack's own checksum" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    // The last `format.byteLength()` bytes of a valid pack are its own
    // trailing checksum; `buildTestPack` builds a real one, trailer
    // included. Deriving the expected name straight from those bytes,
    // rather than from any internal of `ziggit-pack`, is what pins the
    // naming scheme to what the pack actually carries.
    const format = Format.sha1;
    const trailer_len = format.byteLength();
    const trailer = built.bytes[built.bytes.len - trailer_len ..];
    const expected_checksum = Oid.fromBytes(format, trailer);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const expected_name = try std.fmt.allocPrint(gpa, "pack-{s}.pack", .{expected_checksum.toHex(&hex_buf)});
    defer gpa.free(expected_name);

    var pack_dir = try tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var found = false;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, expected_name)) found = true;
    }
    try testing.expect(found);
}

// OID refspec support tests

test "an object id source is not sent as an ls-refs prefix" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")};
    defer for (&rs) |*r| r.deinit(gpa);

    _ = fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .update_refs = false }, null) catch {};

    try testing.expect(fake.fetch_bodies.items.len == 0);
}

test "a want by object id succeeds when the server allows tip sha1 in want" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const oid_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oid = Oid.parse(.sha1, oid_hex) catch unreachable;

    const payload = try buildCommitPayload(gpa, null, "test");
    defer gpa.free(payload);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{fetch_bytes},
        .capabilities_extras = &.{"allow-tip-sha1-in-want"},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, oid_hex)};
    defer for (&rs) |*r| r.deinit(gpa);

    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(fake.fetch_bodies.items.len > 0);
    var want_line_buf: [256]u8 = undefined;
    const want_line = try std.fmt.bufPrint(&want_line_buf, "want {s}\n", .{oid_hex});
    try testing.expect(std.mem.indexOf(u8, fake.fetch_bodies.items[0], want_line) != null);
}

test "a want by object id succeeds when the server allows reachable sha1 in want" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const oid_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oid = Oid.parse(.sha1, oid_hex) catch unreachable;

    const payload = try buildCommitPayload(gpa, null, "test");
    defer gpa.free(payload);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{fetch_bytes},
        .capabilities_extras = &.{"allow-reachable-sha1-in-want"},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, oid_hex)};
    defer for (&rs) |*r| r.deinit(gpa);

    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(fake.fetch_bodies.items.len > 0);
    var want_line_buf: [256]u8 = undefined;
    const want_line = try std.fmt.bufPrint(&want_line_buf, "want {s}\n", .{oid_hex});
    try testing.expect(std.mem.indexOf(u8, fake.fetch_bodies.items[0], want_line) != null);
}

test "a want by object id is refused with its own error when the server allows neither" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const oid_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{},
        .capabilities_extras = &.{},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, oid_hex)};
    defer for (&rs) |*r| r.deinit(gpa);

    try testing.expectError(error.ServerRefusesOidWant, fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null));
}

test "the refusal names the capability rather than reporting RefNotFound" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const oid_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{},
        .capabilities_extras = &.{},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, oid_hex)};
    defer for (&rs) |*r| r.deinit(gpa);

    const result = fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    try testing.expectError(error.ServerRefusesOidWant, result);
}

test "firstFailure returns null when every ref landed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(result.firstFailure() == null);
}

test "firstFailure returns the failed ref when one failed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload_a = try buildCommitPayload(gpa, null, "a");
    defer gpa.free(payload_a);
    const oid_a = commitOid(payload_a);
    const payload_b = try buildCommitPayload(gpa, null, "b");
    defer gpa.free(payload_b);
    const oid_b = commitOid(payload_b);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{
        .{ .oid = oid_a, .name = "refs/heads/a" },
        .{ .oid = oid_b, .name = "refs/heads/b" },
    });
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .commit, .payload = payload_a } },
        .{ .object = .{ .kind = .commit, .payload = payload_b } },
    });
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid_a, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    try tmp.dir.createDirPath(io, "refs/remotes/origin");
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/remotes/origin/b.lock", .data = "" });

    var rs = [_]Refspec{
        try Refspec.parse(gpa, "refs/heads/a:refs/remotes/origin/a"),
        try Refspec.parse(gpa, "refs/heads/b:refs/remotes/origin/b"),
    };
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    const first_failure = result.firstFailure();
    try testing.expect(first_failure != null);
    try testing.expectEqualStrings("refs/remotes/origin/b", first_failure.?.name);
}

test "a forced refspec overwrites a symbolic ref" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "HEAD" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    try tmp.dir.createDirPath(io, "refs/remotes/origin");
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/remotes/origin/HEAD", .data = "ref: refs/heads/main\n" });

    var rs = [_]Refspec{try Refspec.parse(gpa, "+HEAD:refs/remotes/origin/HEAD")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
    try testing.expect(std.meta.activeTag(result.updated[0].outcome) == .updated);

    const resolved = try repo.refs.resolve("refs/remotes/origin/HEAD", null);
    try testing.expect(resolved.eql(new_oid));
}

test "a forced overwrite of a symbolic ref goes through the ref lock" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "HEAD" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    try tmp.dir.createDirPath(io, "refs/remotes/origin");
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/remotes/origin/HEAD", .data = "ref: refs/heads/main\n" });

    // Simulate a concurrent writer already mid-update on this same ref:
    // its lock file is on disk before this fetch ever starts. A direct
    // file write ignores this entirely and clobbers the ref out from
    // under it; going through the ref lock must instead refuse with
    // LockContended, exactly as any other writer of this ref would.
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/remotes/origin/HEAD.lock", .data = "leftover" });

    var rs = [_]Refspec{try Refspec.parse(gpa, "+HEAD:refs/remotes/origin/HEAD")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
    try testing.expect(std.meta.activeTag(result.updated[0].outcome) == .failed);
    try testing.expectEqual(Error.LockContended, result.updated[0].outcome.failed);

    // The symbolic ref is untouched, and the lock file this test planted
    // is neither broken nor removed.
    const ref_content = try tmp.dir.readFileAlloc(io, "refs/remotes/origin/HEAD", gpa, .limited(256));
    defer gpa.free(ref_content);
    try testing.expectEqualStrings("ref: refs/heads/main\n", ref_content);

    const lock_content = try tmp.dir.readFileAlloc(io, "refs/remotes/origin/HEAD.lock", gpa, .limited(256));
    defer gpa.free(lock_content);
    try testing.expectEqualStrings("leftover", lock_content);
}

test "a refspec matching nothing is reported through diag" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);

    var diag: ?Diagnostic = null;
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs }, &diag);
    defer result.deinit(gpa);
    defer if (diag) |*d| d.deinit(gpa);

    try testing.expect(diag != null);
}

test "a fetch writes FETCH_HEAD" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const new_payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(new_payload);
    const new_oid = commitOid(new_payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = new_oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = new_payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, new_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "https://example.com/repo.git" }, null);
    defer result.deinit(gpa);

    const fetch_head_content = try tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024));
    defer gpa.free(fetch_head_content);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const oid_hex = new_oid.toHex(&hex_buf);
    const expected_line = try std.fmt.allocPrint(gpa, "{s}\t\tbranch 'main' of https://example.com/repo.git\n", .{oid_hex});
    defer gpa.free(expected_line);

    try testing.expectEqualStrings(expected_line, fetch_head_content);
}

test "FETCH_HEAD names a fetched object id with no kind word" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const oid_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    // Build a minimal pack with a single commit object to satisfy the fetch
    const payload = try buildCommitPayload(gpa, null, "object-fetch");
    defer gpa.free(payload);
    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);

    // Create a dummy oid from the payload for the ACK line
    const dummy_oid = commitOid(payload);
    const fetch_bytes = try buildReadyPackResponse(gpa, dummy_oid, built.bytes);
    defer gpa.free(fetch_bytes);

    // For object id fetches, ls_refs returns empty (no refs advertised)
    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{});
    defer gpa.free(ls_refs_bytes);

    var fake: FakeTransport = .{
        .gpa = gpa,
        .ls_refs_response = ls_refs_bytes,
        .fetch_responses = &.{fetch_bytes},
        .capabilities_extras = &.{"allow-tip-sha1-in-want"},
    };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:refs/remotes/origin/pinned")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "/local/path" }, null);
    defer result.deinit(gpa);

    const fetch_head_content = try tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024));
    defer gpa.free(fetch_head_content);

    const expected_line = try std.fmt.allocPrint(gpa, "{s}\t\t'{s}' of /local/path\n", .{ oid_hex, oid_hex });
    defer gpa.free(expected_line);

    try testing.expectEqualStrings(expected_line, fetch_head_content);
}

test "FETCH_HEAD names a fetched HEAD with no kind word and no name" {
    // The refspec the Nix evaluator uses. Git prints the url by itself
    // here, with no `branch`, no quoted name and no `of`.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "head");
    defer gpa.free(payload);
    const oid = commitOid(payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = oid, .name = "HEAD" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+HEAD:refs/remotes/origin/HEAD")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "https://example.com/repo.git" }, null);
    defer result.deinit(gpa);

    const content = try tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024));
    defer gpa.free(content);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const expected = try std.fmt.allocPrint(gpa, "{s}\t\thttps://example.com/repo.git\n", .{oid.toHex(&hex_buf)});
    defer gpa.free(expected);

    try testing.expectEqualStrings(expected, content);
}

test "FETCH_HEAD lists a ref that was already up to date" {
    // FETCH_HEAD records what the remote had, not what changed here. A
    // reader that skipped an unchanged ref would write an empty file for
    // the ordinary case of fetching twice.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "settled");
    defer gpa.free(payload);
    const oid = commitOid(payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);

    // First fetch: the ref moves.
    {
        const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
        defer gpa.free(fetch_bytes);
        var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
        defer fake.deinit();
        var first = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "origin" }, null);
        defer first.deinit(gpa);
    }

    try tmp.dir.deleteFile(io, "FETCH_HEAD");

    // Second fetch: nothing moves, and the line must still be there.
    const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
    defer gpa.free(fetch_bytes);
    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();
    var second = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "origin" }, null);
    defer second.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), second.updated.len);
    try testing.expectEqual(RefOutcome.up_to_date, std.meta.activeTag(second.updated[0].outcome));

    const content = try tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024));
    defer gpa.free(content);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const expected = try std.fmt.allocPrint(gpa, "{s}\t\tbranch 'main' of origin\n", .{oid.toHex(&hex_buf)});
    defer gpa.free(expected);

    try testing.expectEqualStrings(expected, content);
}

test "a fetch that updates no refs writes no FETCH_HEAD" {
    // `update_refs = false` is a dry run, and git writes no FETCH_HEAD for
    // a dry run.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "dry");
    defer gpa.free(payload);
    const oid = commitOid(payload);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{.{ .oid = oid, .name = "refs/heads/main" }});
    defer gpa.free(ls_refs_bytes);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload } }});
    defer built.deinit(gpa);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid, built.bytes);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{
        .refspecs = &rs,
        .remote_url = "origin",
        .update_refs = false,
    }, null);
    defer result.deinit(gpa);

    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024)));
}

test "FETCH_HEAD lists one line per updated ref" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir, test_committer);
    defer repo.deinit();

    const payload1 = try buildCommitPayload(gpa, null, "first");
    defer gpa.free(payload1);
    const oid1 = commitOid(payload1);

    const payload2 = try buildCommitPayload(gpa, null, "second");
    defer gpa.free(payload2);
    const oid2 = commitOid(payload2);

    const ls_refs_bytes = try buildLsRefsResponse(gpa, &.{
        .{ .oid = oid1, .name = "refs/heads/main" },
        .{ .oid = oid2, .name = "refs/heads/dev" },
    });
    defer gpa.free(ls_refs_bytes);

    var built1 = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload1 } }});
    defer built1.deinit(gpa);
    var built2 = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{.{ .object = .{ .kind = .commit, .payload = payload2 } }});
    defer built2.deinit(gpa);
    const combined_pack = try std.mem.concat(gpa, u8, &.{ built1.bytes, built2.bytes[12..] });
    defer gpa.free(combined_pack);
    const fetch_bytes = try buildReadyPackResponse(gpa, oid1, combined_pack);
    defer gpa.free(fetch_bytes);

    var fake: FakeTransport = .{ .gpa = gpa, .ls_refs_response = ls_refs_bytes, .fetch_responses = &.{fetch_bytes} };
    defer fake.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchRemote(gpa, io, &repo, fake.transport(), .{ .refspecs = &rs, .remote_url = "origin" }, null);
    defer result.deinit(gpa);

    const fetch_head_content = try tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(1024));
    defer gpa.free(fetch_head_content);

    var hex_buf1: [Oid.max_formatted_length]u8 = undefined;
    var hex_buf2: [Oid.max_formatted_length]u8 = undefined;
    const line1 = try std.fmt.allocPrint(gpa, "{s}\t\tbranch 'main' of origin\n", .{oid1.toHex(&hex_buf1)});
    defer gpa.free(line1);
    const line2 = try std.fmt.allocPrint(gpa, "{s}\t\tbranch 'dev' of origin\n", .{oid2.toHex(&hex_buf2)});
    defer gpa.free(line2);
    const expected = try std.mem.concat(gpa, u8, &.{ line1, line2 });
    defer gpa.free(expected);

    try testing.expectEqualStrings(expected, fetch_head_content);
}
