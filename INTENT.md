# Spy Hunter music

Play the original arcade Spy Hunter sound program independently of the game, for personal listening and investigation of a developer's procedural-music claim. Peter requested this on October 1, 2026.

The executable is `spy-hunter-music`. A Zig core (board wiring, ROM admission, controls; no I/O) exposes a C ABI; a C CLI dogfoods that ABI, and the same core compiles to WebAssembly. Pinned C CPU/chip cores are acceptable. Support Linux x86_64/aarch64, macOS aarch64, and Windows x86_64. The Windows executable cross-compiles with Zig's mingw toolchain and is not a flake output. On 2026-10-02 it ran under Wine for `--about` and a 2 second render that matched the Linux x86_64 WAV. Console hold-to-fire and waveOut playback are implemented and have not been run on a Windows machine. Music loops until Ctrl-C, Ctrl-Q, Ctrl-D, q/Q or uppercase D; space fires the original guns, held for as long as the key is held where the terminal reports key releases; lowercase d plays the original death cue and then resumes safe-driving music; p pauses and resumes. Restore the terminal and close audio on exit or failure.

The web page plays the sound-board program (music, effects, gain PROM) from an image embedded in the wasm, plus one decorative background from `assets/`. It does not carry the rest of the game ROM, and it does not offer the sound-board bytes as a separate download. The same controls apply, minus quitting.

Original emulator and application source can be versioned separately from game assets. The native player still reads a local archive supplied by the person running it.

Success requires a working native audio player, verified ROM mapping, regression tests through one `./test`, keyboard/cleanup checks and a documented distinction between observed ROM behavior and the unverified developer claim. Native macOS execution must be labeled pending until tested there.
