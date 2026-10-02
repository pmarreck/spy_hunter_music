//! WebAssembly root for the personal web player: the core's C ABI plus a
//! byte allocator so JavaScript can pass the user's ZIP into wasm memory.
const std = @import("std");

comptime {
	_ = @import("core").ffi;
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
