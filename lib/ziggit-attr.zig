//! `.gitattributes` lookup, and the content conversion it decides.
//!
//! What this applies is pure computation: line endings, `$Id$`, and the
//! `working-tree-encoding` conversions Zig can do without a charset
//! library. What it cannot apply is a `filter=` clean or smudge driver,
//! whose config value is a shell command string. Git LFS is exactly that
//! mechanism, so this reports such a path and never pretends to have
//! filtered it.

const attributes_mod = @import("ziggit-attr/Attributes.zig");
pub const Error = attributes_mod.Error;
pub const Attributes = attributes_mod.Attributes;
pub const PathAttrs = attributes_mod.PathAttrs;
pub const TextSetting = attributes_mod.TextSetting;
pub const Autocrlf = attributes_mod.Autocrlf;
pub const CoreConfig = attributes_mod.CoreConfig;
pub const Plan = attributes_mod.Plan;
pub const plan = attributes_mod.plan;
pub const max_file_len = attributes_mod.max_file_len;

const encoding_mod = @import("ziggit-attr/encoding.zig");
pub const Encoding = encoding_mod.Encoding;
pub const EncodingError = encoding_mod.Error;
pub const toUtf8 = encoding_mod.toUtf8;
pub const fromUtf8 = encoding_mod.fromUtf8;

const from_tree_mod = @import("ziggit-attr/from_tree.zig");
pub const FromTreeError = from_tree_mod.Error;
pub const fromTree = from_tree_mod.fromTree;
pub const Unsupported = from_tree_mod.Unsupported;
pub const unsupportedFilters = from_tree_mod.unsupportedFilters;
pub const ObjectReader = from_tree_mod.ObjectReader;

const convert_mod = @import("ziggit-attr/convert.zig");
pub const Eol = convert_mod.Eol;
pub const TextKind = convert_mod.TextKind;
pub const hasNul = convert_mod.hasNul;
pub const cleanTranslates = convert_mod.cleanTranslates;
pub const smudgeTranslates = convert_mod.smudgeTranslates;
pub const cleanLineEndings = convert_mod.cleanLineEndings;
pub const smudgeLineEndings = convert_mod.smudgeLineEndings;
pub const cleanIdent = convert_mod.cleanIdent;
pub const smudgeIdent = convert_mod.smudgeIdent;

test {
    _ = attributes_mod;
    _ = convert_mod;
    _ = from_tree_mod;
    _ = encoding_mod;
}
