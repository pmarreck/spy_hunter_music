//! C ABI (include/spy_hunter.h) over the board, ROM admission, controller
//! and WAV modules. Ported from src/engine.lua, src/session.lua and
//! src/render.lua to Zig on 2026-10-02 by Peter Marreck with Claude Opus 5.5
//! (claude-opus-5-5). Process-wide singleton, like the board beneath it.
const std = @import("std");
const board = @import("board.zig");
const rom = @import("rom.zig");
const wav = @import("wav.zig");
const keyboard = @import("keyboard.zig");
const controller = @import("controller.zig");
const terminal = @import("terminal.zig");
const tips = @import("tips.zig");

pub const tips_json: c_uint = 1;
pub const tips_color: c_uint = 2;

const ok: c_int = 0;
const err_argument: c_int = -1;
const err_not_loaded: c_int = -2;
const err_rate: c_int = -3;
const err_admission: c_int = -4;

pub const flag_quit: c_uint = 1;
pub const flag_kitty: c_uint = 2;
pub const flag_paused: c_uint = 4;
pub const flag_legacy: c_uint = 8;

pub const event_guns_down: c_int = 1;
pub const event_guns_up: c_int = 2;
pub const event_death: c_int = 3;
pub const event_pause: c_int = 4;

/// SSIO sound numbers from the game's sound-test table ("12 MACHINE GUNS").
pub const guns_start: u8 = 0x22;
pub const guns_stop: u8 = 0x23;
/// Board mix to output level: the previous player's fixed 4x master gain.
const master_gain: f64 = 4;

pub const Admission = extern struct {
	reason: c_int,
	member_len: usize,
	member: [64]u8,
};

const Session = struct {
	decoder: keyboard.Decoder = .{},
	control: controller.Controller = .{},
	strobe: u8 = 0,
	kitty: bool = false,
	legacy: bool = false,
	quit: bool = false,
};

var session: Session = .{};

export fn sh_admit_zip(zip_ptr: ?[*]const u8, zip_len: usize, result: ?*Admission) c_int {
	const zip = zip_ptr orelse return err_argument;
	var images: rom.Images = undefined;
	const failure = rom.admit(&rom.spy_hunter, zip[0..zip_len], &images);
	if (result) |r| {
		r.* = .{ .reason = 0, .member_len = 0, .member = @splat(0) };
		if (failure) |f| {
			r.reason = @intFromEnum(f.reason);
			const name = f.member orelse "";
			r.member_len = @min(name.len, r.member.len);
			@memcpy(r.member[0..r.member_len], name[0..r.member_len]);
		}
	}
	if (failure != null) return err_admission;
	board.load(&images.music, &images.effects, &images.prom) catch unreachable;
	session = .{};
	return ok;
}

pub export fn sh_load_images(m: ?[*]const u8, ml: usize, e: ?[*]const u8, el: usize, p: ?[*]const u8, pl: usize) c_int {
	board.load((m orelse return err_argument)[0..ml], (e orelse return err_argument)[0..el], (p orelse return err_argument)[0..pl]) catch return err_argument;
	session = .{};
	return ok;
}

fn renderStatus(err: anyerror) c_int {
	return switch (err) {
		error.NotLoaded => err_not_loaded,
		error.InvalidRate => err_rate,
		else => err_argument,
	};
}

/// Execute the ROM's checks and startup delays without sending them to
/// speakers: the SSIO host's four-latch self-test handshake, ~3.5 s of
/// startup, the intro command, then driving music. A different initial
/// command is queued behind driving (the ROM only accepts death while
/// driving) rather than repeating or replacing it.
export fn sh_boot(rate: c_int, initial_command: c_uint) c_int {
	var scratch: [4800]f32 = undefined;
	for ([_]u8{ 0, 255, 85, 170, 0 }) |value| {
		for (0..4) |latch| board.effect(@intCast(latch), value);
		board.render(&scratch, rate) catch |err| return renderStatus(err);
	}
	for (0..35) |_| board.render(&scratch, rate) catch |err| return renderStatus(err);
	board.command(2);
	board.render(scratch[0..480], rate) catch |err| return renderStatus(err);
	board.command(controller.driving_command);
	if (initial_command & 15 != controller.driving_command) board.command(initial_command);
	return ok;
}

export fn sh_command(command: c_uint) void {
	board.command(command);
}

export fn sh_render(out: ?[*]f32, count: usize, rate: c_int) c_int {
	const samples = (out orelse return err_argument)[0..count];
	if (session.control.paused()) {
		if (rate < 8000 or rate > 192000) return err_rate;
		@memset(samples, 0);
		return ok;
	}
	board.render(samples, rate) catch |err| return renderStatus(err);
	return ok;
}

fn flags() c_uint {
	var f: c_uint = 0;
	if (session.quit) f |= flag_quit;
	if (session.kitty) f |= flag_kitty;
	if (session.control.paused()) f |= flag_paused;
	if (session.legacy) f |= flag_legacy;
	return f;
}

fn apply(fx: controller.Effects) void {
	if (fx.quit) session.quit = true;
	if (fx.command) |command| board.command(command);
	if (fx.guns) |on| {
		board.effect(1, if (on) guns_start else guns_stop);
		board.effect(2, 0);
		board.effect(3, 0);
		session.strobe = 128 - session.strobe;
		board.effect(0, session.strobe);
	}
}

export fn sh_key_byte(byte: u8, now: f64) c_uint {
	if (session.decoder.feed(byte)) |key| {
		// Only real key events reveal the key mode: a multiplexer can answer
		// the `CSI ? u` query yet still forward plain bytes.
		const event = keyboard.classify(key);
		switch (key) {
			.kitty => session.kitty = true,
			.byte => if (event == .guns_tap) {
				session.legacy = true;
			},
			.kitty_flags => {},
		}
		if (event) |e| apply(session.control.handle(.{ .key = e }, now));
	}
	return flags();
}

export fn sh_event(event: c_int, now: f64) c_uint {
	const key: keyboard.Event = switch (event) {
		event_guns_down => .guns_down,
		event_guns_up => .guns_up,
		event_death => .death,
		event_pause => .pause,
		else => return flags(),
	};
	apply(session.control.handle(.{ .key = key }, now));
	return flags();
}

export fn sh_tick(now: f64) c_uint {
	apply(session.control.handle(.tick, now));
	return flags();
}

export fn sh_session_reset() void {
	session = .{};
}

fn gained(sample: f32, volume: f64) f64 {
	return std.math.clamp(@as(f64, sample) * volume * master_gain, -1, 1);
}

export fn sh_apply_gain(samples: ?[*]f32, count: usize, volume: f64) void {
	for ((samples orelse return)[0..count]) |*s| s.* = @floatCast(gained(s.*, volume));
}

export fn sh_pcm16(samples: ?[*]const f32, count: usize, volume: f64, out: ?[*]u8, sum_squares: ?*f64, peak: ?*f64) void {
	const in = (samples orelse return)[0..count];
	const pcm = (out orelse return)[0 .. 2 * count];
	for (in, 0..) |s, i| {
		const v = gained(s, volume);
		pcm[2 * i ..][0..2].* = wav.sample(v);
		if (sum_squares) |sum| sum.* += v * v;
		if (peak) |p| p.* = @max(p.*, @abs(v));
	}
}

export fn sh_wav_header(out: ?[*]u8, out_len: usize, rate: u32, samples: u64) c_int {
	if (out_len < wav.header_len) return err_argument;
	wav.header((out orelse return err_argument)[0..wav.header_len], rate, samples) catch return err_argument;
	return ok;
}

fn span(ptr: ?[*]const u8, len: usize) []const u8 {
	return if (ptr) |p| p[0..len] else "";
}

/// Can key releases reach the player? `env` is NUL-separated KEY=VALUE
/// entries; `reply` is what the terminal sent back to terminal_probe().
export fn sh_key_release_verdict(env: ?[*]const u8, env_len: usize, reply: ?[*]const u8, reply_len: usize, probed: c_int) c_int {
	return @intFromEnum(terminal.detect(span(env, env_len), span(reply, reply_len), probed != 0).verdict);
}

/// Render `--tips` text (or JSON) for this terminal setup into `out`.
/// Returns the full length; at most `out_cap` bytes are written.
export fn sh_terminal_tips(env: ?[*]const u8, env_len: usize, reply: ?[*]const u8, reply_len: usize, probed: c_int, options: c_uint, out: ?[*]u8, out_cap: usize) usize {
	const d = terminal.detect(span(env, env_len), span(reply, reply_len), probed != 0);
	const opts: tips.Options = .{ .json = options & tips_json != 0, .color = options & tips_color != 0 };
	var discard_buf: [256]u8 = undefined;
	var counter: std.Io.Writer.Discarding = .init(&discard_buf);
	tips.render(d, opts, &counter.writer) catch return 0;
	counter.writer.flush() catch return 0;
	const total: usize = @intCast(counter.fullCount());
	if (out) |o| {
		var w: std.Io.Writer = .fixed(o[0..out_cap]);
		tips.render(d, opts, &w) catch {}; // a short buffer truncates
	}
	return total;
}

export fn sh_pc() u32 {
	return board.pc();
}

export fn sh_zpc() u32 {
	return board.zpc();
}

export fn sh_dac_writes() u64 {
	return board.dacWrites();
}

export fn sh_ay_register(chip: c_uint, reg: c_uint) u8 {
	return board.ayRegister(chip, reg);
}

export fn sh_latch(latch: c_uint) u8 {
	return if (latch < 4) board.zread_probe(@intCast(0x9000 + latch)) else 0;
}

// ---- tests ----

const t = std.testing;

fn loadSynthetic() !void {
	var m: [board.music_len]u8 = @splat(0);
	m[1] = 1;
	m[2] = 0xcf;
	m[3] = 0xfc;
	m[7] = 8;
	m[8] = 0x60;
	m[9] = 0xfe;
	const e: [board.effects_len]u8 = @splat(0);
	const p: [board.prom_len]u8 = @splat(0);
	try t.expectEqual(ok, sh_load_images(&m, m.len, &e, e.len, &p, p.len));
	sh_session_reset();
}

fn feed(bytes: []const u8, now: f64) c_uint {
	var result: c_uint = 0;
	for (bytes) |b| result = sh_key_byte(b, now);
	return result;
}

test "load and render validate pointers, lengths and rate" {
	try t.expectEqual(err_argument, sh_load_images(null, 0, null, 0, null, 0));
	try loadSynthetic();
	var out: [16]f32 = undefined;
	try t.expectEqual(ok, sh_render(&out, out.len, 48000));
	try t.expectEqual(err_argument, sh_render(null, 16, 48000));
	try t.expectEqual(err_rate, sh_render(&out, out.len, 7999));
}

test "a malformed ZIP reports its reason without loading" {
	var result: Admission = undefined;
	try t.expectEqual(err_admission, sh_admit_zip("not a ZIP", 9, &result));
	try t.expectEqual(@as(c_int, @intFromEnum(rom.Reason.malformed_zip)), result.reason);
	try t.expectEqualStrings("csd_u7a.u7", result.member[0..result.member_len]);
	try t.expectEqual(err_argument, sh_admit_zip(null, 1, &result));
}

test "space starts machine guns on latch 1 and toggles the latch 0 strobe" {
	try loadSynthetic();
	_ = feed(" ", 1);
	try t.expectEqual(guns_start, sh_latch(1));
	try t.expectEqual(@as(u8, 0), sh_latch(2));
	try t.expectEqual(@as(u8, 128), sh_latch(0));
	_ = sh_tick(1 + controller.tap_seconds);
	try t.expectEqual(guns_stop, sh_latch(1));
	try t.expectEqual(@as(u8, 0), sh_latch(0));
}

test "kitty release stops the guns and reports kitty mode" {
	try loadSynthetic();
	try t.expectEqual(flag_kitty, feed("\x1b[32u", 1) & flag_kitty);
	try t.expectEqual(guns_start, sh_latch(1));
	_ = sh_tick(50);
	try t.expectEqual(guns_start, sh_latch(1));
	_ = feed("\x1b[32;1:3u", 50.1);
	try t.expectEqual(guns_stop, sh_latch(1));
}

test "browser events drive the same controller" {
	try loadSynthetic();
	_ = sh_event(event_guns_down, 1);
	try t.expectEqual(guns_start, sh_latch(1));
	_ = sh_event(event_guns_up, 2);
	try t.expectEqual(guns_stop, sh_latch(1));
	try t.expectEqual(flag_paused, sh_event(event_pause, 3) & flag_paused);
	try t.expectEqual(@as(c_uint, 0), sh_event(event_pause, 4) & flag_paused);
	try t.expectEqual(@as(c_uint, 0), sh_event(99, 5));
}

test "quit keys set the quit flag" {
	try loadSynthetic();
	try t.expectEqual(flag_quit, feed("q", 1) & flag_quit);
}

test "pause renders silence without advancing emulation" {
	try loadSynthetic();
	var out: [480]f32 = undefined;
	try t.expectEqual(ok, sh_render(&out, out.len, 48000));
	_ = feed("p", 1);
	const before = sh_dac_writes();
	@memset(&out, 1);
	try t.expectEqual(ok, sh_render(&out, out.len, 48000));
	for (out) |s| try t.expectEqual(@as(f32, 0), s);
	try t.expectEqual(before, sh_dac_writes());
	_ = feed("p", 2);
}

test "gain and PCM conversion share the 4x master gain and clamp" {
	var buf = [_]f32{ 0.1, -0.5, 0.0, 0.3 };
	var pcm: [8]u8 = undefined;
	var sum: f64 = 0;
	var peak: f64 = 0;
	sh_pcm16(&buf, buf.len, 1, &pcm, &sum, &peak);
	try t.expectEqualSlices(u8, &wav.sample(@as(f64, @as(f32, 0.1)) * 4), pcm[0..2]);
	try t.expectEqualSlices(u8, "\x00\x80", pcm[2..4]);
	try t.expectEqual(@as(f64, 1), peak);
	sh_apply_gain(&buf, buf.len, 0.5);
	try t.expectEqual(@as(f32, @floatCast(@as(f64, @as(f32, 0.1)) * 0.5 * 4)), buf[0]);
	try t.expectEqual(@as(f32, -1), buf[1]);
}

test "WAV header requires room for 44 bytes" {
	var h: [44]u8 = undefined;
	try t.expectEqual(ok, sh_wav_header(&h, h.len, 48000, 3));
	try t.expectEqualSlices(u8, "RIFF", h[0..4]);
	try t.expectEqual(err_argument, sh_wav_header(&h, 43, 48000, 3));
}

test "only real key events decide the key mode; a query reply proves nothing" {
	// Herdr answered `CSI ? u` with nonzero flags yet forwarded plain spaces.
	try loadSynthetic();
	try t.expectEqual(@as(c_uint, 0), feed("\x1b[?11u", 1) & (flag_kitty | flag_legacy));
	try t.expectEqual(flag_legacy, feed(" ", 2) & (flag_kitty | flag_legacy));
	try loadSynthetic();
	try t.expectEqual(flag_kitty, feed("\x1b[32u", 3) & (flag_kitty | flag_legacy));
}

fn bootCounter(initial: c_uint) !void {
	const m = board.commandCounterMusic();
	const e: [board.effects_len]u8 = @splat(0);
	const p: [board.prom_len]u8 = @splat(0);
	try t.expectEqual(ok, sh_load_images(&m, m.len, &e, e.len, &p, p.len));
	try t.expectEqual(ok, sh_boot(48000, initial));
	var out: [480]f32 = undefined;
	try t.expectEqual(ok, sh_render(&out, out.len, 48000));
}

test "boot ends on driving music without repeating it" {
	try bootCounter(1);
	try t.expectEqual(@as(u8, 2), board.read(0x1c000)); // intro, driving
	try t.expectEqual(@as(u8, 1), board.read(0x1c001));
}

test "boot delivers another initial command after driving, never merged with it" {
	try bootCounter(0);
	try t.expectEqual(@as(u8, 3), board.read(0x1c000)); // intro, driving, death
	try t.expectEqual(@as(u8, 0), board.read(0x1c001));
}

test "key-release verdict over the C ABI" {
	const env = "TERM_PROGRAM=WezTerm\x00";
	const kitty = "\x1b[?11u\x1b[?62c";
	const plain = "\x1b[?62c";
	try t.expectEqual(@as(c_int, 1), sh_key_release_verdict(env, env.len, kitty, kitty.len, 1));
	try t.expectEqual(@as(c_int, 2), sh_key_release_verdict(env, env.len, plain, plain.len, 1));
	try t.expectEqual(@as(c_int, 0), sh_key_release_verdict(env, env.len, null, 0, 0));
	try t.expectEqual(@as(c_int, 0), sh_key_release_verdict(null, 0, null, 0, 0));
}

test "terminal tips over the C ABI report their full length and truncate safely" {
	const env = "TERM_PROGRAM=WezTerm\x00";
	const plain = "\x1b[?62c";
	var out: [4096]u8 = undefined;
	const n = sh_terminal_tips(env, env.len, plain, plain.len, 1, 0, &out, out.len);
	try t.expect(n > 0 and n < out.len);
	try t.expect(std.mem.indexOf(u8, out[0..n], "enable_kitty_keyboard") != null);
	var small: [10]u8 = @splat(0xaa);
	try t.expectEqual(n, sh_terminal_tips(env, env.len, plain, plain.len, 1, 0, &small, small.len));
	try t.expectEqualSlices(u8, out[0..10], &small);
	try t.expectEqual(n, sh_terminal_tips(env, env.len, plain, plain.len, 1, 0, null, 0));
	const json = sh_terminal_tips(env, env.len, plain, plain.len, 1, tips_json, &out, out.len);
	try t.expect(out[0] == '{' and out[json - 2] == '}');
}
