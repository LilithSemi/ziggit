const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");

    const ziggit = b.addModule("ziggit", .{
        .root_source_file = b.path("lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Object ids. It imports nothing, and that is on purpose: a hash with a
    // published specification and published test vectors needs no error
    // taxonomy, no diagnostics, and no repository layout. Every module above
    // imports this one.
    const oid = b.addModule("ziggit-oid", .{
        .root_source_file = b.path("lib/ziggit-oid.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, oid);

    // The pkt-line codec: git's wire protocol framing. It imports nothing,
    // and that is on purpose: a codec with a published specification and
    // published test vectors needs no error taxonomy, no diagnostics, and no
    // repository layout.
    const pktline = b.addModule("ziggit-pktline", .{
        .root_source_file = b.path("lib/ziggit-pktline.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, pktline);

    // The shared vocabulary of every layer above: object kinds, file modes,
    // authorship identity, the diagnostic channel, and ref name validation.
    // It holds no I/O.
    const core = b.addModule("ziggit-core", .{
        .root_source_file = b.path("lib/ziggit-core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
        },
    });
    addModuleTests(b, test_step, core);

    // The object formats alone: loose object framing, and the typed
    // parsers and serializers for commit, tree, and tag. No database
    // policy (no `.git/objects` layout, no deduplication), and no packs.
    const object = b.addModule("ziggit-object", .{
        .root_source_file = b.path("lib/ziggit-object.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
        },
    });
    addModuleTests(b, test_step, object);

    // Refs on disk alone: loose ref files, packed-refs, symrefs,
    // compare-and-swap updates, and the reflog. It deliberately does not
    // import `ziggit-object`, because a ref is an id and a name, and
    // peeling a tag is the caller's job, not this module's.
    const refs = b.addModule("ziggit-refs", .{
        .root_source_file = b.path("lib/ziggit-refs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
        },
    });
    addModuleTests(b, test_step, refs);

    // git's own INI dialect, not a generic one: layered config across
    // levels, value parsing, and include/includeIf resolution. It
    // deliberately does not import `ziggit-oid`, because a config value
    // is text; the one key that names a hash format is read as a string
    // here and turned into an `Oid.Format` by `ziggit-repo` in a later
    // task.
    const config = b.addModule("ziggit-config", .{
        .root_source_file = b.path("lib/ziggit-config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-core", .module = core },
        },
    });
    addModuleTests(b, test_step, config);

    // Reads `.git/index`, git's staged snapshot of the working tree.
    // Versions 2 and 3 only; version 4's prefix-compressed path names are a
    // different parser and are refused. Read only: a consumer needs this
    // to see what a dirty working tree looks like, and writing an index
    // back out belongs to a later task.
    const index = b.addModule("ziggit-index", .{
        .root_source_file = b.path("lib/ziggit-index.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
        },
    });
    addModuleTests(b, test_step, index);

    // The pack format alone: the "PACK" header and delta-compressed entry
    // stream, delta chain resolution, and `.idx` version 2 reading and
    // writing. No database policy (no alternates, no loose objects);
    // `ziggit-odb`, in a later task, is what decides which pack to open.
    const pack = b.addModule("ziggit-pack", .{
        .root_source_file = b.path("lib/ziggit-pack.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
        },
    });
    addModuleTests(b, test_step, pack);

    // The protocol grammar alone: the v2 capability advertisement,
    // `ls-refs`, `fetch`, and the sideband demultiplexer. No sockets, no
    // transport, no repository; every function here reads a caller-supplied
    // `std.Io.Reader` or writes a caller-supplied `std.Io.Writer`.
    const proto = b.addModule("ziggit-proto", .{
        .root_source_file = b.path("lib/ziggit-proto.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-pktline", .module = pktline },
        },
    });
    addModuleTests(b, test_step, proto);

    // The network dependency. `ziggit-transport` is the only module in
    // this project allowed to import it: every module above speaks git's
    // formats and protocol grammar with no socket in sight, and this is
    // where a socket first appears. Nothing below this line may add
    // `zurl` to its own imports.
    const zurl_dep = b.dependency("zurl", .{ .target = target, .optimize = optimize });

    // The `Transport` interface, and the smart-HTTP implementation over
    // `zurl`. One `zurl.Client` per `Http` transport, owned by it, so
    // `fix` can fetch distinct repositories concurrently with nothing
    // shared between them.
    //
    // This is the module every other module in this project imports, and
    // it carries no `zurl-http`: a non-test file that reached for it here
    // would fail to compile, not merely break a convention.
    const transport = b.addModule("ziggit-transport", .{
        .root_source_file = b.path("lib/ziggit-transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-pktline", .module = pktline },
            .{ .name = "ziggit-proto", .module = proto },
            .{ .name = "zurl", .module = zurl_dep.module("zurl") },
            .{ .name = "zurl-ssh", .module = zurl_dep.module("zurl-ssh") },
            .{ .name = "zurl-scp", .module = zurl_dep.module("zurl-scp") },
        },
    });
    // A private module (`createModule`, not `addModule`: it never joins
    // this package's exported module set), compiled from the very same
    // source, that also carries `zurl-http`: the loopback HTTP server
    // `http.zig`'s tests drive. Only this one goes to `addModuleTests`,
    // so `zig build test` still runs every test in the file, and the
    // boundary above is enforced by the build graph rather than by a
    // comment a future change could outgrow.
    const transport_test = b.createModule(.{
        .root_source_file = b.path("lib/ziggit-transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-pktline", .module = pktline },
            .{ .name = "ziggit-proto", .module = proto },
            .{ .name = "zurl", .module = zurl_dep.module("zurl") },
            .{ .name = "zurl-http", .module = zurl_dep.module("zurl-http") },
            .{ .name = "zurl-ssh", .module = zurl_dep.module("zurl-ssh") },
            .{ .name = "zurl-scp", .module = zurl_dep.module("zurl-scp") },
        },
    });
    addModuleTests(b, test_step, transport_test);

    // The policy layer: it decides which backend, loose or packed,
    // answers a read, and it owns alternates and the environment
    // redirection a sandboxed consumer depends on.
    const odb = b.addModule("ziggit-odb", .{
        .root_source_file = b.path("lib/ziggit-odb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
            .{ .name = "ziggit-pack", .module = pack },
            .{ .name = "ziggit-index", .module = index },
        },
    });
    addModuleTests(b, test_step, odb);

    // Writing a tree out to a working directory: content filters
    // disabled unconditionally (a caller of this project hashes the raw
    // committed blob bytes, and a filter rewriting a byte on the way out
    // would silently change that hash), and every tree entry name
    // checked against path traversal before it is ever joined to a path.
    const checkout = b.addModule("ziggit-checkout", .{
        .root_source_file = b.path("lib/ziggit-checkout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
            .{ .name = "ziggit-odb", .module = odb },
        },
    });
    addModuleTests(b, test_step, checkout);

    // The top of the core: repository discovery, the on-disk layout, and
    // the `Repository` that ties the object database, the ref store, and
    // config into one thing. This is the one module that knows how the
    // pieces of a repository sit on disk together.
    const repo = b.addModule("ziggit-repo", .{
        .root_source_file = b.path("lib/ziggit-repo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-refs", .module = refs },
            .{ .name = "ziggit-config", .module = config },
            .{ .name = "ziggit-odb", .module = odb },
        },
    });
    addModuleTests(b, test_step, repo);

    // Revision resolution and commit graph walking: a revision string to
    // an object id, peeling an annotated tag, and walking the commit
    // graph. It sits directly on `ziggit-repo`, since every function here
    // takes a whole `Repository`, not a bare `Odb`/`Store` pair.
    const revwalk = b.addModule("ziggit-revwalk", .{
        .root_source_file = b.path("lib/ziggit-revwalk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
            .{ .name = "ziggit-odb", .module = odb },
            .{ .name = "ziggit-refs", .module = refs },
            .{ .name = "ziggit-repo", .module = repo },
        },
    });
    addModuleTests(b, test_step, revwalk);

    // Fetch: the remote strategy. Refspec matching, protocol v2
    // negotiation, receiving a packfile, and updating refs, tied into
    // one operation. This is the only module in this project that
    // imports both `ziggit-transport` and `ziggit-refs`, since it is the
    // one place those two strategies (and every module between them)
    // meet.
    const fetch = b.addModule("ziggit-fetch", .{
        .root_source_file = b.path("lib/ziggit-fetch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
            .{ .name = "ziggit-pack", .module = pack },
            .{ .name = "ziggit-odb", .module = odb },
            .{ .name = "ziggit-refs", .module = refs },
            .{ .name = "ziggit-repo", .module = repo },
            .{ .name = "ziggit-proto", .module = proto },
            .{ .name = "ziggit-transport", .module = transport },
            .{ .name = "ziggit-pktline", .module = pktline },
            .{ .name = "ziggit-revwalk", .module = revwalk },
        },
    });
    addModuleTests(b, test_step, fetch);

    // Submodules: parsing `.gitmodules`, and fetching and checking out
    // every submodule a tree records, recursively. It composes fetch,
    // checkout, config, repo, and odb rather than adding a new layer any
    // of them depends on, since a submodule is a repository within a
    // repository, not a new kind of storage.
    const submodule = b.addModule("ziggit-submodule", .{
        .root_source_file = b.path("lib/ziggit-submodule.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggit-oid", .module = oid },
            .{ .name = "ziggit-core", .module = core },
            .{ .name = "ziggit-object", .module = object },
            .{ .name = "ziggit-odb", .module = odb },
            .{ .name = "ziggit-config", .module = config },
            .{ .name = "ziggit-repo", .module = repo },
            .{ .name = "ziggit-checkout", .module = checkout },
            .{ .name = "ziggit-fetch", .module = fetch },
        },
    });
    addModuleTests(b, test_step, submodule);

    // The front package needs every module below wired in only now, once
    // each one exists: `lib/ziggit.zig` re-exports from all of them and
    // its own `test` block imports all of them, so its module must
    // import all of them too.
    ziggit.addImport("ziggit-oid", oid);
    ziggit.addImport("ziggit-core", core);
    ziggit.addImport("ziggit-object", object);
    ziggit.addImport("ziggit-pack", pack);
    ziggit.addImport("ziggit-refs", refs);
    ziggit.addImport("ziggit-config", config);
    ziggit.addImport("ziggit-odb", odb);
    ziggit.addImport("ziggit-repo", repo);
    ziggit.addImport("ziggit-index", index);
    ziggit.addImport("ziggit-transport", transport);
    ziggit.addImport("ziggit-checkout", checkout);
    ziggit.addImport("ziggit-revwalk", revwalk);
    ziggit.addImport("ziggit-fetch", fetch);
    ziggit.addImport("ziggit-submodule", submodule);
    addModuleTests(b, test_step, ziggit);

    // The plumbing CLI: the one place in this project allowed to print,
    // since it is not a library module. Its whole purpose is comparing
    // ziggit's output against real git on real repositories by hand.
    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggit", .module = ziggit },
                // `ls-remote`'s network path speaks protocol v2 directly
                // (one command, never a whole fetch), which is not part
                // of the front package's surface; see `main.zig`'s own
                // comment on the same reach-past.
                .{ .name = "ziggit-proto", .module = proto },
                .{ .name = "ziggit-pktline", .module = pktline },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the ziggit plumbing CLI");
    run_step.dependOn(&run_cmd.step);
}

/// Adds a test run for `module` to `test_step`.
///
/// A build for a different target analyses every declaration and skips only
/// the run. `zig build test -Dtarget=aarch64-macos` therefore compiles each
/// module for Darwin instead of failing the whole build on the first module.
fn addModuleTests(b: *std.Build, test_step: *std.Build.Step, module: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    run.skip_foreign_checks = true;
    test_step.dependOn(&run.step);
}
