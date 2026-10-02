//! Ported from src/wav.lua to Zig on 2026-10-02 by Peter Marreck with
//! Claude Opus 5.5 (claude-opus-5-5).
//! Mono signed 16-bit PCM WAV encoding: 44-byte RIFF header and clamped
//! float-to-PCM16 sample conversion (asymmetric scale, round half up).
const std = @import("std");

pub const header_len = 44;
/// RIFF chunk sizes are u32; the data chunk must leave room for the header.
pub const max_samples: u64 = (0xffff_ffff - 36) / 2;

pub fn header(out: *[header_len]u8, rate: u32, samples: u64) error{TooLong}!void {
	if (samples > max_samples) return error.TooLong;
	const bytes: u32 = @intCast(samples * 2);
	@memcpy(out[0..4], "RIFF");
	std.mem.writeInt(u32, out[4..8], 36 + bytes, .little);
	@memcpy(out[8..16], "WAVEfmt ");
	std.mem.writeInt(u32, out[16..20], 16, .little);
	std.mem.writeInt(u16, out[20..22], 1, .little);
	std.mem.writeInt(u16, out[22..24], 1, .little);
	std.mem.writeInt(u32, out[24..28], rate, .little);
	std.mem.writeInt(u32, out[28..32], rate * 2, .little);
	std.mem.writeInt(u16, out[32..34], 2, .little);
	std.mem.writeInt(u16, out[34..36], 16, .little);
	@memcpy(out[36..40], "data");
	std.mem.writeInt(u32, out[40..44], bytes, .little);
}

/// Clamp to [-1, 1] and scale to signed 16-bit little-endian.
pub fn sample(value: f64) [2]u8 {
	// f64 arithmetic matches the previous LuaJIT encoder bit for bit.
	const v = if (std.math.isNan(value)) 0 else value;
	const clamped = std.math.clamp(v, -1, 1);
	const scale: f64 = if (v < 0) 32768 else 32767;
	const signed: i16 = @intFromFloat(@floor(clamped * scale + 0.5));
	var out: [2]u8 = undefined;
	std.mem.writeInt(i16, &out, signed, .little);
	return out;
}

const t = std.testing;

test "header layout for three mono 48 kHz samples" {
	var h: [header_len]u8 = undefined;
	try header(&h, 48000, 3);
	try t.expectEqualSlices(u8, "RIFF", h[0..4]);
	try t.expectEqual(@as(u32, 36 + 6), std.mem.readInt(u32, h[4..8], .little));
	try t.expectEqualSlices(u8, "WAVEfmt ", h[8..16]);
	try t.expectEqual(@as(u32, 16), std.mem.readInt(u32, h[16..20], .little));
	try t.expectEqual(@as(u16, 1), std.mem.readInt(u16, h[20..22], .little)); // PCM
	try t.expectEqual(@as(u16, 1), std.mem.readInt(u16, h[22..24], .little)); // mono
	try t.expectEqual(@as(u32, 48000), std.mem.readInt(u32, h[24..28], .little));
	try t.expectEqual(@as(u32, 96000), std.mem.readInt(u32, h[28..32], .little));
	try t.expectEqual(@as(u16, 2), std.mem.readInt(u16, h[32..34], .little));
	try t.expectEqual(@as(u16, 16), std.mem.readInt(u16, h[34..36], .little));
	try t.expectEqualSlices(u8, "data", h[36..40]);
	try t.expectEqualSlices(u8, "\x06\x00\x00\x00", h[40..44]);
}

test "header rejects data beyond the RIFF size limit" {
	var h: [header_len]u8 = undefined;
	try header(&h, 48000, max_samples);
	try t.expectError(error.TooLong, header(&h, 48000, max_samples + 1));
}

test "sample scaling, clamping and rounding match the Lua encoder" {
	try t.expectEqualSlices(u8, "\x00\x80", &sample(-1));
	try t.expectEqualSlices(u8, "\xff\x7f", &sample(1));
	try t.expectEqualSlices(u8, "\x00\x00", &sample(0));
	try t.expectEqualSlices(u8, "\xff\x7f", &sample(3));
	try t.expectEqualSlices(u8, "\x00\x80", &sample(-3));
	try t.expectEqualSlices(u8, "\x00\x40", &sample(0.5)); // 16383.5 rounds up
	try t.expectEqualSlices(u8, "\x00\xc0", &sample(-0.5)); // -16384
}

test "NaN encodes as silence instead of undefined float-to-int conversion" {
	try t.expectEqualSlices(u8, "\x00\x00", &sample(std.math.nan(f64)));
}
