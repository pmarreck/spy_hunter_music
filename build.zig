const std = @import("std");

/// C emulator cores shared by every artifact: Musashi (68000, opcode tables
/// generated at build time by its m68kmake) and floooh/chips (Z80, AY).
const Cores = struct {
	translated: *std.Build.Module,
	musashi: *std.Build.Dependency,
	chips: *std.Build.Dependency,
	generated: std.Build.LazyPath,

	fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Cores {
		const musashi = b.dependency("musashi", .{});
		const chips = b.dependency("chips", .{});
		const make = b.addExecutable(.{ .name = "m68kmake", .root_module = b.createModule(.{
			.target = b.graph.host,
			.optimize = .ReleaseSafe,
			.link_libc = true,
		}) });
		make.root_module.addCSourceFile(.{ .file = musashi.path("m68kmake.c"), .flags = &.{"-w"} });
		const generate = b.addRunArtifact(make);
		const generated = generate.addOutputDirectoryArg("musashi");
		generate.addFileArg(musashi.path("m68k_in.c"));
		_ = generate.captureStdOut(.{}); // keep the generator's banner out of build output

		const translate = b.addTranslateC(.{
			.root_source_file = b.path("src/core/cores.h"),
			.target = target,
			.optimize = optimize,
		});
		translate.addIncludePath(musashi.path("."));
		translate.addIncludePath(chips.path("chips"));
		return .{ .translated = translate.createModule(), .musashi = musashi, .chips = chips, .generated = generated };
	}

	fn addTo(self: Cores, m: *std.Build.Module) void {
		m.link_libc = true;
		const wasm = m.resolved_target.?.result.cpu.arch.isWasm();
		if (wasm) m.addIncludePath(m.owner.path("src/web/compat")); // before libc's setjmp.h
		m.addImport("cores", self.translated);
		m.addIncludePath(self.musashi.path("."));
		m.addIncludePath(self.generated);
		m.addIncludePath(self.chips.path("chips"));
		const flags = &.{ "-std=gnu99", "-w" };
		m.addCSourceFiles(.{ .root = self.musashi.path("."), .files = &.{ "m68kcpu.c", "softfloat/softfloat.c" }, .flags = flags });
		if (!wasm) m.addCSourceFile(.{ .file = self.musashi.path("m68kdasm.c"), .flags = flags });
		m.addCSourceFile(.{ .file = self.generated.path(m.owner, "m68kops.c"), .flags = flags });
		m.addCSourceFile(.{ .file = m.owner.path("src/core/chips_impl.c"), .flags = flags });
	}
};

/// Sound-board image module for one target. Pure Zig: no emulator cores.
fn soundImageModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
	const rom_module = b.createModule(.{
		.root_source_file = b.path("src/core/rom.zig"),
		.target = target,
		.optimize = optimize,
	});
	return b.createModule(.{
		.root_source_file = b.path("src/web/sound_image.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{.{ .name = "rom", .module = rom_module }},
	});
}

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;
	const cores = Cores.init(b, target, optimize);

	const fixtures = b.createModule(.{ .root_source_file = b.path("tests/fixtures/fixtures.zig") });
	const test_module = b.createModule(.{
		.root_source_file = b.path("src/core/root.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{.{ .name = "fixtures", .module = fixtures }},
	});
	cores.addTo(test_module);
	const core_tests = b.addTest(.{ .root_module = test_module });
	const image_tests = b.addTest(.{ .root_module = soundImageModule(b, target, optimize) });
	const test_step = b.step("test", "Run Zig core unit tests");
	test_step.dependOn(&b.addRunArtifact(core_tests).step);
	test_step.dependOn(&b.addRunArtifact(image_tests).step);

	// The core library: the C ABI is the public interface for every consumer.
	const lib_module = b.createModule(.{ .root_source_file = b.path("src/core/lib.zig"), .target = target, .optimize = optimize });
	cores.addTo(lib_module);
	const lib = b.addLibrary(.{ .name = "spy_hunter", .linkage = .static, .root_module = lib_module });
	lib.installHeader(b.path("include/spy_hunter.h"), "spy_hunter.h");
	b.installArtifact(lib);

	// The C CLI dogfoods the C ABI; C cannot import the Zig core directly.
	const cli_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
	cli_module.addIncludePath(b.path("include"));
	const cli_flags: []const []const u8 = if (optimize == .Debug)
		&.{ "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra", "-Werror", "-DSH_DEBUG_BUILD" }
	else
		&.{ "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra", "-Werror" };
	cli_module.addCSourceFiles(.{ .root = b.path("src/cli"), .files = &.{ "main.c", "terminal.c" }, .flags = cli_flags });
	cli_module.linkLibrary(lib);
	cli_module.linkSystemLibrary("SDL2", .{});
	cli_module.linkSystemLibrary("m", .{});
	const cli = b.addExecutable(.{ .name = "spy-hunter-music", .root_module = cli_module });
	b.installArtifact(cli);

	// WebAssembly build of the same core for the personal web page.
	const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
	const wasm_cores = Cores.init(b, wasm_target, .ReleaseFast);
	const core_module = b.createModule(.{ .root_source_file = b.path("src/core/root.zig"), .target = wasm_target, .optimize = .ReleaseFast });
	wasm_cores.addTo(core_module);
	const wasm = b.addExecutable(.{ .name = "spy_hunter", .root_module = b.createModule(.{
		.root_source_file = b.path("src/web/wasm.zig"),
		.target = wasm_target,
		.optimize = .ReleaseFast,
		.imports = &.{.{ .name = "core", .module = core_module }},
	}) });
	wasm.entry = .disabled;
	wasm.rdynamic = true;
	const web_step = b.step("web", "Build the personal web player into zig-out/web");
	web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
	web_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("web"), .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
	// One copy, at build time, from assets/. The source tree keeps the artwork there only.
	web_step.dependOn(&b.addInstallFileWithDir(b.path("assets/G-6155.png"), .{ .custom = "web" }, "background.png").step);
}
