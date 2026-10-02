//! Sound-board wiring based on MAME's BSD-3-Clause csd.cpp/midway_sound.cpp.
//! CPU/synth cores are separately licensed Musashi and floooh/chips.
//! This adapter is MIT licensed. Single emulated machine per process.
//! Ported from src/native/sound.c to Zig on 2026-10-02 by Peter Marreck with
//! Claude Opus 5.5 (claude-opus-5-5).
//!
//! Music: 8 MHz 68000 (Cheap Squeak Deluxe) driving a 10-bit DAC through a
//! 6821 PIA whose CA1 edge raises the command IRQ. Effects: 2 MHz Z80 (SSIO)
//! with four command latches and two AY-3-8910s whose outputs are scaled by
//! a duty-cycle gain PROM. Musashi keeps CPU state in globals, so this board
//! is a process-wide singleton.
const std = @import("std");
const c = @import("cores");

pub const music_len = 32768;
pub const effects_len = 8192;
pub const prom_len = 32;
const music_hz = 8_000_000;
const effects_hz = 2_000_000;

var music: [music_len]u8 = undefined;
var effects: [16384]u8 = undefined;
var ram: [4096]u8 = undefined;
var zram: [1024]u8 = undefined;
var prom: [prom_len]u8 = undefined;
var pa: u8 = 0;
var pb: u8 = 0;
var ddra: u8 = 0;
var ddrb: u8 = 0;
var cra: u8 = 0;
var crb: u8 = 0;
var command_latch: u8 = 0;
var latches: [4]u8 = .{ 0, 0, 0, 0 };
var irq_a = false;
var ca1: u8 = 1;
var dac: i32 = 0;
var loaded = false;
var sample_rate: i32 = 48000;
var irq_count: u32 = 0;
var dac_writes: u64 = 0;
var zticks: u64 = 0;
var pins: u64 = 0;
var zcpu: c.z80_t = undefined;
var ay: [2]c.ay38910_t = undefined;
var music_debt: f64 = 0;
var effects_debt: f64 = 0;
var gain: [16]f32 = undefined;
var previous_dac: f32 = 0;
var dc: f32 = 0;

// ---- 68000 side: PIA and memory map ----

fn irqUpdate() void {
	c.m68k_set_irq(if (irq_a and cra & 1 != 0) 4 else 0);
}

fn ca1Set(level: u8) void {
	if (level != ca1 and level == (cra >> 1) & 1) irq_a = true;
	ca1 = level;
	irqUpdate();
}

fn dacUpdate() void {
	dac = (@as(i32, pa & ddra) << 2) | ((pb & ddrb) >> 6);
	dac_writes += 1;
}

fn piaRead(r: u32) u8 {
	switch (r) {
		0 => {
			if (cra & 4 == 0) return ddra;
			irq_a = false;
			irqUpdate();
			return pa;
		},
		1 => return if (crb & 4 != 0) (pb & ddrb) | (command_latch & ~ddrb) else ddrb,
		2 => return cra | @as(u8, if (irq_a) 0x80 else 0),
		else => return crb,
	}
}

fn piaWrite(r: u32, v: u8) void {
	switch (r) {
		0 => {
			if (cra & 4 != 0) pa = v else ddra = v;
			dacUpdate();
		},
		1 => {
			if (crb & 4 != 0) pb = v else ddrb = v;
			dacUpdate();
		},
		2 => {
			cra = v & 63;
			irqUpdate();
		},
		else => crb = v & 63,
	}
}

fn isPia(a: u32) bool {
	return a >= 0x18000 and a < 0x1c000;
}

fn isRam(a: u32) bool {
	return a >= 0x1c000 and a < 0x1d000;
}

export fn m68k_read_memory_8(address: c_uint) c_uint {
	const a = address & 0x1ffff;
	if (a < music_len) return music[a];
	if (isPia(a)) return piaRead((a & 6) >> 1);
	if (isRam(a)) return ram[a - 0x1c000];
	return 255;
}

export fn m68k_read_memory_16(a: c_uint) c_uint {
	return (m68k_read_memory_8(a) << 8) | m68k_read_memory_8(a +% 1);
}

export fn m68k_read_memory_32(a: c_uint) c_uint {
	return (m68k_read_memory_16(a) << 16) | m68k_read_memory_16(a +% 2);
}

export fn m68k_write_memory_8(address: c_uint, v: c_uint) void {
	const a = address & 0x1ffff;
	if (isPia(a)) piaWrite((a & 6) >> 1, @truncate(v));
	if (isRam(a)) ram[a - 0x1c000] = @truncate(v);
}

export fn m68k_write_memory_16(a: c_uint, v: c_uint) void {
	if (isPia(a & 0x1ffff)) {
		piaWrite((a & 6) >> 1, @truncate(v >> 8));
	} else {
		m68k_write_memory_8(a, v >> 8);
		m68k_write_memory_8(a +% 1, v);
	}
}

export fn m68k_write_memory_32(a: c_uint, v: c_uint) void {
	m68k_write_memory_16(a, v >> 16);
	m68k_write_memory_16(a +% 2, v);
}

export fn m68k_read_disassembler_8(a: c_uint) c_uint {
	return m68k_read_memory_8(a);
}

export fn m68k_read_disassembler_16(a: c_uint) c_uint {
	return m68k_read_memory_16(a);
}

export fn m68k_read_disassembler_32(a: c_uint) c_uint {
	return m68k_read_memory_32(a);
}

// ---- Z80 side: SSIO latches, RAM and AY chips ----

const z80_m1: u64 = 1 << c.Z80_PIN_M1;
const z80_mreq: u64 = 1 << c.Z80_PIN_MREQ;
const z80_iorq: u64 = 1 << c.Z80_PIN_IORQ;
const z80_rd: u64 = 1 << c.Z80_PIN_RD;
const z80_wr: u64 = 1 << c.Z80_PIN_WR;
const z80_int: u64 = 1 << c.Z80_PIN_INT;
const ay_bdir: u64 = 1 << c.AY38910_PIN_BDIR;
const ay_bc1: u64 = 1 << c.AY38910_PIN_BC1;
const data_mask: u64 = 0xff0000;

fn setData(p: u64, d: u8) u64 {
	return (p & ~data_mask) | (@as(u64, d) << 16);
}

fn getData(p: u64) u8 {
	return @truncate(p >> 16);
}

fn zread(a: u16) u8 {
	if (a < 0x4000) return effects[a];
	if (a >= 0x8000 and a < 0x9000) return zram[a & 1023];
	if (a >= 0x9000 and a < 0xa000) return latches[a & 3];
	if (a & 0xf003 == 0xa001 or a & 0xf003 == 0xb001) {
		return getData(c.ay38910_iorq(&ay[(a >> 12) - 10], ay_bc1));
	}
	if (a >= 0xe000 and a < 0xf000) {
		irq_count = 0;
		pins &= ~z80_int;
	}
	return 255;
}

fn zwrite(a: u16, v: u8) void {
	if (a >= 0x8000 and a < 0x9000) zram[a & 1023] = v;
	if (a >> 12 == 10 or a >> 12 == 11) {
		var p: u64 = ay_bdir;
		if (a & 3 == 0) {
			p |= ay_bc1;
		} else if (a & 3 != 2) return;
		_ = c.ay38910_iorq(&ay[(a >> 12) - 10], setData(p, v));
	}
}

/// SSIO effects mix: each AY channel's on/off output times its volume, scaled
/// by the PROM-derived duty-cycle gain; AY 1 port B bit 7 mutes everything.
fn effectSample() f32 {
	var sum: f32 = 0;
	if (ay[1].unnamed_0.reg[15] & 128 != 0) return 0;
	for (&ay) |*chip| for (0..3) |ch| {
		const reg = &chip.unnamed_0.reg;
		const tone = &chip.tone[ch];
		const duty = if (ch < 2) (reg[14] >> @intCast(4 * ch)) & 15 else reg[15] & 15;
		const volume = if (reg[8 + ch] & 16 != 0) chip.env.shape_state else reg[8 + ch] & 15;
		if ((tone.bit | tone.tone_disable) & ((chip.noise.rng & 1) | tone.noise_disable) != 0)
			sum += c.sh_ay_volume(volume) * gain[duty];
	};
	return sum / 6.0;
}

// ---- public board API ----

pub fn reset() void {
	@memset(&ram, 0);
	@memset(&zram, 0);
	latches = .{ 0, 0, 0, 0 };
	pa = 0;
	pb = 0;
	ddra = 0;
	ddrb = 0;
	cra = 0;
	crb = 0;
	command_latch = 0;
	pending_command = null;
	irq_a = false;
	ca1 = 1;
	dac = 0;
	dac_writes = 0;
	zticks = 0;
	irq_count = 0;
	music_debt = 0;
	effects_debt = 0;
	previous_dac = 0;
	dc = 0;
	c.m68k_init();
	c.m68k_set_cpu_type(c.M68K_CPU_TYPE_68000);
	c.m68k_pulse_reset();
	pins = c.z80_init(&zcpu);
	for (&ay) |*chip| {
		const desc: c.ay38910_desc_t = .{ .type = c.AY38910_TYPE_8910, .tick_hz = effects_hz, .sound_hz = sample_rate, .magnitude = 1.0 };
		c.ay38910_init(chip, &desc);
	}
}

/// Load raw board images and reset. The gain table converts each 4-bit duty
/// value into the fraction of a 160-clock PROM cycle before its Nth falling edge.
pub fn load(m: []const u8, e: []const u8, p: []const u8) error{InvalidImage}!void {
	if (m.len != music_len or e.len != effects_len or p.len != prom_len) return error.InvalidImage;
	@memcpy(&music, m);
	@memset(&effects, 255);
	@memcpy(effects[0..effects_len], e);
	@memcpy(&prom, p);
	for (0..16) |v| {
		var remain = v;
		var prev = true;
		var clock: u32 = 0;
		while (clock < 160 and remain != 0) : (clock += 1) {
			const cur = prom[clock / 8] & (@as(u8, 0x80) >> @intCast(clock % 8)) != 0;
			if (!cur and prev) remain -= 1;
			prev = cur;
		}
		gain[15 - v] = @as(f32, @floatFromInt(clock)) / 160.0;
	}
	sample_rate = 48000;
	loaded = true;
	reset();
}

/// Send a four-bit music command. If the previous command's IRQ has not yet
/// been acknowledged, hold this one (latest wins) until it is: overwriting
/// the latch first would merge both into one IRQ, and the ROM ignores death
/// unless driving was processed. The game itself sends at most once a frame.
pub fn command(v: u32) void {
	const value: u8 = @truncate(v & 15);
	if (irq_a) {
		pending_command = value;
		return;
	}
	latchCommand(value);
}

fn latchCommand(value: u8) void {
	command_latch = value;
	ca1Set(0);
	ca1Set(1);
}

var pending_command: ?u8 = null;

fn deliverPendingCommand() void {
	if (irq_a) return;
	if (pending_command) |value| {
		pending_command = null;
		latchCommand(value);
	}
}

/// Write one of the four SSIO effects latches.
pub fn effect(latch: u32, value: u8) void {
	if (latch < 4) latches[latch] = value;
}

/// Render mono samples, advancing both CPUs and the AYs in lockstep.
pub fn render(out: []f32, rate: i32) error{ NotLoaded, InvalidRate }!void {
	if (!loaded) return error.NotLoaded;
	if (rate < 8000 or rate > 192000) return error.InvalidRate;
	if (rate != sample_rate) {
		sample_rate = rate;
		for (&ay) |*chip| {
			chip.sample_period = @divTrunc(effects_hz * c.AY38910_FIXEDPOINT_SCALE, rate);
			chip.sample_counter = chip.sample_period;
		}
	}
	const rate_f: f64 = @floatFromInt(rate);
	for (out) |*sample| {
		music_debt += music_hz / rate_f;
		if (music_debt >= 1) music_debt -= @floatFromInt(c.m68k_execute(@intFromFloat(music_debt)));
		deliverPendingCommand();
		effects_debt += effects_hz / rate_f;
		while (effects_debt >= 1) {
			effects_debt -= 1;
			pins = c.z80_tick(&zcpu, pins);
			if (pins & z80_mreq != 0) {
				const a: u16 = @truncate(pins);
				if (pins & z80_rd != 0) {
					// zread may clear Z80_INT in `pins`; read before merging the data.
					const data = zread(a);
					pins = setData(pins, data);
				} else if (pins & z80_wr != 0) zwrite(a, getData(pins));
			} else if (pins & (z80_iorq | z80_m1) == (z80_iorq | z80_m1)) pins = setData(pins, 255);
			zticks += 1;
			if (zticks % 40 == 0) {
				irq_count = (irq_count + 1) & 127;
				if (irq_count & 63 == 0) {
					if (irq_count & 64 != 0) pins |= z80_int else pins &= ~z80_int;
				}
			}
			_ = c.ay38910_tick(&ay[0]);
			_ = c.ay38910_tick(&ay[1]);
		}
		const x = @as(f32, @floatFromInt(dac - 512)) / 512.0;
		// Block the DAC's DC offset, as a physical AC-coupled speaker does.
		dc = x - previous_dac + 0.995 * dc;
		previous_dac = x;
		sample.* = 0.65 * dc + 0.35 * effectSample();
	}
}

// ---- probes for tests and inspection ----

pub fn read(a: u32) u8 {
	return @truncate(m68k_read_memory_8(a));
}

pub fn write(a: u32, v: u8) void {
	m68k_write_memory_8(a, v);
}

pub fn zread_probe(a: u16) u8 {
	return zread(a);
}

pub fn pc() u32 {
	return c.m68k_get_reg(null, c.M68K_REG_PC);
}

pub fn zpc() u16 {
	return zcpu.unnamed_0.pc;
}

pub fn ayRegister(chip: usize, reg: usize) u8 {
	return if (chip < 2 and reg < 16) ay[chip].unnamed_0.reg[reg] else 0;
}

pub fn dacWrites() u64 {
	return dac_writes;
}

// ---- tests: synthetic programs, no copyrighted ROM needed ----

const t = std.testing;

/// 68000 reset vectors (SSP=0x1cffc? via bytes 1..3, PC=8) and BRA.S to itself.
pub fn syntheticMusic() [music_len]u8 {
	var rom: [music_len]u8 = @splat(0);
	rom[1] = 1;
	rom[2] = 0xcf;
	rom[3] = 0xfc;
	rom[7] = 8;
	rom[8] = 0x60;
	rom[9] = 0xfe;
	return rom;
}

test "load rejects wrong image sizes" {
	const rom = syntheticMusic();
	var e: [effects_len]u8 = @splat(0);
	const p: [prom_len]u8 = @splat(0);
	try t.expectError(error.InvalidImage, load(rom[0..100], &e, &p));
	try t.expectError(error.InvalidImage, load(&rom, e[0..10], &p));
	try t.expectError(error.InvalidImage, load(&rom, &e, p[0..1]));
}

test "68000 RAM writes persist until reset; render validates its arguments" {
	const rom = syntheticMusic();
	const e: [effects_len]u8 = @splat(0);
	const p: [prom_len]u8 = @splat(0);
	try load(&rom, &e, &p);
	write(0x1c010, 0x42);
	try t.expectEqual(@as(u8, 0x42), read(0x1c010));
	reset();
	try t.expectEqual(@as(u8, 0), read(0x1c010));
	var out: [64]f32 = undefined;
	try render(&out, 48000);
	try t.expectError(error.InvalidRate, render(&out, 0));
	try t.expectEqual(@as(u32, 8), pc());
}

test "Z80 clears each IRQ in its ISR: 7 or 8 interrupts in 10 ms" {
	// An IRQ-clear side effect lost inside a data-bus macro once caused an
	// interrupt storm (235 IRQs); the timer divides 2 MHz by 40*64.
	const rom = syntheticMusic();
	var e: [effects_len]u8 = @splat(0);
	const p: [prom_len]u8 = @splat(0);
	const boot = [_]u8{ 0x31, 0xff, 0x83, 0xed, 0x56, 0xfb, 0x76, 0xc3, 6, 0 };
	const isr = [_]u8{ 0x3a, 0, 0xe0, 0x3a, 0, 0x80, 0x3c, 0x32, 0, 0x80, 0xfb, 0xed, 0x4d };
	@memcpy(e[0..boot.len], &boot);
	@memcpy(e[0x38..][0..isr.len], &isr);
	try load(&rom, &e, &p);
	var out: [480]f32 = undefined;
	try render(&out, 48000);
	const irqs = zread_probe(0x8000);
	try t.expect(irqs >= 7 and irqs <= 8);
}

/// Hand-assembled 68000 program: enables the PIA CA1 interrupt, then loops.
/// Its level-4 handler counts commands at RAM 0x1c000, stores the last one
/// read from port B at 0x1c001, then reads port A to acknowledge.
pub fn commandCounterMusic() [music_len]u8 {
	var rom = syntheticMusic();
	const main = [_]u8{
		0x13, 0xfc, 0x00, 0x05, 0x00, 0x01, 0x80, 0x04, // move.b #$05,$18004 (CRA: IRQ on, port access)
		0x13, 0xfc, 0x00, 0x04, 0x00, 0x01, 0x80, 0x06, // move.b #$04,$18006 (CRB: port access)
		0x46, 0xfc, 0x20, 0x00, // move.w #$2000,SR (interrupts on)
		0x60, 0xfe, // bra.s *
	};
	const handler = [_]u8{
		0x10, 0x39, 0x00, 0x01, 0x80, 0x02, // move.b $18002,D0 (command)
		0x52, 0x39, 0x00, 0x01, 0xc0, 0x00, // addq.b #1,$1c000
		0x13, 0xc0, 0x00, 0x01, 0xc0, 0x01, // move.b D0,$1c001
		0x10, 0x39, 0x00, 0x01, 0x80, 0x00, // move.b $18000,D0 (acknowledge)
		0x4e, 0x73, // rte
	};
	@memcpy(rom[8..][0..main.len], &main);
	rom[0x70 + 2] = 0x01; // level-4 autovector -> 0x100
	@memcpy(rom[0x100..][0..handler.len], &handler);
	return rom;
}

test "back-to-back commands are each delivered once the previous one is acknowledged" {
	// The ROM ignores death (0) unless driving (1) was processed first; a
	// second command latched before the first IRQ is serviced was lost.
	const rom = commandCounterMusic();
	const e: [effects_len]u8 = @splat(0);
	const p: [prom_len]u8 = @splat(0);
	try load(&rom, &e, &p);
	var out: [480]f32 = undefined;
	try render(&out, 48000); // let the program enable interrupts
	command(1);
	command(0);
	try render(&out, 48000);
	try t.expectEqual(@as(u8, 2), read(0x1c000));
	try t.expectEqual(@as(u8, 0), read(0x1c001));
}
