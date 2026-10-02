/* Single implementation unit for the header-only floooh/chips cores
 * (zlib/libpng license), plus the accessor the Zig board needs. */
#define CHIPS_IMPL
#include "z80.h"
#include "ay38910.h"

float sh_ay_volume(unsigned int index) { return index < 16 ? _ay38910_volumes[index] : 0.0f; }
