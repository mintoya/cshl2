#pragma once
#include "../zig-pkg/c_wheels-0.0.0-0JVaAlKpBADrsLoTHAVkYX7Ss3_9JRX7mlN4DsFw4mGY/macros.h"
typedef struct nothing_t {
} nothing_t;
#define mathKindsS \
  (add, sub, mul, div, mod, band, bor, bxor, shl, shr, eq, ne, lt, gt, le, ge, and, or, xor, cmp)

typedef enum : unsigned char {
  #define mathkind_member(x) MathKind_##x
  APPLY_N_C(mathkind_member, REMOVE_PARENS(mathKindsS))
  #undef mathkind_member
} mathKind;

static const struct {
  #define mathkind_member(name) \
  mathKind name;
  APPLY_N(mathkind_member, REMOVE_PARENS(mathKindsS))
  #undef mathkind_member
} mathKinds = {
  #define mathkind_member(name) \
  .name = MathKind_##name,
    APPLY_N(mathkind_member, REMOVE_PARENS(mathKindsS))
  #undef mathkind_member
};
typedef enum : unsigned char {
  MOV_VV,
  MOV_VP,
  MOV_PV,
  MOV_PP,
} movKind;

typedef unsigned int Reg;
tu_def(
    (Ir_node, unsigned char),
    (Ir_mov, struct { //
      movKind kind;
      Reg l, r;
      unsigned long long size;
    }),
    (Ir_rom, struct { //
      Reg d;
      unsigned long long off;
    }),
    (Ir_math, struct { // only integers and pointers
      mathKind op;
      Reg l;
      Reg r;
      Reg d;
    }),
    (Ir_cast, struct { Reg l, d; }),
    (Ir_fn, struct { //
      unsigned long fnid;
      Reg d;
    }),
    (Ir_call, struct { //
      Reg fn;
      Reg d;
      Reg *args;
    }),
    (Ir_arg, struct { //
      unsigned char idx;
      Reg d;
    }),
    (Ir_ret, Reg),
    (Ir_ldp, struct { Reg l, d; }),
    (Ir_if, Reg),
    (Ir_else, nothing_t),
    (Ir_endif, nothing_t),
    (Ir_loop, nothing_t),
    (Ir_repeat, unsigned int),
    (Ir_endloop, nothing_t),
    (Ir_c, struct { //
      Reg d;
      struct {
        unsigned long len;
        const unsigned char *ptr;
      } sring;
    })
);
