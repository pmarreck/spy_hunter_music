# Spy Hunter Music

Run the original Spy Hunter arcade sound programs independently of the game. A Zig core emulates the Motorola 68000 music board and a Z80 sound-effects board with two AY-3-8910 chips. The music is synthesized from extracted ROM data. No original ROMs are required or available.

## Play

```sh
cd "path/to/spy_hunter_music"
./build
./bin/spy-hunter-music
```

| Key                     | Action                                                            |
| ----------------------- | ----------------------------------------------------------------- |
| Space                   | Fire the original machine guns; hold to keep firing               |
| `p`                     | Pause or resume                                                   |
| `d`                     | Play the death cue, then resume driving music after eight seconds |
| `q`, `Q`, uppercase `D` | Quit                                                              |
| Ctrl-C, Ctrl-Q, Ctrl-D  | Quit                                                              |

The lowercase death key and uppercase quit key are intentionally different. Audio and terminal settings are restored on normal exit, caught signals and playback errors. SIGKILL and machine power loss cannot run cleanup code.

Use `--volume 0.3` for a quieter start. Where the terminal honors the kitty keyboard protocol with key-release events, the guns fire from key press until release, and the ROM finishes the shot in progress, as in the arcade. WezTerm does this only with `config.enable_kitty_keyboard = true` (default off); Herdr answers the protocol query but forwards plain keys. At startup the player checks the terminal and prints a yellow warning when key releases cannot arrive; the first space press confirms. Run `spy-hunter-music --tips` (or `--tips --json`) for what was detected and how to enable key releases in your terminal or multiplexer; see [the terminal notes](docs/TERMINALS.md). Without key releases, each keystroke fires 0.14 s, the arcade tap's two shots; holding space then pauses once before autorepeat starts. If the process is killed with SIGKILL, run `reset` in case the terminal remains in kitty key-reporting mode. The player does not simulate the rest of the game or choose commands from a driving simulation.

## Personal web player

```sh
./serve            # http://127.0.0.1:8473/
```

The same Zig core runs in the browser as WebAssembly inside an AudioWorklet. `./serve` bundles only the seven sound-board ROM members into `zig-out/web/sound.zip`, and the page loads them automatically; the core verifies their SHA-1s as the CLI does. Space fires while held (real key releases), `d` plays the death cue, `p` pauses; the buttons do the same.

## Local ROMs only

Provide your own local `spyhunt.zip`:

```sh
spy-hunter-music --rom "/path with spaces/spyhunt.zip"
SPY_HUNTER_ROM="$HOME/ROMs/spyhunt.zip" spy-hunter-music
spy-hunter-music inspect --rom "$HOME/ROMs/spyhunt.zip" --json
```

The core reads seven exact sound-ROM members from the in-memory ZIP (stored or deflated), checks their sizes and historical MAME SHA-1 identities, and interleaves the 68000 ROMs. Unrelated graphics and game-ROM members are skipped. Historical SHA-1 matching identifies the expected dump; it is not a modern authenticity or security guarantee. Both the legacy short member names and current MAME sound-ROM names are recognized. A set that omits the shared SSIO PROM must be supplied as a complete local archive containing that PROM.

No ROMs are downloaded, extracted to disk, bundled, or committed. Rendered music also stays untracked. The source license does not grant rights to game assets or the Peter Gunn composition.

ZIP input can also come from standard input (limited to 16 MiB):

```sh
spy-hunter-music inspect --rom @stdin --json < "path/to/spyhunt.zip"
```

## Render a private WAV

```sh
spy-hunter-music render --seconds 30 --output "$TMPDIR/spy-hunter.wav" --json
spy-hunter-music render --seconds 10 --output @stdout > "$TMPDIR/spy-hunter-short.wav"
```

Output is 48 kHz mono signed 16-bit PCM WAV. Existing files are refused, including the input archive. Statistics go to stderr; WAV data goes to the selected file or stdout. `--json` changes inspection/render statistics, not the audio format. Playback status goes to stderr.

`--command 0` starts the death cue, `1` selects continuous driving music, `2` selects the short intro, and `3` stops music. The board accepts four-bit commands, but this ROM dispatches on their low two bits. Death-to-driving resumption is the interactive player's policy; a render records the selected command without keyboard interaction.

## Build and test

```sh
./build
./test
nix flake check
```

Zig 0.16 builds a pure Zig core (C ABI in `include/spy_hunter.h`) and a C CLI that uses only that ABI. Nix pins Zig, SDL2, Musashi and floooh/chips; the emulator cores are fetched once into a fixed-output derivation. No emulator installation is required. `./build` creates a host-specific symlink beneath `bin/<os>/<arch>/`; Nix products remain beneath `.nix-out/<target>/ReleaseFast`. The portable `bin/spy-hunter-music` invokes the already-published host product, building through Nix only when it is missing. No dependency evaluation occurs on the warm path. `./run` deliberately rebuilds before launching.

Supported targets are Linux x86_64/aarch64 and macOS aarch64. The Zig rewrite (0.2.0) has been built and tested on Linux x86_64 only; macOS aarch64 is pending a native run (the earlier LuaJIT version passed there). Linux aarch64 is configured, but has not been executed on an ARM Linux machine.

`./test` is the complete entry point: Zig core units (key decoding, controller, ZIP/SHA-1 admission, WAV, synthetic 68000/Z80 programs for interrupts and command delivery), the C CLI surface, real PTY cleanup and host publication. Those require no game ROM, speakers, NAS or external service. Where a locally owned `spyhunt.zip` exists, `tests/rom/run` also checks per-platform render hashes and the startup death command; without one it reports NOT RUN. The first Nix bootstrap may need network access for pinned dependencies.

## What was verified

On October 2, 2026, the owned sound ROMs booted natively on Linux x86_64 and M4 macOS. All six suites and native Nix flake checks passed on both. A Linux dummy-audio interactive run accepted space, death and quit. Independent WAV inspection confirmed real PCM output; both machines' default audio devices opened and closed without queued sound overnight. Terminal tests cover quit keys, signals, idempotent restoration and the platforms' different kernel state flags.

A ten-second Linux/Mac render comparison found 81 differing samples out of 480,000, each differing by just one 16-bit PCM step. Cross-platform output is therefore closely matched but not bit-identical.

Human listening confirms musical balance and arcade fidelity. The mono mix, DC blocker and effects gain are approximations; this is not a claim of analog-circuit-accurate sound. The native adapter supports one emulated machine per process and is not a concurrent multi-instance library.

See [the music investigation](docs/MUSIC_INVESTIGATION.md) for evidence of fixed-score playback, synthesis and algorithmic variation. Application source is [MIT licensed](LICENSE); emulator and runtime dependencies retain [their own licenses](THIRD_PARTY.md).
