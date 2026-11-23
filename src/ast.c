// TODO
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

typedef struct FileItem FileItem;
typedef struct SrcRef SrcRef;
typedef struct Ast Ast;

struct SrcRef {
  const FileItem *src;
  ui off, len;
};
tu_def(
    (Ast, uc),
    (Ast_nil, SrcRef),
    (Ast_str, SrcRef),
    (Ast_num, SrcRef),
    (Ast_id, SrcRef),
    (Ast_call, struct { //
      ull len;
      Ast *ptr;
    }),
);
