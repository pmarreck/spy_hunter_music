//! Static/shared library root: exports the C ABI declared in include/spy_hunter.h.
comptime {
	_ = @import("ffi.zig");
}
