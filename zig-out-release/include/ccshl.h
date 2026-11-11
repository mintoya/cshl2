/* The ccshl compiler as a library, for plugins: outside programs that watch a
 * compilation and keep what they want from it (a map of types by source
 * location, uses of names, ...). Link libccshl.a, libtree-sitter and libc.
 *
 * cshl_compile runs a file and calls the handler with each message as it
 * happens. Every binding gets an id; a use says which binding it found. Only
 * code that ran sends messages: a function that's never called has none.
 * Everything a message points to stays valid until cshl_free. */
#ifndef CCSHL_H
#define CCSHL_H

#include <stddef.h>
#include <stdint.h>

typedef struct cshl cshl;

typedef enum {
  CSHL_BIND = 0,  /* a name bound */
  CSHL_USE = 1,   /* a name, or a struct member, used */
  CSHL_ERROR = 2, /* compilation failed; name is the message */
  CSHL_TRACE = 3, /* after CSHL_ERROR, one per call the error came through,
                     innermost first: where the function, macro or import
                     was called from */
} cshl_kind;

typedef struct {
  cshl_kind kind;
  /* the binding bound, or the one a use found; 0 for a use of something
     never reported, like the builtin operators */
  uint64_t id;
  /* for CSHL_BIND: the binding this one is another name for, or 0: a copy
     @using made, or an alias `x <~ y` */
  uint64_t origin;
  /* for CSHL_BIND, the name; for CSHL_ERROR, the message */
  const char *name;
  size_t name_len;
  /* where: the file's path and a byte range in it. file_len is 0 for code
     that isn't in a file, built by quotes */
  const char *file;
  size_t file_len;
  uint32_t offset, length;
  /* for CSHL_BIND: the type of the value */
  uint64_t type;
  /* for CSHL_BIND, when the value is a type (`T <~ @struct{...}`): that
     type; 0 otherwise */
  uint64_t holds;
} cshl_message;

typedef void (*cshl_handler)(void *ctx, const cshl_message *msg);

/* Runs the file at path; with lower nonzero, lowers it as for C output
   instead of only interpreting it. NULL only when out of memory. */
cshl *cshl_compile(const char *path, int lower, cshl_handler handler, void *ctx);
/* Whether it failed; the handler got a CSHL_ERROR if so. */
int cshl_failed(cshl *s);
void cshl_free(cshl *s);

/* Types are opaque handles. */
typedef enum {
  CSHL_TYPE_VOID,
  CSHL_TYPE_BOOL,
  CSHL_TYPE_TYPE,
  CSHL_TYPE_AST,
  CSHL_TYPE_ANY,
  CSHL_TYPE_INT, /* a compile-time integer */
  CSHL_TYPE_CINT,
  CSHL_TYPE_BUILTIN,
  CSHL_TYPE_POINTER,
  CSHL_TYPE_STRUCT,
  CSHL_TYPE_FUNCTION, /* compile-time */
  CSHL_TYPE_FNPTR,
  CSHL_TYPE_ARRAY,
  CSHL_TYPE_OPAQUE, /* a C type by name */
} cshl_type_kind_t;

cshl_type_kind_t cshl_type_kind(cshl *s, uint64_t type);
/* as errors print it; formatted once per type, valid until cshl_free */
const char *cshl_type_name(cshl *s, uint64_t type, size_t *len);
int cshl_type_is_ref(uint64_t type);
int cshl_type_is_comptime(uint64_t type);
/* what a pointer points to, or an array's elements; 0 otherwise */
uint64_t cshl_type_pointee(cshl *s, uint64_t type);
/* a struct's member count, an array's length, a function's parameter count */
size_t cshl_type_len(cshl *s, uint64_t type);
/* struct member i, or function parameter i; 0 past the end */
uint64_t cshl_type_member(cshl *s, uint64_t type, size_t i);
const char *cshl_type_member_name(cshl *s, uint64_t type, size_t i, size_t *len);
/* struct member i's value when it's a type (`Self <~ @this()`); 0 otherwise */
uint64_t cshl_type_member_holds(cshl *s, uint64_t type, size_t i);
/* a function's result; 0 otherwise */
uint64_t cshl_type_result(cshl *s, uint64_t type);

#endif
