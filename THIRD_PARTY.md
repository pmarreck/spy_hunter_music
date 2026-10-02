# Third-party code and assets

Our application and board adapter are MIT licensed. That does not relicense their dependencies. Exact dependency revisions are in `flake.lock`.

## Embedded emulator code

- [Musashi](https://github.com/kstenerud/Musashi/tree/313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd), copyright Karl Stenerud, supplies 68000 execution and disassembly under its MIT-style notice in `m68k.h`.
- Musashi also compiles [SoftFloat Release 2b](https://github.com/kstenerud/Musashi/blob/313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd/softfloat/softfloat.c), written by John R. Hauser, with assistance from the International Computer Science Institute. Its custom notice permits derivative works, including commercial ones, subject to attribution, retained notices and responsibility/indemnity terms. It is not the application's MIT license. Although this board uses a 68000 without an FPU, the pinned Musashi build includes its floating-point support.
- [floooh/chips](https://github.com/floooh/chips/tree/9e88298ce56319953ac7a43213a1120359f7a3a6), copyright Andre Weissflog, supplies Z80 execution/disassembly and AY-3-8910 synthesis under the zlib/libpng license. The upstream files are used without edits; the board integration is ours.

The native Nix output preserves the full notices in unmodified source/header copies under `share/licenses/spy-hunter-sound/`: `m68k.h`, `softfloat.c`, `z80.h`, `ay38910.h` and `z80dasm.h`. These copies are attribution material, not a second build source tree. The linked native binary therefore has multiple applicable third-party licenses.

## Board reference

[MAME's CSD and Midway SSIO sources](https://github.com/mamedev/mame/tree/master/src/mame/bally) document the board clocks, address maps, command latches, PIA and effects gain PROM. Those files identify BSD-3-Clause licensing and Aaron Giles as a copyright holder. MAME is a research reference, not a linked/runtime dependency. See the investigation for exact source links.

## Runtime libraries

SDL2 (zlib) is provided by Nix for audio output; its notices remain applicable. ZIP inflation and SHA-1 come from the Zig standard library (MIT). SHA-1 is used for historical ROM identification, not for establishing rights or provenance.

## Game and music assets

No complete Spy Hunter ROM, game disassembly listing, or rendered music is included in this repository or package. Loading the webpage is not a redistribution license. Spy Hunter names and the Peter Gunn composition belong to their respective rights holders; the source license covers neither.
