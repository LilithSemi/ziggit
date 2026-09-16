//! git's own INI dialect, not a generic one: layered config across
//! `Level`s (system, global, local, worktree, command), value parsing
//! (quoting, backslash escapes, line continuation, `k`/`m`/`g` suffixes),
//! and `include`/`includeIf` resolution.
//!
//! A section name and a key name compare case insensitively; a
//! subsection name compares case sensitively. A bare key with no `=` at
//! all reads as boolean true, distinct from an explicit empty value,
//! which reads as false. None of this is a generic INI format; it is
//! git's, verbatim.

const config_mod = @import("ziggit-config/Config.zig");
pub const Level = config_mod.Level;
pub const Config = config_mod.Config;

const parser_mod = @import("ziggit-config/Parser.zig");
const include_mod = @import("ziggit-config/include.zig");
const writer_mod = @import("ziggit-config/Writer.zig");
pub const Writer = writer_mod;

test {
    _ = config_mod;
    _ = parser_mod;
    _ = include_mod;
    _ = writer_mod;
}
