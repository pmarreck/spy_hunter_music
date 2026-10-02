//! `--tips` text: what was detected about the terminal setup and how to get
//! hold-to-fire (key releases) working there. Pure rendering from a
//! terminal.Detection. Facts were verified against each project's docs or
//! source on 2026-10-02 (see docs/TERMINALS.md). Written 2026-10-02 by Peter
//! Marreck with Claude Opus 5.5 (claude-opus-5-5).
const std = @import("std");
const terminal = @import("terminal.zig");

pub const Options = struct { color: bool = false, json: bool = false };

const Style = struct {
	color: bool,
	fn wrap(self: Style, code: []const u8, text: []const u8, w: *std.Io.Writer) !void {
		if (self.color) try w.print("\x1b[{s}m{s}\x1b[0m", .{ code, text }) else try w.writeAll(text);
	}
};

pub fn terminalName(term: terminal.Terminal) []const u8 {
	return switch (term) {
		.unknown => "an unrecognized terminal",
		.wezterm => "WezTerm",
		.kitty => "kitty",
		.ghostty => "Ghostty",
		.alacritty => "Alacritty",
		.foot => "foot",
		.iterm2 => "iTerm2",
		.apple_terminal => "Apple Terminal",
		.vte => "a VTE terminal (GNOME Terminal, Console, Tilix or Ptyxis)",
		.konsole => "Konsole",
		.xterm => "xterm",
		.rio => "Rio",
		.windows_console => "the Windows console",
	};
}

pub fn multiplexerName(m: terminal.Multiplexer) []const u8 {
	return switch (m) {
		.none => "none",
		.herdr => "Herdr",
		.tmux => "tmux",
		.zellij => "Zellij",
		.screen => "GNU screen",
	};
}

/// Advice lines for this setup, most important first.
pub fn advice(d: terminal.Detection, out: *[8][]const u8) [][]const u8 {
	var n: usize = 0;
	const add = struct {
		fn f(buf: *[8][]const u8, count: *usize, line: []const u8) void {
			if (count.* < buf.len) {
				buf[count.*] = line;
				count.* += 1;
			}
		}
	}.f;
	switch (d.multiplexer) {
		.none => {},
		.herdr => add(out, &n, "Herdr forwards a space press as a plain byte, so hold-to-fire cannot work inside it even when the terminal around it supports key releases. Run spy-hunter-music in a terminal tab outside Herdr."),
		.tmux => add(out, &n, "tmux cannot pass key-release events to programs: it ignores the kitty keyboard protocol, and its extended-keys option only adds modifier encodings. Run spy-hunter-music in a terminal tab outside tmux."),
		.zellij => add(out, &n, "Zellij supports only the first kitty keyboard level (disambiguation), not key-release events. Run spy-hunter-music in a terminal tab outside Zellij."),
		.screen => add(out, &n, "GNU screen does not pass kitty keyboard events. Run spy-hunter-music in a terminal tab outside screen."),
	}
	if (d.verdict == .releases) {
		add(out, &n, "Nothing to change: this setup reports key releases, so holding space fires continuously and releasing stops after the last shot.");
		return out[0..n];
	}
	switch (d.terminal) {
		.wezterm => add(out, &n, "WezTerm reports key releases only when the kitty keyboard protocol is enabled; it is off by default. Add `config.enable_kitty_keyboard = true` to your WezTerm config (~/.config/wezterm/wezterm.lua or ~/.wezterm.lua) before `return config`, then open a new WezTerm window."),
		.kitty => add(out, &n, "kitty supports key releases by default. If this check still fails outside a multiplexer, update kitty."),
		.ghostty => add(out, &n, "Ghostty supports key releases by default and has no setting to turn them off. If this check fails outside a multiplexer, update Ghostty."),
		.alacritty => add(out, &n, "Alacritty supports key releases by default from version 0.13.0. Update Alacritty if it is older."),
		.foot => add(out, &n, "foot reports key releases from version 1.10.3. Update foot if it is older."),
		.rio => add(out, &n, "Rio supports key releases by default. If this check fails outside a multiplexer, update Rio."),
		.iterm2 => add(out, &n, "iTerm2 3.5 and later support key releases when \"Apps can change how keys are reported\" is enabled in Settings > Profiles (Keys or Terminal tab). Enable it, or update iTerm2."),
		.konsole => add(out, &n, "Konsole gained the kitty keyboard protocol in 2026 (expected in Konsole 26.08). Update Konsole, and check that \"Kitty keyboard protocol\" is enabled under Settings > Edit Current Profile > Advanced."),
		.vte => add(out, &n, "VTE-based terminals (GNOME Terminal, Console, Tilix, Ptyxis) do not implement the kitty keyboard protocol yet, so they cannot report key releases. Use Ghostty, kitty, Alacritty, foot or WezTerm with enable_kitty_keyboard."),
		.apple_terminal => add(out, &n, "Apple Terminal does not report key releases. Use Ghostty, kitty, iTerm2 or WezTerm with enable_kitty_keyboard."),
		.xterm => add(out, &n, "xterm does not implement the kitty keyboard protocol. Use Ghostty, kitty, Alacritty, foot or WezTerm with enable_kitty_keyboard."),
		.unknown => add(out, &n, "Key releases need a terminal that implements the kitty keyboard protocol with event types: Ghostty, kitty, Alacritty 0.13+, foot 1.10.3+, iTerm2 3.5+, Rio, or WezTerm with enable_kitty_keyboard."),
		.windows_console => add(out, &n, "The Windows build reads key-up events from the console, so hold-to-fire works in cmd, PowerShell, and Windows Terminal. Git Bash and mintty are not consoles; run spy-hunter-music.exe from one of those."),
	}
	if (d.verdict == .unknown) add(out, &n, "Run --tips from the terminal you play in; without a terminal on stdin and stdout the live check cannot run.");
	add(out, &n, "Without key releases, each space press fires the arcade's two-shot tap; holding space pauses once before key repeat starts.");
	add(out, &n, "The web player always has hold-to-fire, because browsers report key releases.");
	return out[0..n];
}

fn probeText(p: terminal.Probe) []const u8 {
	return switch (p) {
		.not_run => "not run (no terminal on stdin/stdout)",
		.no_kitty_reply => "no kitty keyboard reply (protocol absent or disabled)",
		.kitty_reply => "kitty keyboard active with key-release events",
		.kitty_reply_without_releases => "kitty keyboard reply without key-release events",
		.silent => "no reply",
		.windows_console => "Windows console key-up events",
	};
}

fn verdictText(v: terminal.Verdict) []const u8 {
	return switch (v) {
		.releases => "available",
		.no_releases => "unavailable (each space press fires two shots)",
		.unknown => "unknown",
	};
}

/// Render the tips for `d` to `w` as styled text or JSON.
pub fn render(d: terminal.Detection, options: Options, w: *std.Io.Writer) !void {
	var buf: [8][]const u8 = undefined;
	const lines = advice(d, &buf);
	if (options.json) {
		try w.print("{{\"terminal\":\"{s}\",\"multiplexer\":\"{s}\",\"probe\":\"{s}\",\"hold_to_fire\":\"{s}\",\"tips\":[", .{
			@tagName(d.terminal), @tagName(d.multiplexer), @tagName(d.probe), @tagName(d.verdict),
		});
		for (lines, 0..) |line, i| {
			if (i > 0) try w.writeByte(',');
			try std.json.Stringify.value(line, .{}, w);
		}
		try w.writeAll("]}\n");
		return;
	}
	const s: Style = .{ .color = options.color };
	try s.wrap("1;36", "Terminal: ", w);
	try w.print("{s}\n", .{terminalName(d.terminal)});
	try s.wrap("1;36", "Multiplexer: ", w);
	try w.print("{s}\n", .{multiplexerName(d.multiplexer)});
	try s.wrap("1;36", "Live check: ", w);
	try w.print("{s}\n", .{probeText(d.probe)});
	try s.wrap("1;36", "Hold-to-fire: ", w);
	try s.wrap(switch (d.verdict) {
		.releases => "1;32",
		.no_releases => "1;33",
		.unknown => "1",
	}, verdictText(d.verdict), w);
	try w.writeAll("\n\n");
	for (lines) |line| {
		try s.wrap("35", "• ", w);
		try w.print("{s}\n", .{line});
	}
}

// ---- tests ----

const t = std.testing;

fn renderTo(buf: []u8, d: terminal.Detection, options: Options) ![]const u8 {
	var w: std.Io.Writer = .fixed(buf);
	try render(d, options, &w);
	return w.buffered();
}

fn det(term: terminal.Terminal, mux: terminal.Multiplexer, verdict: terminal.Verdict) terminal.Detection {
	return .{ .terminal = term, .multiplexer = mux, .probe = .no_kitty_reply, .verdict = verdict };
}

test "every terminal without releases gets a terminal-specific fix" {
	const expected = [_]struct { terminal.Terminal, []const u8 }{
		.{ .wezterm, "config.enable_kitty_keyboard = true" },
		.{ .kitty, "update kitty" },
		.{ .ghostty, "update Ghostty" },
		.{ .alacritty, "0.13.0" },
		.{ .foot, "1.10.3" },
		.{ .rio, "update Rio" },
		.{ .iterm2, "Apps can change how keys are reported" },
		.{ .konsole, "Kitty keyboard protocol" },
		.{ .vte, "do not implement the kitty keyboard protocol yet" },
		.{ .apple_terminal, "Apple Terminal does not report key releases" },
		.{ .xterm, "xterm does not implement" },
		.{ .unknown, "need a terminal that implements" },
		.{ .windows_console, "Windows Terminal" },
	};
	inline for (@typeInfo(terminal.Terminal).@"enum".fields) |field| {
		const term: terminal.Terminal = @enumFromInt(field.value);
		var found = false;
		for (expected) |e| if (e[0] == term) {
			found = true;
			var buf: [4096]u8 = undefined;
			const text = try renderTo(&buf, det(term, .none, .no_releases), .{});
			if (std.mem.indexOf(u8, text, e[1]) == null) {
				std.debug.print("{s}: missing \"{s}\"\n{s}\n", .{ field.name, e[1], text });
				return error.TestUnexpectedResult;
			}
		};
		try t.expect(found); // a new Terminal must get advice and a test entry
	}
}

test "multiplexers get their caveat first, whatever the terminal" {
	const cases = [_]struct { terminal.Multiplexer, []const u8 }{
		.{ .herdr, "outside Herdr" },
		.{ .tmux, "outside tmux" },
		.{ .zellij, "outside Zellij" },
		.{ .screen, "outside screen" },
	};
	for (cases) |c| {
		var advice_buf: [8][]const u8 = undefined;
		const lines = advice(det(.wezterm, c[0], .no_releases), &advice_buf);
		try t.expect(std.mem.indexOf(u8, lines[0], c[1]) != null);
	}
}

test "windows tips name the console and do not claim the kitty protocol" {
	var buf: [4096]u8 = undefined;
	const probed = terminal.detect("OS=Windows_NT\x00TERM=xterm-kitty\x00", "\x1b[?11u\x1b[?62c", true);
	const text = try renderTo(&buf, probed, .{});
	try t.expect(std.mem.indexOf(u8, text, "Windows console") != null);
	try t.expect(std.mem.indexOf(u8, text, "Hold-to-fire: available") != null);
	try t.expect(std.mem.indexOf(u8, text, "kitty keyboard active") == null);
	var buf2: [4096]u8 = undefined;
	const idle = try renderTo(&buf2, terminal.detect("OS=Windows_NT\x00", "", false), .{});
	try t.expect(std.mem.indexOf(u8, idle, "Windows Terminal") != null);
	try t.expect(std.mem.indexOf(u8, idle, "kitty keyboard active") == null);
}

test "a working setup says nothing needs changing" {
	var buf: [4096]u8 = undefined;
	const text = try renderTo(&buf, .{ .terminal = .wezterm, .multiplexer = .none, .probe = .kitty_reply, .verdict = .releases }, .{});
	try t.expect(std.mem.indexOf(u8, text, "Hold-to-fire: available") != null);
	try t.expect(std.mem.indexOf(u8, text, "Nothing to change") != null);
	try t.expect(std.mem.indexOf(u8, text, "enable_kitty_keyboard") == null);
}

test "plain text has no ANSI; color highlights the verdict in yellow" {
	var buf: [4096]u8 = undefined;
	const plain = try renderTo(&buf, det(.wezterm, .none, .no_releases), .{});
	try t.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);
	var buf2: [4096]u8 = undefined;
	const colored = try renderTo(&buf2, det(.wezterm, .none, .no_releases), .{ .color = true });
	try t.expect(std.mem.indexOf(u8, colored, "\x1b[1;33munavailable") != null);
}

test "JSON output parses and carries the same advice" {
	var buf: [8192]u8 = undefined;
	const text = try renderTo(&buf, det(.wezterm, .herdr, .no_releases), .{ .json = true });
	const parsed = try std.json.parseFromSlice(struct {
		terminal: []const u8,
		multiplexer: []const u8,
		probe: []const u8,
		hold_to_fire: []const u8,
		tips: []const []const u8,
	}, t.allocator, text, .{});
	defer parsed.deinit();
	try t.expectEqualStrings("wezterm", parsed.value.terminal);
	try t.expectEqualStrings("herdr", parsed.value.multiplexer);
	try t.expectEqualStrings("no_releases", parsed.value.hold_to_fire);
	try t.expect(std.mem.indexOf(u8, parsed.value.tips[0], "outside Herdr") != null);
}
