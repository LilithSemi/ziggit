//! The repository: the object database, the ref store, and config, tied
//! together on top of a `Layout` that discovery already built.
//!
//! `open` is where the seam `discover` deliberately leaves clean gets
//! closed: only here does this module read `core.repositoryformatversion`
//! and `extensions.objectFormat` and pick the hash format everything below
//! is built with.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const config_mod = @import("ziggit-config");
const Config = config_mod.Config;
const Level = config_mod.Level;
const Writer = config_mod.Writer;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const refs_mod = @import("ziggit-refs");
const Store = refs_mod.Store;
const Committer = core_mod.Committer;

const layout_mod = @import("Layout.zig");
const Layout = layout_mod.Layout;

pub const Error = error{
    NotARepository,
    UnsupportedRepositoryFormat,
    UnsupportedExtension,
    CorruptGitFile,
    IoFailed,
    AlreadyARepository,
    AmbiguousKey,
} || Config.Error || Odb.Error || Store.Error;

/// Extension names, under `[extensions]`, that this build understands.
/// `hasUnknownExtension` refuses anything else when
/// `core.repositoryformatversion` is 1, rather than silently ignoring an
/// extension it does not know how to honour.
const known_extensions = [_][]const u8{"objectformat"};

pub const Repository = struct {
    /// Owned. Freed by `deinit`, which calls `layout.deinit`.
    layout: Layout,
    /// Owned. Freed by `deinit`, which calls `config.deinit`.
    config: Config,
    /// Owned. Freed by `deinit`, which calls `odb.deinit`.
    odb: Odb,
    /// Owned. Freed by `deinit`, which calls `refs.deinit`.
    refs: Store,
    /// A plain value, not a resource: nothing in `deinit` frees this.
    format: Format,
    /// Kept only so `deinit` can release what `open` opened without the
    /// caller passing `gpa` and `io` back in a second time.
    gpa: Allocator,
    io: std.Io,
    /// `common_dir/objects`, opened by `open` for `Odb.init`. `Odb` never
    /// closes the directory it is handed (see `Odb.Options.object_directory`'s
    /// doc comment); this is the one place that directory is remembered so
    /// `deinit` can close it exactly once, regardless of whether `options.odb`
    /// redirected `Odb`'s own writes elsewhere.
    objects_dir: std.Io.Dir,

    pub const InitOptions = struct {
        /// The branch name to write to HEAD. Defaults to "master", which is
        /// git's own built-in default. This module never reads global config
        /// for `init.defaultBranch`: a caller that wants a person's configured
        /// default reads it and passes it here.
        initial_branch: []const u8 = "master",
        /// Create a bare repository (no working tree). Defaults to false.
        bare: bool = false,
    };

    pub const OpenOptions = struct {
        config: Config.Options = .{},
        odb: Odb.Options = .{},
        /// Absolute path to the system-wide config file (git's own
        /// `$(prefix)/etc/gitconfig`), loaded at `.system` level when
        /// `config.use_system` is true. Null skips the system level even
        /// when `use_system` is true: this library never reads an
        /// environment variable or bakes in a build prefix to guess where
        /// that file lives, so the caller supplies it.
        system_config_path: ?[]const u8 = null,
        /// Absolute path to the user's global config file (git's own
        /// `$HOME/.gitconfig` or `$XDG_CONFIG_HOME/git/config`), loaded at
        /// `.global` level when `config.use_global` is true. Same rule as
        /// `system_config_path`: null skips it, and nothing here reads an
        /// environment variable to guess it.
        global_config_path: ?[]const u8 = null,
        /// Who a reflog entry `refs` writes is attributed to. Null means
        /// `open` looks for `user.name` and `user.email` in the config it
        /// already loaded, the way git itself does; when neither key is
        /// set either, `refs` ends up with no committer at all, and a
        /// later write that asks for a reflog is refused, matching git
        /// refusing to commit with no `user.name` configured. A
        /// committer built this way always records UTC (`tz_offset_minutes`
        /// of 0): this library discovers no local offset on its own, so
        /// only a caller-supplied `Committer` can carry a real one.
        committer: ?Committer = null,
    };

    /// Reads `core.repositoryformatversion` and `extensions.objectFormat`
    /// from `layout.common_dir`'s own `config` file, then builds the odb
    /// and the ref store on `layout.common_dir`. Refuses a format version
    /// or an extension this build does not understand, rather than
    /// guessing what either one means.
    ///
    /// Config is loaded in precedence order, system first, then global,
    /// then local: a later level's `addFile` call is what makes it win,
    /// not call order (`Config.Level`'s own ordinal decides), but loading
    /// in that order is what an `includeIf` needs, since it must see
    /// `config.gitdir` and `config.branch` already set, which happens
    /// once, below, before any level is loaded.
    ///
    /// On error, `layout` is left untouched: it stays caller-owned, and
    /// the caller must still call `layout.deinit`. Ownership of `layout`
    /// passes to the returned `Repository` only on success.
    pub fn open(gpa: Allocator, io: std.Io, layout: Layout, options: OpenOptions, diag: ?*?Diagnostic) Error!Repository {
        var config = Config.init(gpa);
        config.options = options.config;
        errdefer config.deinit();

        // `includeIf` needs both of these before the first file is read:
        // a `gitdir:` or `onbranch:` condition inside the system or global
        // file must be able to match against this very repository.
        var gitdir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (layout.git_dir.realPath(io, &gitdir_buf)) |len| {
            config.gitdir = gitdir_buf[0..len];
        } else |_| {
            // No real path, no `gitdir:` match: the same outcome as if
            // `config.gitdir` had never been set.
        }
        var head_buf: [max_head_peek_len]u8 = undefined;
        config.branch = peekBranchName(io, layout.common_dir, &head_buf);

        if (options.config.use_system) {
            if (options.system_config_path) |p| try addAbsoluteConfigFile(&config, io, .system, layout.common_dir, p, diag);
        }
        if (options.config.use_global) {
            if (options.global_config_path) |p| try addAbsoluteConfigFile(&config, io, .global, layout.common_dir, p, diag);
        }
        try config.addFile(io, .local, layout.common_dir, "config", diag);

        const version = config.getInt("core.repositoryformatversion") orelse 0;
        if (version < 0 or version > @as(i64, options.config.max_format_version)) {
            return error.UnsupportedRepositoryFormat;
        }
        if (version == 1 and hasUnknownExtension(&config)) {
            return error.UnsupportedExtension;
        }

        const format: Format = blk: {
            const raw = config.getString("extensions.objectFormat") orelse break :blk .sha1;
            break :blk Format.fromName(raw) orelse return error.UnsupportedExtension;
        };

        var objects_dir = layout.common_dir.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.NotARepository,
            else => return error.IoFailed,
        };
        errdefer objects_dir.close(io);

        var odb = try Odb.init(gpa, io, objects_dir, format, options.odb);
        errdefer odb.deinit();

        const committer = options.committer orelse committerFromConfig(&config);
        const refs = Store.init(gpa, io, layout.common_dir, format, committer);

        return .{
            .layout = layout,
            .config = config,
            .odb = odb,
            .refs = refs,
            .format = format,
            .gpa = gpa,
            .io = io,
            .objects_dir = objects_dir,
        };
    }

    /// Create a new repository in the given directory. Fails if a repository
    /// already exists there. Does not read global config for initial branch.
    pub fn init(gpa: Allocator, io: std.Io, dir: std.Io.Dir, options: InitOptions) Error!void {
        const head_stat = dir.statFile(io, "HEAD", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.IoFailed,
        };
        if (head_stat != null) {
            return error.AlreadyARepository;
        }

        const git_stat = dir.statFile(io, ".git", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.IoFailed,
        };
        if (git_stat != null) {
            return error.AlreadyARepository;
        }

        if (options.bare) {
            try initBareRepository(gpa, io, dir, options.initial_branch);
        } else {
            try initStandardRepository(gpa, io, dir, options.initial_branch);
        }
    }

    fn initStandardRepository(gpa: Allocator, io: std.Io, work_tree: std.Io.Dir, initial_branch: []const u8) Error!void {
        work_tree.createDir(io, ".git", .default_dir) catch return error.IoFailed;
        var git_dir = work_tree.openDir(io, ".git", .{}) catch return error.IoFailed;
        defer git_dir.close(io);

        git_dir.createDirPath(io, "objects/pack") catch return error.IoFailed;
        git_dir.createDirPath(io, "objects/info") catch return error.IoFailed;
        git_dir.createDirPath(io, "refs/heads") catch return error.IoFailed;
        git_dir.createDirPath(io, "refs/tags") catch return error.IoFailed;

        var head_content: [512]u8 = undefined;
        const head_len = std.fmt.bufPrint(&head_content, "ref: refs/heads/{s}\n", .{initial_branch}) catch return error.IoFailed;
        git_dir.writeFile(io, .{
            .sub_path = "HEAD",
            .data = head_content[0..head_len.len],
        }) catch return error.IoFailed;

        const filemode = try probeFilemode(io, git_dir);

        const config_content = try buildConfigContent(
            gpa,
            filemode,
            false,
        );
        defer gpa.free(config_content);

        git_dir.writeFile(io, .{
            .sub_path = "config",
            .data = config_content,
        }) catch return error.IoFailed;
    }

    fn initBareRepository(gpa: Allocator, io: std.Io, dir: std.Io.Dir, initial_branch: []const u8) Error!void {
        dir.createDirPath(io, "objects/pack") catch return error.IoFailed;
        dir.createDirPath(io, "objects/info") catch return error.IoFailed;
        dir.createDirPath(io, "refs/heads") catch return error.IoFailed;
        dir.createDirPath(io, "refs/tags") catch return error.IoFailed;

        var head_content: [512]u8 = undefined;
        const head_len = std.fmt.bufPrint(&head_content, "ref: refs/heads/{s}\n", .{initial_branch}) catch return error.IoFailed;
        dir.writeFile(io, .{
            .sub_path = "HEAD",
            .data = head_content[0..head_len.len],
        }) catch return error.IoFailed;

        const filemode = try probeFilemode(io, dir);

        const config_content = try buildConfigContent(
            gpa,
            filemode,
            true,
        );
        defer gpa.free(config_content);

        dir.writeFile(io, .{
            .sub_path = "config",
            .data = config_content,
        }) catch return error.IoFailed;
    }

    /// Reports whether this filesystem keeps a file's executable bit.
    ///
    /// Probed rather than assumed. A `filemode` that says true on a
    /// filesystem that drops the bit makes git report a mode change on
    /// every file, every time, and nothing in the repository is wrong.
    fn probeFilemode(io: std.Io, dir: std.Io.Dir) Error!bool {
        const probe_name = ".tmp_filemode_probe";
        defer dir.deleteFile(io, probe_name) catch |err| switch (err) {
            // The probe file is already gone, which is the outcome this
            // cleanup exists for. Not a fault.
            error.FileNotFound => {},
            // Any other failure leaves one empty file behind in a
            // directory this call just created. That is untidy and is not
            // a reason to fail a repository that is otherwise complete.
            else => {},
        };

        dir.writeFile(io, .{
            .sub_path = probe_name,
            .data = "",
        }) catch return error.IoFailed;

        var probe_file = dir.openFile(io, probe_name, .{}) catch return error.IoFailed;
        defer probe_file.close(io);

        probe_file.setPermissions(io, @enumFromInt(0o755)) catch return error.IoFailed;

        const stat = probe_file.stat(io) catch return error.IoFailed;
        const mode = @intFromEnum(stat.permissions);
        const has_exec = (mode & 0o111) != 0;

        return has_exec;
    }

    fn buildConfigContent(gpa: Allocator, filemode: bool, bare: bool) Allocator.Error![]const u8 {
        const entries = [_]Writer.Entry{
            .{
                .section = "core",
                .subsection = null,
                .key = "repositoryformatversion",
                .value = "0",
                .is_bare = false,
            },
            .{
                .section = "core",
                .subsection = null,
                .key = "filemode",
                .value = if (filemode) "true" else "false",
                .is_bare = false,
            },
            .{
                .section = "core",
                .subsection = null,
                .key = "bare",
                .value = if (bare) "true" else "false",
                .is_bare = false,
            },
            .{
                .section = "core",
                .subsection = null,
                .key = "logallrefupdates",
                .value = "true",
                .is_bare = false,
            },
        };

        return try Writer.renderEntries(gpa, entries[0..]);
    }

    pub fn deinit(r: *Repository) void {
        r.refs.deinit();
        r.odb.deinit();
        r.objects_dir.close(r.io);
        r.config.deinit();
        r.layout.deinit(r.io);
        r.* = undefined;
    }

    /// Resolves HEAD. `error.RefNotFound` when HEAD points at a branch
    /// with no commit yet, which is a fresh repository, not a fault.
    pub fn head(r: *Repository, diag: ?*?Diagnostic) Error!Oid {
        return r.refs.resolve("HEAD", diag);
    }

    /// The branch name HEAD points at, or null when HEAD is detached.
    /// Caller frees the returned slice with the allocator `open` was
    /// given.
    pub fn headBranch(r: *Repository, diag: ?*?Diagnostic) Error!?[]const u8 {
        var ref = try r.refs.lookup("HEAD", diag);
        defer ref.deinit(r.gpa);
        return switch (ref.target) {
            .oid => null,
            .symbolic => |sym| blk: {
                const prefix = "refs/heads/";
                const name = if (std.mem.startsWith(u8, sym, prefix)) sym[prefix.len..] else sym;
                break :blk try r.gpa.dupe(u8, name);
            },
        };
    }

    /// Whether this repository is shallow (has a boundary commit where
    /// parents are cut off). A repository is shallow when the shallow file
    /// exists and names at least one commit. An absent file or an empty file
    /// both mean the repository is not shallow.
    pub fn isShallow(r: *Repository, diag: ?*?Diagnostic) Error!bool {
        var boundary = try readShallowBoundary(r.gpa, r.io, r.layout.common_dir, r.format, diag);
        defer boundary.deinit(r.gpa);
        return boundary.count() > 0;
    }

    /// Create a remote with the given name, url, and fetchspec. Writes the
    /// config file back to disk. A remote named origin with url
    /// https://github.com/example/repo and fetchspec
    /// +refs/heads/*:refs/remotes/origin/* sets remote.origin.url and
    /// remote.origin.fetch in the config.
    pub fn createRemote(
        r: *Repository,
        name: []const u8,
        url: []const u8,
        fetchspec: []const u8,
    ) Error!void {
        const old_config = r.layout.common_dir.readFileAlloc(
            r.io,
            "config",
            r.gpa,
            .limited(1 << 20),
        ) catch |err| switch (err) {
            else => return error.IoFailed,
        };
        defer r.gpa.free(old_config);

        const new_config_1 = Writer.setKeyInFile(
            r.gpa,
            old_config,
            "remote",
            name,
            "url",
            url,
        ) catch |err| switch (err) {
            error.AmbiguousKey => return error.AmbiguousKey,
            else => return err,
        };
        defer r.gpa.free(new_config_1);

        const new_config_2 = Writer.setKeyInFile(
            r.gpa,
            new_config_1,
            "remote",
            name,
            "fetch",
            fetchspec,
        ) catch |err| switch (err) {
            error.AmbiguousKey => return error.AmbiguousKey,
            else => return err,
        };
        defer r.gpa.free(new_config_2);

        // Written to `config.lock` and renamed over `config`, which is what
        // git does with the same file name. A plain write over the live
        // config truncates it first, so a crash or a short write in the
        // middle leaves a repository whose config no longer parses, and
        // `open` reads that file for `core.repositoryformatversion`. The
        // rename is the only step that can be seen by a reader, and it
        // either happened or it did not.
        r.layout.common_dir.writeFile(r.io, .{
            .sub_path = "config.lock",
            .data = new_config_2,
        }) catch return error.IoFailed;
        r.layout.common_dir.rename("config.lock", r.layout.common_dir, "config", r.io) catch {
            // Leave no lock file behind for a write that never landed.
            // Git reports a repository as locked while that file is there,
            // so a failed rename must not also strand it. A cleanup that
            // fails changes nothing about the rename failure being the
            // fault worth reporting.
            r.layout.common_dir.deleteFile(r.io, "config.lock") catch |cleanup_err| switch (cleanup_err) {
                error.FileNotFound => {},
                else => {},
            };
            return error.IoFailed;
        };
    }
};

/// Longest `HEAD` file `peekBranchName` reads. A defensive ceiling, not a
/// spec limit: a real one is a handful of bytes.
const max_head_peek_len: usize = 4096;

/// Allocation budget for reading the entire shallow file.
/// A typical shallow file lists a handful of commits; this is a defensive
/// ceiling against a hostile one, not a spec limit.
const max_shallow_file_len: usize = 1 << 20;

/// Reads the shallow boundary file from a repository's common directory.
/// Returns the set of ids it names, or an empty set when the file is
/// absent, which is what an ordinary full repository looks like. Every
/// line must be a hex id of `format`: a repository has one hash format, so
/// a line of a different length is corruption rather than a second format
/// in the same file. Caller owns the returned set and must free it.
/// `diag` receives a `corrupt_gitfile` report naming the shallow file when
/// it cannot be read or parsed. Without it a caller gets a bare
/// `CorruptObject` and no way to learn which file was wrong, which is the
/// diagnostic hole already recorded against `Index.open`.
pub fn readShallowBoundary(
    gpa: Allocator,
    io: std.Io,
    common_dir: std.Io.Dir,
    format: Format,
    diag: ?*?Diagnostic,
) (error{CorruptObject} || Allocator.Error)!std.AutoHashMapUnmanaged(Oid, void) {
    var boundary: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    errdefer boundary.deinit(gpa);

    const bytes = common_dir.readFileAlloc(io, "shallow", gpa, .limited(max_shallow_file_len)) catch |err| switch (err) {
        error.FileNotFound => return boundary,
        else => {
            reportCorruptShallow(diag, gpa, "shallow file could not be read");
            return error.CorruptObject;
        },
    };
    defer gpa.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const oid = Oid.parse(format, line) catch {
            reportCorruptShallow(diag, gpa, "shallow file line is not an id of this repository's hash format");
            return error.CorruptObject;
        };
        try boundary.put(gpa, oid, {});
    }

    return boundary;
}

fn reportCorruptShallow(diag: ?*?Diagnostic, gpa: Allocator, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const owned_path = gpa.dupe(u8, "shallow") catch null;
    const owned_detail = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_gitfile, .path = owned_path, .detail = owned_detail });
}

/// The branch name `common_dir`'s own `HEAD` names, when it holds a
/// symbolic ref under `refs/heads/`; null for a detached HEAD, an unborn
/// repository with no `HEAD` file yet, or anything else. Reads the file
/// directly rather than through `ziggit-refs`, since this runs before
/// `format` is chosen: a raw object id under `HEAD` needs no format to
/// say "this is not a branch", the only thing this function reports.
fn peekBranchName(io: std.Io, common_dir: std.Io.Dir, buf: *[max_head_peek_len]u8) ?[]const u8 {
    const content = common_dir.readFile(io, "HEAD", buf) catch return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    return trimmed[prefix.len..];
}

/// Loads the config file at the absolute path `full_path` into `config`
/// at `level`. `Config.addFile` reads a path relative to a directory it is
/// handed, not an absolute one, so this splits `full_path` at its last
/// "/" and opens the parent directory itself; a relative `full_path`
/// (never produced by a real system or global config path, but not
/// rejected either) resolves its parent against `base` instead. A parent
/// directory that does not exist is treated the same as a missing file:
/// nothing on disk at this level is normal, not a fault.
fn addAbsoluteConfigFile(
    config: *Config,
    io: std.Io,
    level: Level,
    base: std.Io.Dir,
    full_path: []const u8,
    diag: ?*?Diagnostic,
) Error!void {
    const slash = std.mem.lastIndexOfScalar(u8, full_path, '/');
    const parent = if (slash) |s| full_path[0..s] else ".";
    const name = if (slash) |s| full_path[s + 1 ..] else full_path;

    var dir = core_mod.openDirRelative(io, base, parent) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return error.IoFailed,
    };
    defer dir.close(io);
    try config.addFile(io, level, dir, name, diag);
}

/// Builds a `Committer` from `user.name` and `user.email` in `config`,
/// the way git itself attributes a commit with no `--author` given.
/// Null when either key is absent: a half identity is not one this
/// library will use to attribute a write. The `name` and `email` fields
/// borrow directly from `config`'s own storage, so the returned
/// `Committer` is only valid for as long as `config` is.
fn committerFromConfig(config: *Config) ?Committer {
    const name = config.getString("user.name") orelse return null;
    const email = config.getString("user.email") orelse return null;
    return .{ .name = name, .email = email };
}

/// True when `config` carries an `extensions.*` key this build does not
/// recognize. Walks `Config.sectionKeyIterator`, `ziggit-config`'s public
/// enumeration API, instead of decoding `Config`'s internal key encoding
/// directly, so a future change to that encoding cannot silently break
/// this check.
fn hasUnknownExtension(config: *Config) bool {
    var it = config.sectionKeyIterator("extensions", null);
    while (it.next()) |name| {
        var known = false;
        for (known_extensions) |k| {
            if (std.mem.eql(u8, name, k)) {
                known = true;
                break;
            }
        }
        if (!known) return true;
    }
    return false;
}

// Test helpers shared by every test below: a minimal, real repository
// directory this task builds by hand, with no `.git` wrapper (a bare
// shape is the simplest fixture, and none of these tests care about the
// bare/non-bare distinction except the one that names it).

fn buildMinimalRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "objects/pack");
    try dir.createDirPath(io, "refs/heads");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
}

const discover_mod = @import("discover.zig");
const discover = discover_mod.discover;

// expected

test "open reads extensions.objectFormat sha256 and sets the format" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectFormat = sha256\n",
    });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectEqual(Format.sha256, repo.format);
}

test "open defaults to sha1 when extensions.objectFormat is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectEqual(Format.sha1, repo.format);
}

test "head resolves a symbolic HEAD to a commit id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "3333333333333333333333333333333333333333\n" });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    const oid = try repo.head(null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("3333333333333333333333333333333333333333", oid.toHex(&buf));
}

test "headBranch returns the branch name for an attached HEAD" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    const name = try repo.headBranch(null);
    defer if (name) |n| gpa.free(n);
    try std.testing.expectEqualStrings("main", name.?);
}

test "headBranch returns null for a detached HEAD" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "4444444444444444444444444444444444444444\n" });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    const name = try repo.headBranch(null);
    try std.testing.expect(name == null);
}

// suspicious

test "open refuses core.repositoryformatversion 2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\n\trepositoryformatversion = 2\n" });

    var layout = try discover(gpa, io, tmp.dir, .{}, null);
    defer layout.deinit(io);
    try std.testing.expectError(error.UnsupportedRepositoryFormat, Repository.open(gpa, io, layout, .{}, null));
}

test "open refuses an unknown entry under extensions when the format version is 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tpreciousObjects = true\n",
    });

    var layout = try discover(gpa, io, tmp.dir, .{}, null);
    defer layout.deinit(io);
    try std.testing.expectError(error.UnsupportedExtension, Repository.open(gpa, io, layout, .{}, null));
}

test "open on a bare repository has a null work_tree and is_bare true" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    try std.testing.expect(layout.is_bare);
    try std.testing.expect(layout.work_tree == null);

    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();
    try std.testing.expect(repo.layout.is_bare);
    try std.testing.expect(repo.layout.work_tree == null);
}

test "head on a repository with an unborn HEAD is RefNotFound, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectError(error.RefNotFound, repo.head(null));
}

// A caller-supplied system or global config path is an absolute path to a
// file outside the repository under test, so these live in their own
// temporary directory rather than the repo's.

test "open loads a system config file when system_config_path is given" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    var etc_tmp = std.testing.tmpDir(.{});
    defer etc_tmp.cleanup();
    try etc_tmp.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = "[core]\n\teditor = fromsystem\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try etc_tmp.dir.realPath(io, &path_buf);
    const sys_path = try std.fmt.allocPrint(gpa, "{s}/gitconfig", .{path_buf[0..len]});
    defer gpa.free(sys_path);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{ .system_config_path = sys_path }, null);
    defer repo.deinit();

    try std.testing.expectEqualStrings("fromsystem", repo.config.getString("core.editor").?);
}

test "local config still wins over system and global" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "[core]\n\teditor = fromlocal\n" });

    var sys_tmp = std.testing.tmpDir(.{});
    defer sys_tmp.cleanup();
    try sys_tmp.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = "[core]\n\teditor = fromsystem\n" });
    var global_tmp = std.testing.tmpDir(.{});
    defer global_tmp.cleanup();
    try global_tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[core]\n\teditor = fromglobal\n" });

    var sys_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sys_len = try sys_tmp.dir.realPath(io, &sys_buf);
    const sys_path = try std.fmt.allocPrint(gpa, "{s}/gitconfig", .{sys_buf[0..sys_len]});
    defer gpa.free(sys_path);
    var global_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const global_len = try global_tmp.dir.realPath(io, &global_buf);
    const global_path = try std.fmt.allocPrint(gpa, "{s}/.gitconfig", .{global_buf[0..global_len]});
    defer gpa.free(global_path);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{
        .system_config_path = sys_path,
        .global_config_path = global_path,
    }, null);
    defer repo.deinit();

    try std.testing.expectEqualStrings("fromlocal", repo.config.getString("core.editor").?);
}

test "system_config_path is ignored when use_system is false" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    var sys_tmp = std.testing.tmpDir(.{});
    defer sys_tmp.cleanup();
    try sys_tmp.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = "[core]\n\teditor = fromsystem\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try sys_tmp.dir.realPath(io, &path_buf);
    const sys_path = try std.fmt.allocPrint(gpa, "{s}/gitconfig", .{path_buf[0..len]});
    defer gpa.free(sys_path);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{
        .config = .{ .use_system = false },
        .system_config_path = sys_path,
    }, null);
    defer repo.deinit();

    try std.testing.expect(repo.config.getString("core.editor") == null);
}

test "config.gitdir is set to the repository's own git dir before includeIf resolves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "other.conf", .data = "[found]\n\tvalue = yes\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const local_config = try std.fmt.allocPrint(
        gpa,
        "[includeIf \"gitdir:{s}/\"]\n\tpath = other.conf\n",
        .{path_buf[0..len]},
    );
    defer gpa.free(local_config);
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = local_config });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectEqualStrings("yes", repo.config.getString("found.value").?);
}

test "config.branch is set to HEAD's branch before includeIf resolves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `buildMinimalRepo` points HEAD at `refs/heads/main`.
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "other.conf", .data = "[found]\n\tvalue = yes\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "[includeIf \"onbranch:main\"]\n\tpath = other.conf\n",
    });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectEqualStrings("yes", repo.config.getString("found.value").?);
}

test "open builds a committer from user.name and user.email in config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n",
    });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expect(repo.refs.committer != null);
    try std.testing.expectEqualStrings("Ada Lovelace", repo.refs.committer.?.name);
    try std.testing.expectEqualStrings("ada@example.com", repo.refs.committer.?.email);
}

test "an explicit OpenOptions.committer wins over user.name and user.email in config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "config",
        .data = "[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n",
    });

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{
        .committer = .{ .name = "Sandbox Agent", .email = "agent@example.com" },
    }, null);
    defer repo.deinit();

    try std.testing.expectEqualStrings("Sandbox Agent", repo.refs.committer.?.name);
    try std.testing.expectEqualStrings("agent@example.com", repo.refs.committer.?.email);
}

test "open leaves the Store with no committer when config has neither user.name nor user.email" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try buildMinimalRepo(io, tmp.dir);

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expect(repo.refs.committer == null);
}

test "init creates HEAD naming the initial branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    var head_buf: [256]u8 = undefined;
    const head_content = try tmp.dir.readFile(io, ".git/HEAD", &head_buf);
    try std.testing.expectEqualStrings("ref: refs/heads/master\n", head_content);
}

test "init creates config with four core keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    var config_buf: [4096]u8 = undefined;
    const config_content = try tmp.dir.readFile(io, ".git/config", &config_buf);

    // Asserted as whole text, not with `indexOf`. A containment check
    // passes for `repositoryformatversion = 99` just as happily as for
    // `= 0`, and passes whatever else surrounds the keys. These exact
    // bytes were captured from `git init` with git 2.55.
    const probed = try Repository.probeFilemode(io, try tmp.dir.openDir(io, ".git", .{}));
    const expected = try std.fmt.allocPrint(
        gpa,
        "[core]\n\trepositoryformatversion = 0\n\tfilemode = {s}\n\tbare = false\n\tlogallrefupdates = true\n",
        .{if (probed) "true" else "false"},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, config_content);
}

test "init can be opened and HEAD resolves to RefNotFound for unborn branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try std.testing.expectError(error.RefNotFound, repo.head(null));
}

test "init creates no hooks, description or info/exclude directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    var git_dir = try tmp.dir.openDir(io, ".git", .{});
    defer git_dir.close(io);

    try std.testing.expectError(error.FileNotFound, git_dir.openDir(io, "hooks", .{}));
    try std.testing.expectError(error.FileNotFound, git_dir.statFile(io, "description", .{}));
    try std.testing.expectError(error.FileNotFound, git_dir.openDir(io, "info", .{}));
}

test "init accepts custom initial_branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{ .initial_branch = "develop" });

    var head_buf: [256]u8 = undefined;
    const head_content = try tmp.dir.readFile(io, ".git/HEAD", &head_buf);
    try std.testing.expectEqualStrings("ref: refs/heads/develop\n", head_content);
}

test "init creates bare repository when bare option is true" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{ .bare = true });

    var head_buf: [256]u8 = undefined;
    const head_content = try tmp.dir.readFile(io, "HEAD", &head_buf);
    try std.testing.expectEqualStrings("ref: refs/heads/master\n", head_content);

    var config_buf: [4096]u8 = undefined;
    const config_content = try tmp.dir.readFile(io, "config", &config_buf);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "bare = true") != null);
}

test "init refuses to init over an existing repository" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    try std.testing.expectError(error.AlreadyARepository, Repository.init(gpa, io, tmp.dir, .{}));
}

test "init probes filemode on the filesystem" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    var config_buf: [4096]u8 = undefined;
    const config_content = try tmp.dir.readFile(io, ".git/config", &config_buf);

    // `expect(saw_true or saw_false)` was the first version of this test
    // and proved nothing: it passes for a hardcoded value just as happily
    // as for a probed one. Compare the config against what the probe
    // itself answers, so a constant written into the config disagrees with
    // the probe and fails here.
    const probed = try Repository.probeFilemode(io, tmp.dir);
    const want = if (probed) "filemode = true" else "filemode = false";
    try std.testing.expect(std.mem.indexOf(u8, config_content, want) != null);

    // And the probe must give a real answer for this filesystem, not just
    // a self-consistent one. A temporary directory here keeps the bit.
    // A filesystem that drops it, such as a FAT mount, is not reachable
    // from a test that may not mount anything, so the false branch stays
    // unverified and is called out rather than pretended about.
    try std.testing.expect(probed);
}

// isShallow tests

test "a repository with a shallow file naming a commit reports true" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    const commit_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try repo.layout.common_dir.writeFile(io, .{ .sub_path = "shallow", .data = commit_id ++ "\n" });

    const is_shallow = try repo.isShallow(null);
    try std.testing.expectEqual(true, is_shallow);
}

test "a repository with no shallow file reports false" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    const is_shallow = try repo.isShallow(null);
    try std.testing.expectEqual(false, is_shallow);
}

test "a repository with an empty shallow file reports false" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.layout.common_dir.writeFile(io, .{ .sub_path = "shallow", .data = "" });

    const is_shallow = try repo.isShallow(null);
    try std.testing.expectEqual(false, is_shallow);
}

test "a shallow file whose line is the wrong length for the repository is corrupt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git/objects");

    const hex = "a" ** 40;
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/shallow", .data = hex ++ "\n" });

    try std.testing.expectError(
        error.CorruptObject,
        readShallowBoundary(gpa, io, try tmp.dir.openDir(io, ".git", .{}), .sha256, null),
    );
}

test "a corrupt shallow file names itself through diag" {
    // `isShallow` first took a `diag` and threw it away with `_ = diag;`.
    // A caller then got a bare CorruptObject with no way to learn which
    // file was wrong, which is the same hole already recorded against
    // `Index.open`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/shallow", .data = "not-an-object-id\n" });

    var git_dir = try tmp.dir.openDir(io, ".git", .{});
    defer git_dir.close(io);

    var diag: ?Diagnostic = null;
    defer if (diag) |*d| d.deinit(gpa);

    try std.testing.expectError(
        error.CorruptObject,
        readShallowBoundary(gpa, io, git_dir, .sha1, &diag),
    );
    try std.testing.expect(diag != null);
    try std.testing.expectEqual(Diagnostic.Kind.corrupt_gitfile, diag.?.kind);
    try std.testing.expectEqualStrings("shallow", diag.?.path.?);
}

test "createRemote sets both url and fetch keys in config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.createRemote("origin", "https://github.com/example/repo", "+refs/heads/*:refs/remotes/origin/*");

    var config_buf: [4096]u8 = undefined;
    const config_content = try repo.layout.common_dir.readFile(io, "config", &config_buf);

    try std.testing.expect(std.mem.indexOf(u8, config_content, "[remote \"origin\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "url = https://github.com/example/repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "fetch = +refs/heads/*:refs/remotes/origin/*") != null);
}

test "createRemote uses the whole config text, not just contains" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.createRemote("origin", "https://example.com", "+refs/heads/*:refs/remotes/origin/*");

    var config_buf: [4096]u8 = undefined;
    const config_content = try repo.layout.common_dir.readFile(io, "config", &config_buf);

    try std.testing.expectEqualStrings("[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n[remote \"origin\"]\n\turl = https://example.com\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", config_content);
}

test "createRemote preserves core section when adding remote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.createRemote("origin", "https://example.com", "+refs/heads/*:refs/remotes/origin/*");

    var config_buf: [4096]u8 = undefined;
    const config_content = try repo.layout.common_dir.readFile(io, "config", &config_buf);

    try std.testing.expect(std.mem.indexOf(u8, config_content, "[core]") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "repositoryformatversion = 0") != null);
}

test "createRemote updates existing remote instead of adding second section" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.createRemote("origin", "https://old.com", "+refs/heads/*:refs/remotes/origin/*");
    try repo.createRemote("origin", "https://new.com", "+refs/tags/*:refs/remotes/origin/tags/*");

    var config_buf: [4096]u8 = undefined;
    const config_content = try repo.layout.common_dir.readFile(io, "config", &config_buf);

    try std.testing.expect(std.mem.indexOf(u8, config_content, "https://new.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "+refs/tags/*:refs/remotes/origin/tags/*") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_content, "https://old.com") == null);
}

test "repository reopened after createRemote reads the url through config.getString" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});

    const layout1 = try discover(gpa, io, tmp.dir, .{}, null);
    var repo1 = try Repository.open(gpa, io, layout1, .{}, null);
    try repo1.createRemote("origin", "https://github.com/example/repo", "+refs/heads/*:refs/remotes/origin/*");
    repo1.deinit();

    const layout2 = try discover(gpa, io, tmp.dir, .{}, null);
    var repo2 = try Repository.open(gpa, io, layout2, .{}, null);
    defer repo2.deinit();

    const url = repo2.config.getString("remote.origin.url");
    try std.testing.expectEqualStrings("https://github.com/example/repo", url.?);
}

test "createRemote writes through config.lock and leaves none behind" {
    // Asserting only that no `config.lock` remains is a test that passes
    // both ways: a write that never makes a lock file leaves none either.
    // So a stale lock holding recognisable bytes is put there first. A
    // write that goes straight to `config` cannot disturb it, and the
    // bytes are still on disk at the end. A write that goes through the
    // lock replaces it and renames it away.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});
    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.layout.common_dir.writeFile(io, .{
        .sub_path = "config.lock",
        .data = "STALE LOCK FROM A CRASHED WRITE\n",
    });

    try repo.createRemote("origin", "https://example.com/r.git", "+refs/heads/*:refs/remotes/origin/*");

    // Gone, because the rename moved it over `config`.
    try std.testing.expectError(
        error.FileNotFound,
        repo.layout.common_dir.statFile(io, "config.lock", .{}),
    );
    // And its bytes did not end up in `config`.
    var buf: [4096]u8 = undefined;
    const config_text = try repo.layout.common_dir.readFile(io, "config", &buf);
    try std.testing.expect(std.mem.indexOf(u8, config_text, "STALE LOCK") == null);
    try std.testing.expect(std.mem.indexOf(u8, config_text, "https://example.com/r.git") != null);
}

test "a config that fails to parse is not left behind by createRemote" {
    // The point of writing through a lock and renaming: the config a
    // reader sees is either the old one or the new one, never a partial
    // file. `open` reads this file for core.repositoryformatversion, so a
    // truncated config makes the repository unopenable.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try Repository.init(gpa, io, tmp.dir, .{});
    const layout = try discover(gpa, io, tmp.dir, .{}, null);
    var repo = try Repository.open(gpa, io, layout, .{}, null);
    defer repo.deinit();

    try repo.createRemote("origin", "https://example.com/r.git", "+refs/heads/*:refs/remotes/origin/*");

    // Reopening proves the file on disk still parses as a whole config.
    const layout2 = try discover(gpa, io, tmp.dir, .{}, null);
    var repo2 = try Repository.open(gpa, io, layout2, .{}, null);
    defer repo2.deinit();
    try std.testing.expectEqualStrings(
        "https://example.com/r.git",
        repo2.config.getString("remote.origin.url").?,
    );
}
