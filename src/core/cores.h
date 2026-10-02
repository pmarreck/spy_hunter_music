/* Declarations of the C emulator cores the Zig board drives: Musashi (68000)
 * and floooh/chips (Z80, AY-3-8910). Translated for Zig by build.zig. */
#include <stdint.h>
#include <stdbool.h>
#include "m68k.h"
#include "z80.h"
#include "ay38910.h"
/* chips' AY volume table is static inside the implementation unit. */
float sh_ay_volume(unsigned int index);
