#pragma once
#include "../zig-pkg/c_wheels-0.0.0-0JVaAlKpBADrsLoTHAVkYX7Ss3_9JRX7mlN4DsFw4mGY/macros.h"

typedef unsigned char uc;
typedef unsigned short us;
typedef unsigned int ui;
typedef unsigned long ul;
typedef unsigned long long ull;
typedef signed char sc;
typedef signed short ss;
typedef signed int si;
typedef signed long sl;
typedef signed long long sll;

typedef struct nothing_t {
} nothing_t;
#define mathKindsS      \
  (add,                 \
   sub,                 \
   mul,                 \
   div,                 \
   mod,                 \
   band,                \
   bor,                 \
   bxor,                \
   shl,                 \
   shr, /*change type*/ \
   eq,                  \
   ne,                  \
   lt,                  \
   gt,                  \
   le,                  \
   ge,                  \
   and,                 \
   or,                  \
   xor,                 \
   cmp)

typedef enum : uc {
  #define mathkind_member(x) MathKind_##x
  APPLY_N_C(mathkind_member, REMOVE_PARENS(mathKindsS))
  #undef mathkind_member
} mathKind;

typedef enum : uc {
  MOV_VV,
  MOV_VP,
  MOV_PV,
  MOV_PP,
} movKind;

typedef ui Reg;
static const Reg Reg_term = (~(Reg)0);
static inline ull Reg_term_len(const Reg term[]) {
  ull res = 0;
  while (term[res] != Reg_term)
    res++;
  return res;
}
tu_def(
    (Ir_node, uc),
    (Ir_mov, struct { //
      movKind kind;
      Reg l, r;
      ull size;
    }),
    (Ir_rom, struct { //
      Reg d;
      ull off;
    }),
    (Ir_math, struct { // only integers and pointers
      mathKind op;
      Reg l,
          r,
          d;
    }),
    (Ir_cast, struct { Reg l, d; }),
    (Ir_fn, struct { //
      ul fnid;
      Reg d;
    }),
    (Ir_call, struct { //
      Reg fn;
      Reg d;
      Reg *args;
    }),
    (Ir_arg, struct { //
      uc idx;
      Reg d;
    }),
    (Ir_ret, Reg),
    (Ir_ldp, struct { Reg l, d; }),
    (Ir_if, Reg),
    (Ir_else, nothing_t),
    (Ir_endif, nothing_t),
    (Ir_loop, nothing_t),
    (Ir_repeat, ui),
    (Ir_endloop, nothing_t),
    (Ir_c, struct { //
      Reg d;
      struct {
        ull len;
        const uc *ptr;
      } sring;
    })
);
