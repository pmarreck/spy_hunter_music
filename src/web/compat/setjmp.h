/* setjmp.h shim for the wasm32 build only (wasi-libc requires the exception-
 * handling proposal for real setjmp). Musashi calls setjmp() as a bus-error
 * trap point in m68k_execute; the matching longjmp() fires only from
 * m68k_pulse_bus_error(), which this 68000 board never calls (address-error
 * emulation is off). If it ever were reached, trap instead of corrupting. */
#ifndef SPY_HUNTER_WASM_SETJMP_H
#define SPY_HUNTER_WASM_SETJMP_H
typedef int jmp_buf[1];
#define setjmp(env) ((void)(env), 0)
#define longjmp(env, value) ((void)(env), (void)(value), __builtin_trap())
#endif
