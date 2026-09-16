//! Writing a tree out to a working directory, and nothing else: no index,
//! no ref update, no HEAD. `ziggit-repo` decides which tree that is;
//! `ziggit-submodule`, in a later task, decides what happens with the
//! empty directory this module leaves at a gitlink.

const checkout_mod = @import("ziggit-checkout/Checkout.zig");
pub const Strategy = checkout_mod.Strategy;
pub const Error = checkout_mod.Error;
pub const checkoutTree = checkout_mod.checkoutTree;

test {
    _ = checkout_mod;
}
