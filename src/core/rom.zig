//! Ported from src/rom.lua to Zig on 2026-10-02 by Peter Marreck with
//! Claude Opus 5.5 (claude-opus-5-5).
//! Sound-ROM admission: pick exactly the seven sound-board members out of a
//! user-supplied spyhunt.zip (legacy or current MAME names), check sizes and
//! historical MAME SHA-1 identities, and build the board images
//! (interleaved 68000 words, concatenated Z80 ROMs, gain PROM).
const std = @import("std");
const zip = @import("zip.zig");

pub const Member = struct {
	name: []const u8,
	size: usize,
	sha1: *const [40]u8,
	alias: ?[]const u8 = null,
};

/// Order matters: four CSD 68000 ROMs, two SSIO Z80 ROMs, then the gain PROM.
pub const spy_hunter = [_]Member{
	.{ .name = "csd_u7a.u7", .size = 8192, .sha1 = "38ad2e9f12b9d389fb2568ebcb32c8bd1ac6879e", .alias = "spy-hunter_cs_deluxe_u7_a_11-18-83.u7" },
	.{ .name = "csd_u17b.u17", .size = 8192, .sha1 = "d955c0e67fc78b517cc229601ab4023cc5a644c2", .alias = "spy-hunter_cs_deluxe_u17_b_11-18-83.u17" },
	.{ .name = "csd_u8c.u8", .size = 8192, .sha1 = "5708d374dd56758194c95118f096ea51bf12bf64", .alias = "spy-hunter_cs_deluxe_u8_c_11-18-83.u8" },
	.{ .name = "csd_u18d.u18", .size = 8192, .sha1 = "5864a7e9b6bc3d2df6891d40965a7a0efbba6837", .alias = "spy-hunter_cs_deluxe_u18_d_11-18-83.u18" },
	.{ .name = "snd_0sd.a8", .size = 4096, .sha1 = "d1b0e299a27e306ddbc0654fd3a9d981c92afe8c", .alias = "spy-hunter_snd_0_sd_11-18-83.a7" },
	.{ .name = "snd_1sd.a7", .size = 4096, .sha1 = "c6b835fc45e4484a4d52b682ce015caa242c8b4f", .alias = "spy-hunter_snd_1_sd_11-18-83.a8" },
	.{ .name = "82s123.12d", .size = 32, .sha1 = "9ac9b01d24affc0ee9227a4364c4fd8f8290343a" },
};

pub const Images = struct {
	music: [32768]u8,
	effects: [8192]u8,
	prom: [32]u8,
};

pub const Reason = enum(c_int) { malformed_zip = 1, unsupported_zip, duplicate, missing, wrong_size, digest_mismatch, corrupt };

pub const Failure = struct { reason: Reason, member: ?[]const u8 = null };

/// Admit `archive` against `table` (seven members laid out like
/// `spy_hunter`). Returns null on success, else why and which member failed.
pub fn admit(table: *const [7]Member, archive: []const u8, images: *Images) ?Failure {
	var raw: [7][8192]u8 = undefined;
	for (table, 0..) |m, i| {
		const maybe = lookup(archive, m) catch |err| return .{ .reason = reasonFor(err), .member = m.name };
		const entry = maybe orelse return .{ .reason = .missing, .member = m.name };
		if (entry.size != m.size) return .{ .reason = .wrong_size, .member = m.name };
		const bytes = raw[i][0..m.size];
		zip.extract(entry, bytes) catch |err| return .{ .reason = reasonFor(err), .member = m.name };
		var digest: [20]u8 = undefined;
		std.crypto.hash.Sha1.hash(bytes, &digest, .{});
		if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), m.sha1)) return .{ .reason = .digest_mismatch, .member = m.name };
	}
	interleave(raw[0][0..8192], raw[1][0..8192], images.music[0..16384]);
	interleave(raw[2][0..8192], raw[3][0..8192], images.music[16384..]);
	@memcpy(images.effects[0..4096], raw[4][0..4096]);
	@memcpy(images.effects[4096..], raw[5][0..4096]);
	@memcpy(&images.prom, raw[6][0..32]);
	return null;
}

/// The canonical name wins; the current MAME alias is the fallback.
fn lookup(archive: []const u8, m: Member) zip.Error!?zip.Entry {
	if (try zip.find(archive, m.name)) |e| return e;
	return if (m.alias) |a| zip.find(archive, a) else null;
}

fn reasonFor(err: zip.Error) Reason {
	return switch (err) {
		error.Malformed => .malformed_zip,
		error.Unsupported => .unsupported_zip,
		error.Duplicate => .duplicate,
		error.TooLarge => .wrong_size,
		error.Corrupt => .corrupt,
	};
}

/// Interleave two 8-bit ROMs into big-endian 68000 words: a[0] b[0] a[1] b[1]...
pub fn interleave(even: []const u8, odd: []const u8, out: []u8) void {
	for (even, odd, 0..) |e, o, i| {
		out[2 * i] = e;
		out[2 * i + 1] = o;
	}
}

// ---- tests: synthetic members in an in-memory stored ZIP ----

const t = std.testing;

const TestFile = struct { name: []const u8, data: []const u8 };

/// Build a stored (method 0) ZIP so admission is tested without ROM bytes.
fn storedZip(gpa: std.mem.Allocator, files: []const TestFile) ![]u8 {
	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(gpa);
	var offsets: [16]u32 = undefined;
	for (files, 0..) |f, i| {
		offsets[i] = @intCast(out.items.len);
		try appendHeader(gpa, &out, 0x04034b50, f, null);
		try out.appendSlice(gpa, f.data);
	}
	const dir_at: u32 = @intCast(out.items.len);
	for (files, 0..) |f, i| try appendHeader(gpa, &out, 0x02014b50, f, offsets[i]);
	const dir_len: u32 = @intCast(out.items.len - dir_at);
	var eocd: [22]u8 = @splat(0);
	std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
	std.mem.writeInt(u16, eocd[8..10], @intCast(files.len), .little);
	std.mem.writeInt(u16, eocd[10..12], @intCast(files.len), .little);
	std.mem.writeInt(u32, eocd[12..16], dir_len, .little);
	std.mem.writeInt(u32, eocd[16..20], dir_at, .little);
	try out.appendSlice(gpa, &eocd);
	return out.toOwnedSlice(gpa);
}

fn appendHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), signature: u32, f: TestFile, local_offset: ?u32) !void {
	const central = local_offset != null;
	var h: [46]u8 = @splat(0);
	const base: usize = if (central) 2 else 0; // central headers add "version made by"
	std.mem.writeInt(u32, h[0..4], signature, .little);
	std.mem.writeInt(u32, h[base + 14 ..][0..4], std.hash.Crc32.hash(f.data), .little);
	std.mem.writeInt(u32, h[base + 18 ..][0..4], @intCast(f.data.len), .little);
	std.mem.writeInt(u32, h[base + 22 ..][0..4], @intCast(f.data.len), .little);
	std.mem.writeInt(u16, h[base + 26 ..][0..2], @intCast(f.name.len), .little);
	if (central) std.mem.writeInt(u32, h[42..46], local_offset.?, .little);
	try out.appendSlice(gpa, h[0..if (central) 46 else 30]);
	try out.appendSlice(gpa, f.name);
}

/// Seven synthetic members whose bytes encode their index, with a matching table.
const Synthetic = struct {
	data: [7][8192]u8,
	hex: [7][40]u8,
	table: [7]Member,

	fn init(self: *Synthetic) void {
		for (spy_hunter, 0..) |m, i| {
			for (self.data[i][0..m.size], 0..) |*b, j| b.* = @truncate(i * 31 + j);
			var digest: [20]u8 = undefined;
			std.crypto.hash.Sha1.hash(self.data[i][0..m.size], &digest, .{});
			self.hex[i] = std.fmt.bytesToHex(digest, .lower);
			self.table[i] = m;
			self.table[i].sha1 = &self.hex[i];
		}
	}

	fn file(self: *const Synthetic, i: usize, name: []const u8) TestFile {
		return .{ .name = name, .data = self.data[i][0..spy_hunter[i].size] };
	}

	fn files(self: *const Synthetic, out: *[7]TestFile) []const TestFile {
		for (0..7) |i| out[i] = self.file(i, spy_hunter[i].name);
		return out;
	}
};

test "admission builds interleaved music, concatenated effects and PROM" {
	var s: Synthetic = undefined;
	s.init();
	var fs: [7]TestFile = undefined;
	const z = try storedZip(t.allocator, s.files(&fs));
	defer t.allocator.free(z);
	var images: Images = undefined;
	try t.expectEqual(@as(?Failure, null), admit(&s.table, z, &images));
	// music: u7/u17 interleaved, then u8/u18 interleaved.
	try t.expectEqual(s.data[0][5], images.music[10]);
	try t.expectEqual(s.data[1][5], images.music[11]);
	try t.expectEqual(s.data[2][5], images.music[16384 + 10]);
	try t.expectEqual(s.data[3][5], images.music[16384 + 11]);
	try t.expectEqualSlices(u8, s.data[4][0..4096], images.effects[0..4096]);
	try t.expectEqualSlices(u8, s.data[5][0..4096], images.effects[4096..]);
	try t.expectEqualSlices(u8, s.data[6][0..32], &images.prom);
}

test "current MAME member names are accepted as aliases; unrelated members ignored" {
	var s: Synthetic = undefined;
	s.init();
	var fs: [8]TestFile = undefined;
	for (0..7) |i| fs[i] = s.file(i, spy_hunter[i].alias orelse spy_hunter[i].name);
	fs[7] = .{ .name = "vid_0fg.a8", .data = "graphics are never read" };
	const z = try storedZip(t.allocator, &fs);
	defer t.allocator.free(z);
	var images: Images = undefined;
	try t.expectEqual(@as(?Failure, null), admit(&s.table, z, &images));
}

test "each failure names its reason and member" {
	var s: Synthetic = undefined;
	s.init();
	var images: Images = undefined;
	var fs: [8]TestFile = undefined;

	_ = s.files(fs[0..7]);
	const missing = try storedZip(t.allocator, fs[0..6]); // no PROM
	defer t.allocator.free(missing);
	try t.expectEqual(Reason.missing, admit(&s.table, missing, &images).?.reason);
	try t.expectEqualStrings("82s123.12d", admit(&s.table, missing, &images).?.member.?);

	_ = s.files(fs[0..7]);
	fs[4].data = s.data[4][0..4095];
	const short = try storedZip(t.allocator, fs[0..7]);
	defer t.allocator.free(short);
	try t.expectEqual(Failure{ .reason = .wrong_size, .member = "snd_0sd.a8" }, normalize(admit(&s.table, short, &images)));

	_ = s.files(fs[0..7]);
	fs[1].data = s.data[0][0..8192]; // right size, wrong bytes
	const wrong = try storedZip(t.allocator, fs[0..7]);
	defer t.allocator.free(wrong);
	try t.expectEqual(Failure{ .reason = .digest_mismatch, .member = "csd_u17b.u17" }, normalize(admit(&s.table, wrong, &images)));

	_ = s.files(fs[0..7]);
	fs[7] = s.file(0, "csd_u7a.u7");
	const dup = try storedZip(t.allocator, &fs);
	defer t.allocator.free(dup);
	try t.expectEqual(Failure{ .reason = .duplicate, .member = "csd_u7a.u7" }, normalize(admit(&s.table, dup, &images)));

	try t.expectEqual(Reason.malformed_zip, admit(&s.table, "not a ZIP", &images).?.reason);
}

test "the canonical name wins over its alias when both are present" {
	var s: Synthetic = undefined;
	s.init();
	var fs: [8]TestFile = undefined;
	_ = s.files(fs[0..7]);
	fs[7] = .{ .name = spy_hunter[0].alias.?, .data = "decoy" };
	const z = try storedZip(t.allocator, &fs);
	defer t.allocator.free(z);
	var images: Images = undefined;
	try t.expectEqual(@as(?Failure, null), admit(&s.table, z, &images));
}

/// Compare member names by content in expectEqual.
fn normalize(f: ?Failure) Failure {
	const v = f.?;
	for (spy_hunter) |m| {
		if (v.member) |name| {
			if (std.mem.eql(u8, name, m.name)) return .{ .reason = v.reason, .member = m.name };
		}
	}
	return v;
}

test "real table digests are well-formed lowercase hex" {
	for (spy_hunter) |m| for (m.sha1) |c| try t.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}
