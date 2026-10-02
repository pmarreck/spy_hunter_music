//! Terminal capability detection for hold-to-fire: identify the outer
//! terminal and any multiplexer from environment variables, read the reply to
//! a kitty keyboard query (`CSI ? u` then primary device attributes
//! `CSI c`), and decide whether key-release events can reach the player.
//! Written 2026-10-02 by Peter Marreck with Claude Opus 5.5 (claude-opus-5-5).
const std = @import("std");

pub const Terminal = enum { unknown, wezterm, kitty, ghostty, alacritty, foot, iterm2, apple_terminal, vte, konsole, xterm, rio };
pub const Multiplexer = enum { none, herdr, tmux, zellij, screen };

/// Result of probing the terminal on our stdin/stdout.
pub const Probe = enum {
	/// No terminal to probe (not a TTY) or the probe was skipped.
	not_run,
	/// Device attributes answered but no kitty flags reply: protocol absent or disabled.
	no_kitty_reply,
	/// The kitty flags query was answered with event types (flag 2) active
	/// after our push: key releases are reported at this layer.
	kitty_reply,
	/// Answered, but without event types (e.g. Zellij's `?1u`, or `?0u` when
	/// the push was ignored): no key releases.
	kitty_reply_without_releases,
	/// Nothing answered before the timeout.
	silent,
};

/// Kitty "report event types" progressive enhancement: press/repeat/release.
const event_types_flag: u32 = 2;

pub const Verdict = enum(c_int) { unknown = 0, releases = 1, no_releases = 2 };

pub const Detection = struct {
	terminal: Terminal,
	multiplexer: Multiplexer,
	probe: Probe,
	verdict: Verdict,
};

/// Look up `key` in a block of NUL-separated `KEY=VALUE` entries.
pub fn getenv(env: []const u8, key: []const u8) ?[]const u8 {
	var entries = std.mem.splitScalar(u8, env, 0);
	while (entries.next()) |entry| {
		if (entry.len > key.len and entry[key.len] == '=' and std.mem.eql(u8, entry[0..key.len], key))
			return entry[key.len + 1 ..];
	}
	return null;
}

/// Classify the probe reply bytes: a `CSI ? <flags> u` answer before the
/// device-attributes reply means the kitty protocol is active.
pub fn parseProbe(reply: []const u8, probed: bool) Probe {
	if (!probed) return .not_run;
	var i: usize = 0;
	while (std.mem.indexOfPos(u8, reply, i, "\x1b[?")) |start| {
		var end = start + 3;
		while (end < reply.len and (std.ascii.isDigit(reply[end]) or reply[end] == ';')) end += 1;
		if (end >= reply.len) break;
		if (reply[end] == 'u') {
			const flags = std.fmt.parseInt(u32, reply[start + 3 .. end], 10) catch 0;
			return if (flags & event_types_flag != 0) .kitty_reply else .kitty_reply_without_releases;
		}
		if (reply[end] == 'c') return .no_kitty_reply;
		i = end;
	}
	return .silent;
}

fn has(env: []const u8, key: []const u8) bool {
	return getenv(env, key) != null;
}

fn is(env: []const u8, key: []const u8, value: []const u8) bool {
	return if (getenv(env, key)) |v| std.mem.eql(u8, v, value) else false;
}

fn termStarts(env: []const u8, prefix: []const u8) bool {
	return if (getenv(env, "TERM")) |v| std.mem.startsWith(u8, v, prefix) else false;
}

fn identifyMultiplexer(env: []const u8) Multiplexer {
	if (is(env, "HERDR_ENV", "1") or is(env, "TERM_PROGRAM", "herdr")) return .herdr;
	if (has(env, "TMUX") or is(env, "TERM_PROGRAM", "tmux")) return .tmux;
	if (has(env, "ZELLIJ")) return .zellij;
	if (has(env, "STY")) return .screen;
	return .none;
}

/// Identify the outer terminal. Inside a multiplexer TERM_PROGRAM and TERM
/// describe the multiplexer, so terminal-specific variables come first.
fn identifyTerminal(env: []const u8) Terminal {
	if (is(env, "TERM_PROGRAM", "WezTerm") or has(env, "WEZTERM_PANE") or has(env, "WEZTERM_EXECUTABLE")) return .wezterm;
	if (has(env, "KITTY_WINDOW_ID") or termStarts(env, "xterm-kitty")) return .kitty;
	if (is(env, "TERM_PROGRAM", "ghostty") or has(env, "GHOSTTY_RESOURCES_DIR") or termStarts(env, "xterm-ghostty")) return .ghostty;
	if (has(env, "ALACRITTY_WINDOW_ID") or has(env, "ALACRITTY_SOCKET") or termStarts(env, "alacritty")) return .alacritty;
	if (termStarts(env, "foot")) return .foot;
	if (is(env, "TERM_PROGRAM", "rio") or termStarts(env, "xterm-rio") or termStarts(env, "rio")) return .rio;
	if (is(env, "TERM_PROGRAM", "iTerm.app") or has(env, "ITERM_SESSION_ID")) return .iterm2;
	if (is(env, "TERM_PROGRAM", "Apple_Terminal")) return .apple_terminal;
	if (has(env, "KONSOLE_VERSION")) return .konsole;
	if (has(env, "VTE_VERSION")) return .vte;
	if (has(env, "XTERM_VERSION")) return .xterm;
	return .unknown;
}

pub fn detect(env: []const u8, reply: []const u8, probed: bool) Detection {
	const multiplexer = identifyMultiplexer(env);
	const probe = parseProbe(reply, probed);
	const verdict: Verdict = switch (multiplexer) {
		// Observed: Herdr 0.9.1 answers the query but forwards plain bytes.
		.herdr => .no_releases,
		else => switch (probe) {
			.not_run => .unknown,
			.kitty_reply => .releases,
			.no_kitty_reply, .kitty_reply_without_releases, .silent => .no_releases,
		},
	};
	return .{ .terminal = identifyTerminal(env), .multiplexer = multiplexer, .probe = probe, .verdict = verdict };
}

// ---- tests ----

const t = std.testing;

fn block(comptime pairs: []const []const u8) []const u8 {
	comptime var out: []const u8 = "";
	inline for (pairs) |p| out = out ++ p ++ "\x00";
	return out;
}

test "getenv finds exact keys in a NUL-separated block" {
	const env = block(&.{ "TERM=xterm-256color", "TERM_PROGRAM=WezTerm", "TMUXX=decoy", "EMPTY=" });
	try t.expectEqualStrings("WezTerm", getenv(env, "TERM_PROGRAM").?);
	try t.expectEqualStrings("", getenv(env, "EMPTY").?);
	try t.expect(getenv(env, "TMUX") == null);
	try t.expect(getenv(env, "TERM_PROG") == null);
	try t.expect(getenv("", "TERM") == null);
	try t.expect(getenv("TERM", "TERM") == null); // no '=' is not an entry
}

test "probe replies are classified" {
	try t.expectEqual(Probe.not_run, parseProbe("", false));
	try t.expectEqual(Probe.silent, parseProbe("", true));
	try t.expectEqual(Probe.kitty_reply, parseProbe("\x1b[?11u\x1b[?62;22c", true));
	try t.expectEqual(Probe.kitty_reply_without_releases, parseProbe("\x1b[?0u\x1b[?62c", true)); // our push was ignored
	try t.expectEqual(Probe.no_kitty_reply, parseProbe("\x1b[?62;22c", true));
	try t.expectEqual(Probe.no_kitty_reply, parseProbe("x\x1b[?1;2c", true)); // stray typed byte first
}

const Case = struct { env: []const u8, terminal: Terminal, multiplexer: Multiplexer };

test "terminals and multiplexers are identified over a set of environments" {
	const cases = [_]Case{
		.{ .env = block(&.{"TERM_PROGRAM=WezTerm"}), .terminal = .wezterm, .multiplexer = .none },
		.{ .env = block(&.{"WEZTERM_PANE=0"}), .terminal = .wezterm, .multiplexer = .none },
		.{ .env = block(&.{"TERM=xterm-kitty"}), .terminal = .kitty, .multiplexer = .none },
		.{ .env = block(&.{"KITTY_WINDOW_ID=1"}), .terminal = .kitty, .multiplexer = .none },
		.{ .env = block(&.{"TERM_PROGRAM=ghostty"}), .terminal = .ghostty, .multiplexer = .none },
		.{ .env = block(&.{"TERM=xterm-ghostty"}), .terminal = .ghostty, .multiplexer = .none },
		.{ .env = block(&.{"GHOSTTY_RESOURCES_DIR=/x"}), .terminal = .ghostty, .multiplexer = .none },
		.{ .env = block(&.{"ALACRITTY_WINDOW_ID=5"}), .terminal = .alacritty, .multiplexer = .none },
		.{ .env = block(&.{"TERM=alacritty"}), .terminal = .alacritty, .multiplexer = .none },
		.{ .env = block(&.{"TERM=foot"}), .terminal = .foot, .multiplexer = .none },
		.{ .env = block(&.{"TERM=foot-extra"}), .terminal = .foot, .multiplexer = .none },
		.{ .env = block(&.{"TERM_PROGRAM=iTerm.app"}), .terminal = .iterm2, .multiplexer = .none },
		.{ .env = block(&.{"TERM_PROGRAM=Apple_Terminal"}), .terminal = .apple_terminal, .multiplexer = .none },
		.{ .env = block(&.{"VTE_VERSION=7600"}), .terminal = .vte, .multiplexer = .none },
		.{ .env = block(&.{"KONSOLE_VERSION=240802"}), .terminal = .konsole, .multiplexer = .none },
		.{ .env = block(&.{"XTERM_VERSION=XTerm(393)"}), .terminal = .xterm, .multiplexer = .none },
		.{ .env = block(&.{"TERM_PROGRAM=rio"}), .terminal = .rio, .multiplexer = .none },
		.{ .env = block(&.{"TERM=xterm-rio"}), .terminal = .rio, .multiplexer = .none },
		.{ .env = block(&.{"TERM=xterm-256color"}), .terminal = .unknown, .multiplexer = .none },
		.{ .env = "", .terminal = .unknown, .multiplexer = .none },
		// Multiplexers: TERM_PROGRAM names the multiplexer; the outer terminal
		// is recovered from inherited variables.
		.{ .env = block(&.{ "TERM_PROGRAM=herdr", "HERDR_ENV=1", "WEZTERM_PANE=3" }), .terminal = .wezterm, .multiplexer = .herdr },
		.{ .env = block(&.{"HERDR_ENV=1"}), .terminal = .unknown, .multiplexer = .herdr },
		.{ .env = block(&.{ "TMUX=/tmp/tmux-1000/default,1,0", "TERM_PROGRAM=tmux", "KITTY_WINDOW_ID=2" }), .terminal = .kitty, .multiplexer = .tmux },
		.{ .env = block(&.{"ZELLIJ=0"}), .terminal = .unknown, .multiplexer = .zellij },
		.{ .env = block(&.{ "STY=1234.pts-0.host", "VTE_VERSION=7600" }), .terminal = .vte, .multiplexer = .screen },
		.{ .env = block(&.{"HERDR_ENV=0"}), .terminal = .unknown, .multiplexer = .none },
	};
	for (cases) |c| {
		const d = detect(c.env, "", false);
		t.expectEqual(c.terminal, d.terminal) catch |err| {
			std.debug.print("env {any}: terminal {s}\n", .{ c.env, @tagName(d.terminal) });
			return err;
		};
		try t.expectEqual(c.multiplexer, d.multiplexer);
	}
}

test "verdict: releases only with a kitty reply and no plain-key multiplexer" {
	const reply = "\x1b[?11u\x1b[?62c"; // after our push of flags 1|2|8
	const da = "\x1b[?62c";
	try t.expectEqual(Verdict.releases, detect(block(&.{"TERM_PROGRAM=WezTerm"}), reply, true).verdict);
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"TERM_PROGRAM=WezTerm"}), da, true).verdict);
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"TERM_PROGRAM=Apple_Terminal"}), "", true).verdict);
	// Herdr answers the query yet forwarded plain keys (observed with 0.9.1).
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"HERDR_ENV=1"}), reply, true).verdict);
	try t.expectEqual(Verdict.unknown, detect(block(&.{"TERM_PROGRAM=WezTerm"}), "", false).verdict);
}

test "a reply without the event-types flag means no releases (Zellij answers ?1u)" {
	// Zellij supports only flag 1 and replies `CSI ? 1 u` to any push
	// (zellij-server/src/panes/grid.rs); releases need flag 2.
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"ZELLIJ=0"}), "\x1b[?1u\x1b[?62c", true).verdict);
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"TERM=xterm-kitty"}), "\x1b[?1u\x1b[?62c", true).verdict);
	try t.expectEqual(Verdict.releases, detect(block(&.{"TERM=xterm-kitty"}), "\x1b[?11u\x1b[?62c", true).verdict);
	// tmux ignores the query entirely, so only device attributes come back.
	try t.expectEqual(Verdict.no_releases, detect(block(&.{"TMUX=/tmp/t,1,0"}), "\x1b[?62c", true).verdict);
}
