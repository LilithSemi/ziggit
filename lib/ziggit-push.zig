//! Sending refs and objects to a remote.
//!
//! Receive-pack has no protocol v2, so nothing here shares the v2
//! advertisement `ziggit-proto` parses for fetch. The old ref
//! advertisement, the ref update commands and the status report live in
//! this module instead.

const protocol_mod = @import("ziggit-push/protocol.zig");
pub const ProtocolError = protocol_mod.Error;
pub const Advertisement = protocol_mod.Advertisement;
pub const Ref = protocol_mod.Ref;
pub const Command = protocol_mod.Command;
pub const Report = protocol_mod.Report;
pub const RefStatus = protocol_mod.RefStatus;
pub const readAdvertisement = protocol_mod.readAdvertisement;
pub const writeCommands = protocol_mod.writeCommands;
pub const readReport = protocol_mod.readReport;

const send_mod = @import("ziggit-push/send.zig");
pub const SendError = send_mod.Error;
pub const Update = send_mod.Update;
pub const LeaseFailure = send_mod.LeaseFailure;
pub const checkLeases = send_mod.checkLeases;
pub const writeRequest = send_mod.writeRequest;

const objects_mod = @import("ziggit-push/objects.zig");
pub const ObjectsError = objects_mod.Error;
pub const collectObjects = objects_mod.collect;
pub const OdbSource = objects_mod.OdbSource;

test {
    _ = objects_mod;
    _ = protocol_mod;
    _ = send_mod;
}
