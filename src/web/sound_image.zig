//! Build-input check for the web player's embedded sound-board image.
const std = @import("std");
const rom = @import("rom");

const bytes = @embedFile("sound_image.bin");

test "embedded sound image is the seven sound-board members and nothing else" {
	try std.testing.expect(rom.verifySoundImage(bytes));
	var copy: [bytes.len]u8 = undefined;
	@memcpy(&copy, bytes);
	copy[0] ^= 0x01;
	try std.testing.expect(!rom.verifySoundImage(&copy));
	copy[0] ^= 0x01;
	copy[bytes.len - 1] ^= 0x01;
	try std.testing.expect(!rom.verifySoundImage(&copy));
}
