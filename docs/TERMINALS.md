# Terminals and key releases

Hold-to-fire needs key-release events. The CLI pushes kitty keyboard flags 1|2|8 (`CSI > 11 u`) and checks the reply to `CSI ? u` followed by primary device attributes `CSI c`: releases are available only when the reply reports flag 2 (event types). `spy-hunter-music --tips` turns this table into advice for the current setup.

Verified 2026-10-02 against each project's documentation or source at HEAD, except where marked unverified.

| Terminal or multiplexer                     | Key releases                                                           | Default                                                               | Detected by                                                           |
| ------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------- |
| WezTerm                                     | yes                                                                    | off: `config.enable_kitty_keyboard = true`                            | `TERM_PROGRAM=WezTerm`, `WEZTERM_PANE`                                |
| kitty                                       | yes                                                                    | on                                                                    | `TERM=xterm-kitty`, `KITTY_WINDOW_ID`                                 |
| Ghostty                                     | yes                                                                    | on, no setting                                                        | `TERM_PROGRAM=ghostty`, `TERM=xterm-ghostty`, `GHOSTTY_RESOURCES_DIR` |
| Alacritty 0.13.0+                           | yes                                                                    | on                                                                    | `ALACRITTY_WINDOW_ID`, `TERM=alacritty`                               |
| foot 1.10.3+                                | yes                                                                    | on                                                                    | `TERM=foot`                                                           |
| iTerm2 3.5+                                 | yes                                                                    | "Apps can change how keys are reported" (pane and default unverified) | `TERM_PROGRAM=iTerm.app`                                              |
| Rio                                         | yes                                                                    | on                                                                    | `TERM_PROGRAM=rio`                                                    |
| Konsole (merged May 2026, likely 26.08)     | yes                                                                    | on                                                                    | `KONSOLE_VERSION`                                                     |
| VTE: GNOME Terminal, Console, Tilix, Ptyxis | no (VTE issue 2601 open)                                               | n/a                                                                   | `VTE_VERSION`                                                         |
| xterm                                       | no                                                                     | n/a                                                                   | `XTERM_VERSION`                                                       |
| Apple Terminal                              | no (closed source, unverified)                                         | n/a                                                                   | `TERM_PROGRAM=Apple_Terminal`                                         |
| tmux                                        | no: ignores the query; `extended-keys` carries modifiers only          | n/a                                                                   | `TMUX`                                                                |
| Zellij                                      | no: flag 1 only, answers `CSI ? 1 u`                                   | n/a                                                                   | `ZELLIJ`                                                              |
| GNU screen                                  | no (unverified)                                                        | n/a                                                                   | `STY`                                                                 |
| Herdr                                       | presses arrive as plain bytes (observed in 0.9.1); echoes pushed flags | n/a                                                                   | `HERDR_ENV=1`, `TERM_PROGRAM=herdr`                                   |
| Windows console                             | yes: ReadConsoleInput key-up, encoded as kitty CSI-u                   | cmd, PowerShell, Windows Terminal. Git Bash and mintty are not consoles | `OS=Windows_NT` (wins over `TERM`)                                    |

The Windows row is the `spy-hunter-music.exe` console adapter, not Windows Terminal's own keyboard protocol. `OS=Windows_NT` is set by Windows and by Wine.

Primary sources:

- WezTerm: [enable_kitty_keyboard](https://wezterm.org/config/lua/config/enable_kitty_keyboard.html) ("Default Value: false"); `term/src/terminalstate/performer.rs` gates both push and query on it; `encode_kitty` in `wezterm-input-types/src/lib.rs` emits `:3` releases.
- kitty: [keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) ("the release type is 3") and [glossary](https://sw.kovidgoyal.net/kitty/glossary/).
- Ghostty: `src/input/key_encode.zig` (plain text only without report-all), `src/termio/Exec.zig` sets `TERM_PROGRAM`.
- Alacritty: `alacritty/src/config/ui_config.rs` (`kitty_keyboard: true`); CHANGELOG 0.13.0.
- foot: CHANGELOG 1.10.3, "Report event types (mode 0b10)".
- iTerm2: [Keys preferences](https://iterm2.com/documentation-preferences-profiles-keys.html); `sources/Keyboard/iTermModernKeyMapper.swift`.
- Rio: `bindings/kitty_keyboard.rs` uses `REPORT_EVENT_TYPES`.
- Konsole: KDE merge request 1188, "Implement Kitty keyboard protocol" (merged 2026-05-10).
- VTE: [issue 2601](https://gitlab.gnome.org/GNOME/vte/-/issues/2601) and merge request 14, both open.
- tmux: `input.c` has no handler for the kitty push or query; `options-table.c` documents `extended-keys` and `extended-keys-format`.
- Zellij: `zellij-client/src/lib.rs` pushes only flag 1; `zellij-server/src/panes/grid.rs` replies `?1u`.
- Herdr: `src/input/encode.rs` sends presses as generated text unless report-all is active on the host.
