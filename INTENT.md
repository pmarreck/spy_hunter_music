# Spy Hunter music

Play the original arcade Spy Hunter sound program independently of the game, for personal listening and investigation of a developer's procedural-music claim. Peter requested this on October 1, 2026.

The executable is `spy-hunter-music`. A Zig core (board wiring, ROM admission, controls; no I/O) exposes a C ABI; a C CLI dogfoods that ABI, and the same core compiles to WebAssembly. Pinned C CPU/chip cores are acceptable. Support Linux x86_64/aarch64 and macOS aarch64. Windows is excluded for now. Music loops until Ctrl-C, Ctrl-Q, Ctrl-D, q/Q or uppercase D; space fires the original guns, held for as long as the key is held where the terminal reports key releases; lowercase d plays the original death cue and then resumes safe-driving music; p pauses and resumes. Restore the terminal and close audio on exit or failure.

The web page uses only the game audio plus a decorative background image, with the same controls (minus quitting).

Only sound-board ROM regions were extracted. Original emulator/application source can be versioned separately from game assets.

Success requires a working native audio player, verified ROM mapping, regression tests through one `./test`, keyboard/cleanup checks and a documented distinction between observed ROM behavior and the unverified developer claim. Native macOS execution must be labeled pending until tested there.
