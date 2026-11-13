#pragma once
#include "../zig-pkg/c_wheels-0.0.0-0JVaAlKpBADrsLoTHAVkYX7Ss3_9JRX7mlN4DsFw4mGY/macros.h"
typedef struct nothing_t {
} nothing_t;
typedef enum : unsigned char {
  MathKind_ADD,
  MathKind_SUB,
  MathKind_MUL,
  MathKind_DIV,
  MathKind_MOD,
  MathKind_BAND,
  MathKind_BOR,
  MathKind_BXOR,
  MathKind_SHL,
  MathKind_SHR,
  MathKind_EQ,
  MathKind_NE,
  MathKind_LT,
  MathKind_GT,
  MathKind_LE,
  MathKind_GE,
  MathKind_AND,
  MathKind_OR,
  MathKind_XOR,
  MathKind_CMP,
} mathKind;
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
