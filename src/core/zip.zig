//! Replaces the libarchive adapter (src/archive.lua) on 2026-10-02; written by
//! Peter Marreck with Claude Opus 5.5 (claude-opus-5-5).
//! In-memory ZIP member extraction: locate the end-of-central-directory
//! record, look members up by exact name in the central directory, then
//! inflate (method 8) or copy (method 0) and verify CRC-32. Bounds-checked
//! against hostile archives; ZIP64 and encryption are rejected.
const std = @import("std");

pub const Error = error{ Malformed, Unsupported, Duplicate, TooLarge, Corrupt };

pub const Entry = struct {
	method: u16,
	crc32: u32,
	compressed: []const u8,
	size: u32,
};

const eocd_signature: u32 = 0x06054b50;
const central_signature: u32 = 0x02014b50;
const local_signature: u32 = 0x04034b50;
const eocd_len = 22;
const central_len = 46;
const local_len = 30;
const max_comment = 0xffff;

fn read16(bytes: []const u8, at: usize) Error!u16 {
	if (at > bytes.len or bytes.len - at < 2) return error.Malformed;
	return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn read32(bytes: []const u8, at: usize) Error!u32 {
	if (at > bytes.len or bytes.len - at < 4) return error.Malformed;
	return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn slice(bytes: []const u8, at: usize, len: usize) Error![]const u8 {
	if (at > bytes.len or bytes.len - at < len) return error.Malformed;
	return bytes[at..][0..len];
}

/// Locate the end-of-central-directory record by scanning back over the
/// maximum comment length; its comment must end exactly at the archive end.
fn findEocd(archive: []const u8) Error!usize {
	if (archive.len < eocd_len) return error.Malformed;
	var at = archive.len - eocd_len;
	const lowest = archive.len -| (eocd_len + max_comment);
	while (true) : (at -= 1) {
		if (try read32(archive, at) == eocd_signature and
			at + eocd_len + try read16(archive, at + 20) == archive.len) return at;
		if (at == lowest) return error.Malformed;
	}
}

/// Find the single member named `name`. Returns null if absent and
/// error.Duplicate if the central directory lists it twice.
pub fn find(archive: []const u8, name: []const u8) Error!?Entry {
	const eocd = try findEocd(archive);
	if (try read16(archive, eocd + 4) != 0 or try read16(archive, eocd + 6) != 0) return error.Unsupported; // multi-disk
	const count = try read16(archive, eocd + 10);
	const dir_size = try read32(archive, eocd + 12);
	const dir_offset = try read32(archive, eocd + 16);
	if (dir_offset == 0xffff_ffff or count == 0xffff) return error.Unsupported; // ZIP64
	const directory = try slice(archive, dir_offset, dir_size);
	if (@as(usize, dir_offset) + dir_size > eocd) return error.Malformed;
	var found: ?Entry = null;
	var at: usize = 0;
	for (0..count) |_| {
		if (try read32(directory, at) != central_signature) return error.Malformed;
		const flags = try read16(directory, at + 8);
		const method = try read16(directory, at + 10);
		const crc = try read32(directory, at + 16);
		const compressed_size = try read32(directory, at + 20);
		const size = try read32(directory, at + 24);
		const name_len = try read16(directory, at + 28);
		const extra_len = try read16(directory, at + 30);
		const comment_len = try read16(directory, at + 32);
		const local_offset = try read32(directory, at + 42);
		const entry_name = try slice(directory, at + central_len, name_len);
		at += central_len + @as(usize, name_len) + extra_len + comment_len;
		if (!std.mem.eql(u8, entry_name, name)) continue;
		if (found != null) return error.Duplicate;
		if (flags & 1 != 0) return error.Unsupported; // encrypted
		if (method != 0 and method != 8) return error.Unsupported;
		if (size == 0xffff_ffff or compressed_size == 0xffff_ffff or local_offset == 0xffff_ffff) return error.Unsupported;
		if (try read32(archive, local_offset) != local_signature) return error.Malformed;
		const local_name = try read16(archive, local_offset + 26);
		const local_extra = try read16(archive, local_offset + 28);
		const data_at = @as(usize, local_offset) + local_len + local_name + local_extra;
		found = .{
			.method = method,
			.crc32 = crc,
			.compressed = try slice(archive, data_at, compressed_size),
			.size = size,
		};
	}
	return found;
}

/// Decompress `entry` into `out`, whose length must equal `entry.size`.
pub fn extract(entry: Entry, out: []u8) Error!void {
	if (out.len != entry.size) return error.Corrupt;
	switch (entry.method) {
		0 => {
			if (entry.compressed.len != out.len) return error.Corrupt;
			@memcpy(out, entry.compressed);
		},
		8 => {
			var input: std.Io.Reader = .fixed(entry.compressed);
			var window: [std.compress.flate.max_window_len]u8 = undefined;
			var inflate: std.compress.flate.Decompress = .init(&input, .raw, &window);
			inflate.reader.readSliceAll(out) catch return error.Corrupt;
			// Exactly `size` bytes: anything more is corruption, not padding.
			var extra: [1]u8 = undefined;
			if ((inflate.reader.readSliceShort(&extra) catch return error.Corrupt) != 0) return error.Corrupt;
		},
		else => return error.Unsupported,
	}
	if (std.hash.Crc32.hash(out) != entry.crc32) return error.Corrupt;
}

const t = std.testing;
const fixtures = @import("fixtures");

fn expectFixtureMember(archive: []const u8, method: u16) !void {
	const entry = (try find(archive, "csd_u7a.u7")).?;
	try t.expectEqual(method, entry.method);
	try t.expectEqual(@as(u32, 8192), entry.size);
	var out: [8192]u8 = undefined;
	try extract(entry, &out);
	var digest: [20]u8 = undefined;
	std.crypto.hash.Sha1.hash(&out, &digest, .{});
	try t.expectEqualStrings(fixtures.member_sha1, &std.fmt.bytesToHex(digest, .lower));
}

test "deflated and stored members extract exactly (fixtures made by Info-ZIP zip)" {
	try expectFixtureMember(fixtures.deflate_zip, 8);
	try expectFixtureMember(fixtures.stored_zip, 0);
}

test "names match exactly; absent members are null" {
	try t.expect((try find(fixtures.deflate_zip, "ignore.txt")) != null);
	try t.expect((try find(fixtures.deflate_zip, "csd_u7a.u")) == null);
	try t.expect((try find(fixtures.deflate_zip, "CSD_U7A.U7")) == null);
	try t.expect((try find(fixtures.deflate_zip, "missing")) == null);
}

test "non-ZIP and truncated input are malformed" {
	try t.expectError(error.Malformed, find("not a ZIP", "x"));
	try t.expectError(error.Malformed, find("", "x"));
	const z = fixtures.deflate_zip;
	try t.expectError(error.Malformed, find(z[0 .. z.len - 1], "csd_u7a.u7"));
}

test "every single-byte truncation is rejected or still extracts verified data" {
	// Shotgun over cut points: no panic, no out-of-bounds read, no silent corruption.
	const z = fixtures.deflate_zip;
	for (0..z.len) |cut| {
		const entry = find(z[0..cut], "csd_u7a.u7") catch continue orelse continue;
		var out: [8192]u8 = undefined;
		if (entry.size != out.len) continue;
		extract(entry, &out) catch continue;
		try expectFixtureMember(z[0..cut], entry.method);
	}
}

test "every single-bit flip is rejected or extracts verified data" {
	const z = fixtures.deflate_zip;
	var buf: [fixtures.deflate_zip.len]u8 = undefined;
	var detected: usize = 0;
	var total: usize = 0;
	for (0..z.len * 8) |bit| {
		@memcpy(&buf, z);
		buf[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
		const entry = find(&buf, "csd_u7a.u7") catch {
			detected += 1;
			total += 1;
			continue;
		} orelse {
			detected += 1;
			total += 1;
			continue;
		};
		total += 1;
		var out: [8192]u8 = undefined;
		if (entry.size != out.len) {
			detected += 1;
			continue;
		}
		extract(entry, &out) catch {
			detected += 1;
			continue;
		};
		// Undetected flips must be in bytes that do not affect the payload.
		var digest: [20]u8 = undefined;
		std.crypto.hash.Sha1.hash(&out, &digest, .{});
		try t.expectEqualStrings(fixtures.member_sha1, &std.fmt.bytesToHex(digest, .lower));
	}
	try t.expect(detected > 0 and total == z.len * 8);
}

test "extract rejects an output length different from the declared size" {
	const entry = (try find(fixtures.deflate_zip, "csd_u7a.u7")).?;
	var small: [100]u8 = undefined;
	try t.expectError(error.Corrupt, extract(entry, &small));
}
