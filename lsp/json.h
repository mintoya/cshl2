/* A small JSON reader and writer, enough for the language server protocol.
 * Everything is allocated from the allocator it's given: parse a message
 * into an arena and drop the arena with it. */
#ifndef CSHL_LSP_JSON_H
#define CSHL_LSP_JSON_H

#include "allocator.h"
#include "mylist.h"

#include <stddef.h>

typedef enum { JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT } json_kind;

typedef struct json json;
struct json {
  json_kind kind;
  double number;
  int boolean;
  /* a string, unescaped, NUL-terminated */
  char *string;
  size_t len;
  /* an array's items, or an object's values, with keys[i] for values[i] */
  json *items;
  char **keys;
  size_t count;
};

/* Parses text[0..len] with everything allocated from a; NULL if it isn't
   JSON. */
json *json_parse(allocfn a, const char *text, size_t len);

/* obj[key], or NULL */
const json *json_get(const json *obj, const char *key);
/* the path of keys, one after another: json_at(v, "params", "textDocument", "uri", NULL) */
const json *json_at(const json *v, ...);
const char *json_str(const json *v); /* NULL unless a string */
long json_int(const json *v, long fallback);

/* An output buffer: a list of bytes. */
typedef struct {
  mList(char) bytes;
} buf;

static inline buf buf_new(allocfn a) { return (buf){mList_init(a, char)}; }
static inline char *buf_data(buf *b) { return mList_arr(b->bytes); }
static inline size_t buf_len(buf *b) { return mList_len(b->bytes); }

void buf_add(buf *b, const char *s, size_t n);
/* a string literal, its length taken from the literal */
#define buf_lit(b, lit) buf_add((b), (lit), sizeof(lit) - 1)
void buf_printf(buf *b, const char *fmt, ...);
/* s[0..n] as a JSON string, quotes included */
void buf_str(buf *b, const char *s, size_t n);

#endif
