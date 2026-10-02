# Spy Hunter sound-program investigation

Investigated October 1–2, 2026, for a ROM player. The supplied statement was that an original developer described the music as procedurally-generated, inspiring this project.

## Finding

The sound ROM executes a software synthesizer, reads fixed musical event data, and contains state-dependent variation in a solo section. Calling that combination procedural is defensible. Describing the entire Peter Gunn arrangement as newly composed at runtime would go beyond the evidence. This is also not a pre-recorded audio track.

This conclusion comes from the local sound-program control flow and execution, with MAME as an independent board-wiring reference. It does not establish the original composer's intent or exact choice of terminology.

## Hardware and original program

The music board is a Motorola 68000 with a 10-bit DAC and 6821 PIA. Our configured 8 MHz CPU clock follows the current MAME CSD board definition. The effects board is a 2 MHz Z80 controlling two AY-3-8910 chips and a gain PROM. The four interleaved music ROMs supply 32 KiB; the two effects ROMs supply 8 KiB; the gain PROM is 32 bytes.

Primary references:

- [MAME CSD implementation](https://github.com/mamedev/mame/blob/master/src/mame/bally/csd.cpp) and [board declaration](https://github.com/mamedev/mame/blob/master/src/mame/bally/csd.h).
- [MAME Midway sound implementation](https://github.com/mamedev/mame/blob/master/src/mame/bally/midway_sound.cpp), including the SSIO map and PROM-controlled gain.
- [MAME MCR3 machine and ROM definitions](https://github.com/mamedev/mame/blob/master/src/mame/bally/mcr3.cpp).
- [Pinned Musashi CPU implementation](https://github.com/kstenerud/Musashi/tree/313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd) and [pinned Z80/AY implementation](https://github.com/floooh/chips/tree/9e88298ce56319953ac7a43213a1120359f7a3a6).

MAME links above follow its current branch; reproducible CPU/chip dependencies are pinned in `flake.lock`. The local ROM identities are recorded as historical SHA-1 constants in `src/core/rom.zig`; no asset bytes or disassembly listings are published here.

## Local ROM evidence

Addresses below refer to the admitted 32 KiB interleaved music image, not arbitrary ROM revisions.

| Location                                              | Observed role                                               | What it supports                                             |
| ----------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------ |
| `0x21ee`                                              | Reset entry and startup checks                              | Original sound program is executing                          |
| `0x2120`, dispatch table `0x21de`                     | IRQ command handling using the low two command bits         | Death, driving, intro and stop are original commands         |
| Around `0x24a2–0x251e`                                | Eight-voice phase advancement, waveform lookup and mixing   | Software synthesis rather than recorded-track playback       |
| `0x73fe–0x7724`                                       | Death-cue score/event region                                | A substantial fixed arrangement exists                       |
| Around `0x2624–0x264a`                                | Phase-dependent choice among score pointers                 | Timing/state can affect musical selection                    |
| Around `0x26d6–0x26fe`, state at RAM `0x1c036`        | Bit selection, index adjustment and masked frequency lookup | Algorithmic variation in the solo section                    |
| Score near `0x7726`, companion state at RAM `0x1c034` | Accompanying event sequence                                 | Generated variation is combined with stored musical material |

A 240-second emulated run sampled the solo index once per second. It observed 131 samples in the solo region, 21 sampled index transitions and 10 distinct sampled indices. These are coarse trace observations, not exact note counts or proof that each performance is unique. No fresh entropy source was identified. Given the same reset state and command timing, the emulator should reproduce the same program behavior; phase-dependent variation does not require nondeterministic randomness.

On the game side, the main CPU queues sound numbers and writes up to three per frame to SSIO latches 1–3 (ports `1Dh`–`1Fh`), then toggles bit 7 of latch 0 (port `1Ch`) as a strobe. The main program's sound-test table (page `cpu_pg5.11d`, just after the menu strings) pairs each menu entry with a start number, a duration in frames and a stop number. Entry 12, MACHINE GUNS, is start `0x22`, 40 frames, stop `0x23`. Entry 7, EXPLOSION, is `0x19`/`0x1a`.

The game's fire routine (main CPU around `0x23cc`) polls the fire button, sends `0x22` once when firing begins and `0x23` on release; there is no minimum burst. After `0x23` the effects program lets the current shot finish. With the owned ROM, a press followed by a stop after N ms produced 1 burst below 100 ms, 2 bursts from 100 to 180 ms and 3 from 190 ms (bursts about 93 ms apart). Arcade tap is a reported two-shot "tsch-tsch", so terminals without key releases fire for 0.14 s per keystroke.

An earlier version of this player sent `0x19`/`0x1a` (25/26) for guns, misreading an explosion call site around `0x4eb2`. "A muddled low-frequency static mess" instead of the arcade's tight "tsch, tsch, tsch" was heard. Register traces explain the difference: `0x19` drives only AY tone channels near 50 Hz, whereas `0x22` repeats AY noise bursts about every 93 ms while active and `0x23` silences it within one frame. Resending `0x22` during autorepeat made the burst spacing irregular (100–132 ms), so the player sends one start per held run and stops on key release, or 0.14 s after a keystroke where the terminal reports no releases.

## Playback policy and fidelity limits

The player completes the original SSIO self-test handshake, executes startup without audible output, and restarts the music. Music commands 0, 1, 2 and 3 correspond to death, driving, intro and stop. Pressing `d` sends 0 and schedules 1 after eight seconds. That resumption delay is our controller's policy, informed by the observed cue duration; it is not a complete model of the original game's life/death state.

The original program generates the notes. The adapter's mono music/effects balance and simple DC blocker approximate the output stage. Exact analog filtering, cabinet speaker response and stereo presentation have not been modeled. Human listening and comparison to real arcade hardware remain the appropriate next checks for sound quality.

## Verification record

Native Linux x86_64 and M4 macOS builds passed all six suites and native Nix flake checks on October 2, 2026. The owned ROMs passed admission and booted on both platforms with matching post-boot CPU PCs and DAC-write counts. A Linux interactive dummy-audio run accepted guns, death and quit without leaving the terminal in raw mode. Both default audio devices opened and closed successfully without queued sound.

FFprobe independently identified a rendered file as ten seconds of 48 kHz mono signed 16-bit PCM, 960,044 bytes including its WAV header. Comparing native Linux and Mac renders found 81 differing samples out of 480,000, a maximum difference of one PCM step and an RMS difference of 0.012990 PCM steps. Minor floating-point rounding is a plausible explanation, not a separately proven cause. Do not use a shared cross-platform audio hash as an acceptance criterion without first specifying numeric reproducibility requirements.

The ROM-independent suite also caught an interrupt-clear bug before delivery: a data-bus macro overwrote the Z80 interrupt-clear side effect. The synthetic test expected seven or eight interrupts over 10 ms from the board clock, observed 235 before the fix, and passed after the read was evaluated separately. This regression protects the timing model without storing game code.

The macOS PTY test initially treated the kernel's transient `PENDIN` bit as an altered terminal setting. [Apple's termios definition](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/termios.h) identifies it as pending-input state. The corrected test excludes only that transient bit while still checking terminal settings and signal-handler restoration.

## Unresolved

- Compare long-run musical pacing and tonal balance against an arcade/oracle recording without distributing either recording.
- Execute the configured Linux aarch64 target on native hardware before claiming it tested.
