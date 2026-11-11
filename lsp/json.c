#include "json.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *p, *end;
  allocfn a;
} reader;

static void skip(reader *r) {
  while (r->p < r->end && (*r->p == ' ' || *r->p == '\t' || *r->p == '\n' || *r->p == '\r')) r->p++;
}

static void push_utf8(buf *b, unsigned c) {
  char u[4];
  size_t n;
  if (c < 0x80) u[0] = (char)c, n = 1;
  else if (c < 0x800) u[0] = (char)(0xc0 | c >> 6), u[1] = (char)(0x80 | (c & 0x3f)), n = 2;
  else if (c < 0x10000)
    u[0] = (char)(0xe0 | c >> 12), u[1] = (char)(0x80 | (c >> 6 & 0x3f)), u[2] = (char)(0x80 | (c & 0x3f)), n = 3;
  else
    u[0] = (char)(0xf0 | c >> 18), u[1] = (char)(0x80 | (c >> 12 & 0x3f)), u[2] = (char)(0x80 | (c >> 6 & 0x3f)),
    u[3] = (char)(0x80 | (c & 0x3f)), n = 4;
  buf_add(b, u, n);
}

static int hex4(reader *r, unsigned *out) {
  if (r->end - r->p < 4) return 0;
  unsigned v = 0;
  for (int i = 0; i < 4; i++) {
    char c = *r->p++;
    v <<= 4;
    if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
    else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
    else return 0;
  }
  *out = v;
  return 1;
}

static int string(reader *r, char **out, size_t *len) {
  if (r->p >= r->end || *r->p != '"') return 0;
  r->p++;
  buf b = buf_new(r->a);
  while (r->p < r->end && *r->p != '"') {
    char c = *r->p++;
    if (c != '\\') {
      mList_push(b.bytes, c);
      continue;
    }
    if (r->p >= r->end) return 0;
    char e = *r->p++;
    switch (e) {
    case '"': case '\\': case '/': mList_push(b.bytes, e); break;
    case 'b': mList_push(b.bytes, '\b'); break;
    case 'f': mList_push(b.bytes, '\f'); break;
    case 'n': mList_push(b.bytes, '\n'); break;
    case 'r': mList_push(b.bytes, '\r'); break;
    case 't': mList_push(b.bytes, '\t'); break;
    case 'u': {
      unsigned c1;
      if (!hex4(r, &c1)) return 0;
      /* a surrogate pair is one character */
      if (c1 >= 0xd800 && c1 < 0xdc00 && r->end - r->p >= 6 && r->p[0] == '\\' && r->p[1] == 'u') {
        r->p += 2;
        unsigned c2;
        if (!hex4(r, &c2)) return 0;
        c1 = 0x10000 + ((c1 - 0xd800) << 10) + (c2 - 0xdc00);
      }
      push_utf8(&b, c1);
      break;
    }
    default: return 0;
    }
  }
  if (r->p >= r->end) return 0;
  r->p++;
  *len = buf_len(&b);
  mList_push(b.bytes, 0);
  *out = buf_data(&b);
  return 1;
}

static int value(reader *r, json *out) {
  memset(out, 0, sizeof *out);
  skip(r);
  if (r->p >= r->end) return 0;
  char c = *r->p;
  if (c == '"') {
    out->kind = JSON_STRING;
    return string(r, &out->string, &out->len);
  }
  if (c == '{' || c == '[') {
    int obj = c == '{';
    char close = obj ? '}' : ']';
    out->kind = obj ? JSON_OBJECT : JSON_ARRAY;
    r->p++;
    mList(json) items = mList_init(r->a, json);
    mList(char *) keys = mList_init(r->a, char *);
    skip(r);
    if (r->p < r->end && *r->p == close) {
      r->p++;
      return 1;
    }
    for (;;) {
      if (obj) {
        skip(r);
        char *k;
        size_t kl;
        if (!string(r, &k, &kl)) return 0;
        mList_push(keys, k);
        skip(r);
        if (r->p >= r->end || *r->p++ != ':') return 0;
      }
      json item;
      if (!value(r, &item)) return 0;
      mList_push(items, item);
      skip(r);
      if (r->p >= r->end) return 0;
      if (*r->p == ',') {
        r->p++;
        continue;
      }
      if (*r->p++ != close) return 0;
      out->items = mList_arr(items);
      out->keys = obj ? mList_arr(keys) : NULL;
      out->count = mList_len(items);
      return 1;
    }
  }
  if (r->end - r->p >= 4 && !memcmp(r->p, "true", 4)) return out->kind = JSON_BOOL, out->boolean = 1, r->p += 4, 1;
  if (r->end - r->p >= 5 && !memcmp(r->p, "false", 5)) return out->kind = JSON_BOOL, r->p += 5, 1;
  if (r->end - r->p >= 4 && !memcmp(r->p, "null", 4)) return out->kind = JSON_NULL, r->p += 4, 1;
  /* a number */
  char tmp[64];
  size_t n = 0;
  while (r->p < r->end && n < sizeof tmp - 1 && strchr("+-.eE0123456789", *r->p)) tmp[n++] = *r->p++;
  if (n == 0) return 0;
  tmp[n] = 0;
  out->kind = JSON_NUMBER;
  out->number = strtod(tmp, NULL);
  return 1;
}

json *json_parse(allocfn a, const char *text, size_t len) {
  reader r = {text, text + len, a};
  json *v = acreate(a, json);
  return value(&r, v) ? v : NULL;
}

const json *json_get(const json *obj, const char *key) {
  if (!obj || obj->kind != JSON_OBJECT) return NULL;
  for (size_t i = 0; i < obj->count; i++)
    if (!strcmp(obj->keys[i], key)) return &obj->items[i];
  return NULL;
}

const json *json_at(const json *v, ...) {
  va_list ap;
  va_start(ap, v);
  for (const char *k; v && (k = va_arg(ap, const char *));) v = json_get(v, k);
  va_end(ap);
  return v;
}

const char *json_str(const json *v) { return v && v->kind == JSON_STRING ? v->string : NULL; }

long json_int(const json *v, long fallback) { return v && v->kind == JSON_NUMBER ? (long)v->number : fallback; }

void buf_add(buf *b, const char *s, size_t n) { List_appendFromArr((List *)b->bytes, s, (List_index_t)n, 1); }

void buf_printf(buf *b, const char *fmt, ...) {
  va_list ap, ap2;
  va_start(ap, fmt);
  va_copy(ap2, ap);
  int n = vsnprintf(NULL, 0, fmt, ap);
  va_end(ap);
  if (n > 0) {
    /* room for vsnprintf's NUL, which isn't kept */
    size_t at = buf_len(b);
    List_resize((List *)b->bytes, (List_index_t)(at + (size_t)n + 1), 1);
    vsnprintf(buf_data(b) + at, (size_t)n + 1, fmt, ap2);
    mList_len(b->bytes) = (List_index_t)(at + (size_t)n);
  }
  va_end(ap2);
}

void buf_str(buf *b, const char *s, size_t n) {
  buf_lit(b, "\"");
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"') buf_lit(b, "\\\"");
    else if (c == '\\') buf_lit(b, "\\\\");
    else if (c == '\n') buf_lit(b, "\\n");
    else if (c == '\r') buf_lit(b, "\\r");
    else if (c == '\t') buf_lit(b, "\\t");
    else if (c < 0x20) buf_printf(b, "\\u%04x", c);
    else buf_add(b, &s[i], 1);
  }
  buf_lit(b, "\"");
}
