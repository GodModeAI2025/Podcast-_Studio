/*
 * Hand-written config.h for building LAME 3.100 as a SwiftPM C target
 * (iOS, macOS arm64/x86_64 and Linux for CI). Replaces the autoconf output.
 */
#ifndef PODSTUDIO_LAME_CONFIG_H
#define PODSTUDIO_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_LIMITS_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1

/* Portable float tricks used by the quantizer (IEEE754 on all targets). */
#define TAKEHIRO_IEEE754_HACK 1
#define USE_FAST_LOG 1

/* No decoder (mpglib) and no SIMD paths: encoder only, plain C. */
#undef HAVE_MPGLIB
#undef DECODE_ON_THE_FLY
#undef HAVE_XMMINTRIN_H
#undef HAVE_NASM
#undef MMX_choose_table

/* Fixed-width types come from <stdint.h>; only LAME's float aliases are needed. */
#include <stdint.h>
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;

#define PACKAGE "lame"
#define PACKAGE_NAME "lame"
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"
#define PROTOTYPES 1

#endif
