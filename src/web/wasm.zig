//! WebAssembly root for the web player: the core's C ABI, the embedded
//! sound-board image, and a byte allocator for host buffers.
const std = @import("std");
const rom = @import("core").rom;
const ffi = @import("core").ffi;

const embedded = @embedFile("sound_image.bin");

comptime {
	_ = ffi;
}

/// Load the embedded sound-board image after checking its historical SHA-1s.
export fn sh_load_embedded() c_int {
	if (!rom.verifySoundImage(embedded)) return 1;
	const music_len = @typeInfo(@FieldType(rom.Images, "music")).array.len;
	const effects_len = @typeInfo(@FieldType(rom.Images, "effects")).array.len;
	const prom_len = @typeInfo(@FieldType(rom.Images, "prom")).array.len;
	return ffi.sh_load_images(
		embedded.ptr,
		music_len,
		embedded.ptr + music_len,
		effects_len,
		embedded.ptr + music_len + effects_len,
		prom_len,
	);
}

const allocator = std.heap.wasm_allocator;

/// Allocate `len` bytes for the host; returns 0 on failure.
export fn sh_alloc(len: usize) ?[*]u8 {
	const slice = allocator.alloc(u8, len) catch return null;
	return slice.ptr;
}

/// Free a block from sh_alloc; `len` must match the allocation.
export fn sh_free(ptr: ?[*]u8, len: usize) void {
	if (ptr) |p| allocator.free(p[0..len]);
}
