//! Ported from src/keyboard.lua and src/controls.lua to Zig on 2026-10-02 by
//! Peter Marreck with Claude Opus 5.5 (claude-opus-5-5).
//! Terminal key decoding: legacy key bytes plus kitty keyboard protocol CSI-u
//! sequences (ESC [ code[:alts] ; mods[:event] u). Kitty events carry key
//! press/repeat/release, which makes hold-to-fire possible. Pure: bytes in,
//! keys out, one byte at a time so split reads decode correctly.
const std = @import("std");

pub const Kind = enum(u8) { press = 1, repeat = 2, release = 3 };

pub const Key = union(enum) {
	byte: u8,
	kitty: struct { code: u32, mods: u32, kind: Kind },
	/// Reply to the `CSI ? u` query: the terminal's active kitty flags.
	kitty_flags: u32,
};

/// Player-level meaning of a key.
pub const Event = enum { guns_tap, guns_down, guns_up, death, pause, quit };

const max_sequence = 32;
const lock_bits: u32 = 64 | 128; // Caps Lock and Num Lock never change a key's meaning.
const shift: u32 = 1;
const ctrl: u32 = 4;

pub const Decoder = struct {
	buf: [max_sequence]u8 = undefined,
	len: usize = 0,
	state: enum { idle, escape, ss3, csi, skip } = .idle,

	/// Feed one byte; returns a decoded key when one completes.
	pub fn feed(self: *Decoder, b: u8) ?Key {
		switch (self.state) {
			.idle => {
				if (b == 0x1b) {
					self.state = .escape;
					return null;
				}
				return .{ .byte = b };
			},
			.escape => {
				self.state = switch (b) {
					'[' => .csi,
					'O' => .ss3,
					else => .idle,
				};
				self.len = 0;
				return null;
			},
			.ss3 => {
				self.state = .idle;
				return null;
			},
			.csi, .skip => {
				if (b >= 0x40 and b <= 0x7e) {
					const complete = self.state == .csi and b == 'u';
					self.state = .idle;
					return if (complete) parseCsiU(self.buf[0..self.len]) else null;
				}
				if (b < 0x20 or b > 0x3f) {
					self.state = .idle;
					return null;
				}
				if (self.state == .csi) {
					if (self.len == max_sequence) {
						self.state = .skip;
					} else {
						self.buf[self.len] = b;
						self.len += 1;
					}
				}
				return null;
			},
		}
	}
};

/// Parse kitty CSI-u parameters: code[:alternates][;mods[:event]].
fn parseCsiU(params: []const u8) ?Key {
	if (params.len > 1 and params[0] == '?')
		return .{ .kitty_flags = std.fmt.parseInt(u32, params[1..], 10) catch return null };
	var fields = std.mem.splitScalar(u8, params, ';');
	const key_field = fields.next() orelse return null;
	var key_parts = std.mem.splitScalar(u8, key_field, ':');
	const code = std.fmt.parseInt(u32, key_parts.next() orelse return null, 10) catch return null;
	var mods: u32 = 1;
	var kind: Kind = .press;
	if (fields.next()) |mod_field| {
		var mod_parts = std.mem.splitScalar(u8, mod_field, ':');
		const m = mod_parts.next() orelse "";
		if (m.len > 0) mods = std.fmt.parseInt(u32, m, 10) catch return null;
		if (mod_parts.next()) |e| {
			if (e.len > 0) kind = std.enums.fromInt(Kind, std.fmt.parseInt(u8, e, 10) catch return null) orelse return null;
		}
	}
	if (fields.next() != null or mods == 0) return null;
	return .{ .kitty = .{ .code = code, .mods = (mods - 1) & ~lock_bits, .kind = kind } };
}

/// Map a decoded key to a player event. Legacy bytes keep the original key
/// meanings; kitty space becomes press-to-fire / release-to-stop.
pub fn classify(key: Key) ?Event {
	switch (key) {
		.byte => |b| return switch (b) {
			' ' => .guns_tap,
			'd' => .death,
			'p', 'P' => .pause,
			'q', 'Q', 'D', 0x03, 0x04, 0x11 => .quit,
			else => null,
		},
		.kitty_flags => return null,
		.kitty => |k| {
			if (k.code == ' ' and k.mods == 0) return if (k.kind == .release) .guns_up else .guns_down;
			if (k.kind != .press) return null;
			return switch (k.code) {
				'd' => if (k.mods == 0) .death else if (k.mods == shift or k.mods == ctrl) .quit else null,
				'p' => if (k.mods == 0 or k.mods == shift) .pause else null,
				'q' => if (k.mods == 0 or k.mods == shift or k.mods == ctrl) .quit else null,
				'c' => if (k.mods == ctrl) .quit else null,
				else => null,
			};
		},
	}
}

fn decodeAll(bytes: []const u8, out: []?Event) usize {
	var d: Decoder = .{};
	var n: usize = 0;
	for (bytes) |b| if (d.feed(b)) |k| {
		out[n] = classify(k);
		n += 1;
	};
	return n;
}

fn expectEvents(bytes: []const u8, expected: []const ?Event) !void {
	var out: [64]?Event = undefined;
	const n = decodeAll(bytes, &out);
	try std.testing.expectEqualSlices(?Event, expected, out[0..n]);
}

test "legacy bytes keep the original key meanings" {
	try expectEvents(" dpPqQD\x03\x04\x11x", &.{ .guns_tap, .death, .pause, .pause, .quit, .quit, .quit, .quit, .quit, .quit, null });
}

test "kitty space fires from press through repeat until release" {
	try expectEvents("\x1b[32u\x1b[32;1:2u\x1b[32;1:3u", &.{ .guns_down, .guns_down, .guns_up });
}

test "kitty death and pause act on press only" {
	try expectEvents("\x1b[100u\x1b[100;1:2u\x1b[100;1:3u", &.{ .death, null, null });
	try expectEvents("\x1b[112u\x1b[112;2u\x1b[112;1:3u", &.{ .pause, .pause, null });
}

test "kitty quit keys: shift+d, q, Q, ctrl+c/d/q" {
	try expectEvents("\x1b[100;2u\x1b[113u\x1b[113;2u", &.{ .quit, .quit, .quit });
	try expectEvents("\x1b[99;5u\x1b[100;5u\x1b[113;5u", &.{ .quit, .quit, .quit });
	try expectEvents("\x1b[113;1:3u", &.{null});
}

test "lock modifiers are ignored; other modifiers are not controls" {
	try expectEvents("\x1b[100;65u\x1b[32;129u", &.{ .death, .guns_down });
	try expectEvents("\x1b[32;5u\x1b[100;3u", &.{ null, null });
}

test "unrelated escape sequences produce nothing" {
	try expectEvents("\x1b[A\x1b[?1049h\x1bOP", &.{});
}

test "a sequence split across reads decodes once complete" {
	var d: Decoder = .{};
	for ("\x1b[32") |b| try std.testing.expect(d.feed(b) == null);
	try std.testing.expectEqual(Event.guns_down, classify(d.feed('u').?).?);
}

test "oversized sequences are discarded without unbounded buffering" {
	try expectEvents("\x1b[" ++ "9" ** 100 ++ "u ", &.{.guns_tap});
}

test "kitty flag query replies are decoded and are not player events" {
	var d: Decoder = .{};
	var last: ?Key = null;
	for ("\x1b[?11u") |b| last = d.feed(b) orelse last;
	try std.testing.expectEqual(@as(u32, 11), last.?.kitty_flags);
	try std.testing.expectEqual(@as(?Event, null), classify(last.?));
	d = .{};
	last = null;
	for ("\x1b[?0u") |b| last = d.feed(b) orelse last;
	try std.testing.expectEqual(@as(u32, 0), last.?.kitty_flags);
}
