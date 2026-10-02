//! Ported from src/player.lua to Zig on 2026-10-02 by Peter Marreck with
//! Claude Opus 5.5 (claude-opus-5-5).
//! Interactive controller: a pure state machine from (event, now) to board
//! effects. Death resumes driving music after a delay; guns start once per
//! firing run (resending the start resets the ROM's burst rhythm); pause
//! freezes playback and shifts pending deadlines by the paused time.
const std = @import("std");
const keyboard = @import("keyboard.zig");

pub const Input = union(enum) { key: keyboard.Event, tick };

pub const Effects = struct {
	command: ?u4 = null,
	guns: ?bool = null,
	quit: bool = false,
};

/// Music-board commands (low two bits dispatch in the ROM).
pub const death_command: u4 = 0;
pub const driving_command: u4 = 1;
/// Seconds of death cue before driving music resumes (player policy).
pub const death_seconds: f64 = 8;
/// A legacy keystroke has no release event; fire this long after the last
/// one. Tap-faithful (Peter, 2026-10-02): the arcade's two-shot "tsch-tsch",
/// accepting one gap before autorepeat when held in such terminals.
pub const tap_seconds: f64 = 0.14;

pub const Controller = struct {
	resume_at: ?f64 = null,
	guns_until: ?f64 = null,
	guns_held: bool = false,
	paused_at: ?f64 = null,

	pub fn paused(self: Controller) bool {
		return self.paused_at != null;
	}

	fn firing(self: Controller) bool {
		return self.guns_held or self.guns_until != null;
	}

	fn stopGuns(self: *Controller, fx: *Effects) void {
		if (self.firing()) fx.guns = false;
		self.guns_held = false;
		self.guns_until = null;
	}

	pub fn handle(self: *Controller, input: Input, now: f64) Effects {
		var fx: Effects = .{};
		switch (input) {
			.key => |event| switch (event) {
				.quit => fx.quit = true,
				.pause => if (self.paused_at) |since| {
					if (self.resume_at) |at| self.resume_at = at + (now - since);
					self.paused_at = null;
				} else {
					self.stopGuns(&fx);
					self.paused_at = now;
				},
				else => if (!self.paused()) switch (event) {
					.death => {
						self.resume_at = now + death_seconds;
						fx.command = death_command;
					},
					.guns_tap, .guns_down => {
						if (!self.firing()) fx.guns = true;
						if (event == .guns_down) {
							self.guns_held = true;
							self.guns_until = null;
						} else if (!self.guns_held) self.guns_until = now + tap_seconds;
					},
					.guns_up => self.stopGuns(&fx),
					else => unreachable,
				},
			},
			.tick => if (!self.paused()) {
				if (self.resume_at) |at| if (now >= at) {
					self.resume_at = null;
					fx.command = driving_command;
				};
				if (self.guns_until) |at| if (now >= at) {
					self.guns_until = null;
					fx.guns = false;
				};
			},
		}
		return fx;
	}
};

const t = std.testing;

test "death plays the cue, then resumes driving music after the delay" {
	var c: Controller = .{};
	try t.expectEqual(@as(?u4, death_command), c.handle(.{ .key = .death }, 1).command);
	try t.expectEqual(@as(?u4, null), c.handle(.tick, 6).command);
	try t.expectEqual(@as(?u4, driving_command), c.handle(.tick, 9).command);
	try t.expectEqual(@as(?f64, null), c.resume_at);
}

test "legacy taps start once and stop a tap duration after the last keystroke" {
	var c: Controller = .{};
	try t.expectEqual(@as(?bool, true), c.handle(.{ .key = .guns_tap }, 1).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.{ .key = .guns_tap }, 1.5).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.tick, 1.5 + tap_seconds - 0.01).guns);
	try t.expectEqual(@as(?bool, false), c.handle(.tick, 1.5 + tap_seconds).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.tick, 10).guns);
}

test "kitty press fires until release, however long" {
	var c: Controller = .{};
	try t.expectEqual(@as(?bool, true), c.handle(.{ .key = .guns_down }, 1).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.{ .key = .guns_down }, 1.5).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.tick, 100).guns);
	try t.expectEqual(@as(?bool, false), c.handle(.{ .key = .guns_up }, 100.1).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.{ .key = .guns_up }, 100.2).guns);
	try t.expectEqual(@as(?bool, null), c.handle(.tick, 200).guns);
}

test "quit is reported" {
	var c: Controller = .{};
	try t.expect(c.handle(.{ .key = .quit }, 1).quit);
}

test "pause stops firing, ignores fire and death, and freezes the resume deadline" {
	var c: Controller = .{};
	_ = c.handle(.{ .key = .death }, 0); // resume due at 8
	_ = c.handle(.{ .key = .guns_down }, 1);
	try t.expectEqual(@as(?bool, false), c.handle(.{ .key = .pause }, 2).guns);
	try t.expect(c.paused());
	try t.expectEqual(Effects{}, c.handle(.{ .key = .guns_down }, 3));
	try t.expectEqual(Effects{}, c.handle(.{ .key = .death }, 3));
	try t.expectEqual(Effects{}, c.handle(.tick, 20));
	try t.expectEqual(Effects{}, c.handle(.{ .key = .pause }, 30)); // resume after 28 paused seconds
	try t.expect(!c.paused());
	try t.expectEqual(@as(?u4, null), c.handle(.tick, 35).command);
	try t.expectEqual(@as(?u4, driving_command), c.handle(.tick, 36).command);
}

test "quit works while paused" {
	var c: Controller = .{};
	_ = c.handle(.{ .key = .pause }, 1);
	try t.expect(c.handle(.{ .key = .quit }, 2).quit);
}

test "a no-release tap lasts long enough for exactly the arcade's two shots" {
	// Measured with the owned ROM (press then stop after N ms): 1 burst below
	// 100 ms, 2 bursts from 100 to 180 ms, 3 from 190 ms. Peter's arcade tap
	// is the double "tsch-tsch"; aim for the middle of the 2-burst plateau.
	try t.expect(tap_seconds >= 0.12 and tap_seconds <= 0.16);
}
