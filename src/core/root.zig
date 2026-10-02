//! Spy Hunter sound-board core: pure in-memory logic behind the C FFI.
pub const keyboard = @import("keyboard.zig");
pub const controller = @import("controller.zig");
pub const wav = @import("wav.zig");
pub const zip = @import("zip.zig");
pub const rom = @import("rom.zig");
pub const board = @import("board.zig");
pub const ffi = @import("ffi.zig");
pub const terminal = @import("terminal.zig");
pub const tips = @import("tips.zig");

test {
	@import("std").testing.refAllDecls(@This());
}
