/* cshl-lsp: a language server for cshl, over libccshl.
 *
 * It compiles a document when it's opened or saved, keeps what the compiler
 * reported (every binding with its type, every use with the binding it
 * found, the error), and answers from that: diagnostics, hover, definition,
 * references and document symbols. Only code that ran is known, so a
 * function that's never called has nothing.
 *
 * It speaks JSON-RPC over stdin and stdout; logs go to stderr. */
/* realpath; defined as wheels defines it, so they agree */
#define _GNU_SOURCE
#include "ccshl.h"
#include "json.h"

#include "allocator.h"
#include "allocators/arenaAllocator.h"
#include "fptr.h"
#include "hxmap.h"
#include "mylist.h"
#include "print.h"
#include "smap.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* ------------------------------------------------------------ files */

/* lives as long as the server: paths, documents */
static allocfn server;
/* lives while one message is handled: its JSON, and what's written back */
static allocfn req;

static char *dup_str(allocfn a, const char *s, size_t n) {
  char *d = (char *)acreate_extra(a, char, n + 1);
  memcpy(d, s, n);
  d[n] = 0;
  return d;
}

/* a file's text and where its lines start, read when needed */
typedef struct {
  char *text;
  size_t len;
  mList(size_t) lines;
} file_t;

/* by path; dropped with their arena when a compile starts, since files may
   have changed on disk */
static allocfn files_arena;
static msxmap(file_t) files;

static void forget_files(void) {
  if (files) msxmap_deinit(files), arena_cleanup(files_arena);
  files_arena = arena_new_ext(server, 1 << 16);
  files = msxmap_init(files_arena, file_t);
}

static file_t *file_get(const char *path) {
  file_t *have = msxmap_get(files, (char *)path);
  if (have) return have;
  file_t f = {0};
  FILE *fh = fopen(path, "rb");
  if (fh) {
    fseek(fh, 0, SEEK_END);
    long n = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    f.text = (char *)acreate_extra(files_arena, char, (size_t)(n > 0 ? n : 0) + 1);
    f.len = fread(f.text, 1, (size_t)(n > 0 ? n : 0), fh);
    f.text[f.len] = 0;
    fclose(fh);
  } else f.text = dup_str(files_arena, "", 0);
  f.lines = mList_init(files_arena, size_t);
  mList_push(f.lines, 0);
  for (size_t i = 0; i < f.len; i++)
    if (f.text[i] == '\n') mList_push(f.lines, i + 1);
  return msxmap_set(files, (char *)path, f);
}

/* LSP positions count UTF-16 code units in a line */
static void to_position(file_t *f, size_t off, long *line, long *character) {
  size_t *lines = mList_arr(f->lines);
  size_t lo = 0, hi = mList_len(f->lines);
  while (hi - lo > 1) {
    size_t mid = (lo + hi) / 2;
    if (lines[mid] <= off) lo = mid;
    else hi = mid;
  }
  *line = (long)lo;
  long c = 0;
  for (size_t i = lines[lo]; i < off && i < f->len;) {
    unsigned char b = (unsigned char)f->text[i];
    size_t n = b < 0x80 ? 1 : b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4;
    c += n == 4 ? 2 : 1;
    i += n;
  }
  *character = c;
}

static size_t to_offset(file_t *f, long line, long character) {
  if (line < 0) return 0;
  if ((size_t)line >= mList_len(f->lines)) return f->len;
  size_t i = mList_arr(f->lines)[line];
  for (long c = 0; c < character && i < f->len && f->text[i] != '\n';) {
    unsigned char b = (unsigned char)f->text[i];
    size_t n = b < 0x80 ? 1 : b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4;
    c += n == 4 ? 2 : 1;
    i += n;
  }
  return i;
}

/* file:// URIs, with %XX escapes */
static char *uri_to_path(allocfn a, const char *uri) {
  if (strncmp(uri, "file://", 7)) return dup_str(a, uri, strlen(uri));
  const char *s = uri + 7;
  char *out = (char *)acreate_extra(a, char, strlen(s) + 1), *o = out;
  for (; *s; s++) {
    if (*s == '%' && s[1] && s[2]) {
      char h[3] = {s[1], s[2], 0};
      *o++ = (char)strtol(h, NULL, 16);
      s += 2;
    } else *o++ = *s;
  }
  *o = 0;
  return out;
}

static void add_uri(buf *b, const char *path) {
  buf c = buf_new(req);
  buf_lit(&c, "file://");
  for (const char *s = path; *s; s++) {
    unsigned char ch = (unsigned char)*s;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || strchr("/-_.~", ch))
      buf_add(&c, s, 1);
    else buf_printf(&c, "%%%02X", ch);
  }
  buf_str(b, buf_data(&c), buf_len(&c));
}

static void add_range(buf *b, const char *path, size_t off, size_t len) {
  file_t *f = file_get(path);
  long l1, c1, l2, c2;
  to_position(f, off, &l1, &c1);
  to_position(f, off + len, &l2, &c2);
  buf_printf(b, "{\"start\":{\"line\":%ld,\"character\":%ld},\"end\":{\"line\":%ld,\"character\":%ld}}", l1, c1, l2, c2);
}

static void add_location(buf *b, const char *path, size_t off, size_t len) {
  buf_lit(b, "{\"uri\":");
  add_uri(b, path);
  buf_lit(b, ",\"range\":");
  add_range(b, path, off, len);
  buf_lit(b, "}");
}

/* canonical paths, interned so they compare by pointer */
static msxmap(char *) paths;

static char *intern_path(const char *raw, size_t len) {
  char tmp[PATH_MAX], real[PATH_MAX];
  if (len >= sizeof tmp) len = sizeof tmp - 1;
  memcpy(tmp, raw, len), tmp[len] = 0;
#ifdef _WIN32
  char *p = _fullpath(real, tmp, sizeof real) ? real : tmp;
#else
  char *p = realpath(tmp, real) ? real : tmp;
#endif
  char **have = msxmap_get(paths, p);
  if (have) return *have;
  char *owned = dup_str(server, p, strlen(p));
  msxmap_set(paths, owned, owned);
  return owned;
}

/* ------------------------------------------------------- compilation */

typedef struct {
  uint64_t id, origin, type;
  uint64_t holds; /* the type it holds, when its value is a type */
  const char *name;
  char *file; /* canonical, or NULL for code built by quotes */
  size_t name_len;
  uint32_t off, len;
  size_t uses;
  /* its declaration: an index into doc.decls */
  size_t decl;
} binding;

typedef struct {
  uint64_t id;
  char *file;
  uint32_t off, len;
} use;

/* a call an error came through */
typedef struct {
  char *file;
  uint32_t off, len;
} frame;

/* a declaration, its name where it's written: a local binds once per call,
   so one declaration has many bindings */
typedef struct {
  size_t first; /* its first binding */
  int used;
  mList(uint64_t) types; /* every type it had, once each */
} decl;

/* what identifies a declaration */
typedef struct {
  char *file;
  uint32_t off;
  uint32_t name_len;
  uint64_t name_hash;
} decl_key;

typedef struct {
  char *uri, *path;
  cshl *session; /* keeps the type names */
  /* everything below lives in this, dropped on each compile */
  allocfn arena;
  mList(binding) binds;
  mList(use) uses;
  mList(decl) decls;
  mxmap(decl_key, size_t) decl_of;
  int failed;
  char *error, *error_file;
  uint32_t error_off, error_len;
  mList(frame) trace; /* innermost first */
  /* the last message's file, and its canonical path */
  const char *last_raw;
  size_t last_raw_len;
  char *last_path;
} doc;

static mList(doc *) docs;

static char *message_file(doc *d, const cshl_message *m) {
  if (!m->file_len) return NULL;
  /* messages from one file share its path's memory */
  if (m->file != d->last_raw || m->file_len != d->last_raw_len) {
    d->last_raw = m->file, d->last_raw_len = m->file_len;
    d->last_path = intern_path(m->file, m->file_len);
  }
  return d->last_path;
}

static binding *find_binding(doc *d, uint64_t id) {
  /* ids count up from 1 in order */
  return id && id <= mList_len(d->binds) ? &mList_arr(d->binds)[id - 1] : NULL;
}

static uint64_t hash_name(const char *s, size_t n) {
  uint64_t h = 0xcbf29ce484222325u;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 0x100000001b3u;
  return h;
}

static size_t decl_for(doc *d, binding *b, size_t index) {
  decl_key k = {b->file, b->off, (uint32_t)b->name_len, hash_name(b->name, b->name_len)};
  size_t *have = mxmap_get(d->decl_of, k);
  if (have) return *have;
  size_t n = mList_len(d->decls);
  mList_push(d->decls, (decl){index, 0, mList_init(d->arena, uint64_t)});
  mxmap_set(d->decl_of, k, n);
  return n;
}

static void on_message(void *ctx, const cshl_message *m) {
  doc *d = ctx;
  switch (m->kind) {
  case CSHL_BIND: {
    binding b = {m->id, m->origin, m->type, m->holds, m->name, message_file(d, m), m->name_len, m->offset, m->length, 0, 0};
    b.decl = decl_for(d, &b, mList_len(d->binds));
    decl *dc = &mList_arr(d->decls)[b.decl];
    /* a copy @using made counts as a use of the declaration */
    if (b.origin) dc->used = 1;
    int seen = 0;
    for (size_t i = 0; i < mList_len(dc->types) && !seen; i++) seen = mList_arr(dc->types)[i] == b.type;
    if (!seen) mList_push(dc->types, b.type);
    mList_push(d->binds, b);
    break;
  }
  case CSHL_USE:
    mList_push(d->uses, (use){m->id, message_file(d, m), m->offset, m->length});
    for (binding *b = find_binding(d, m->id); b; b = find_binding(d, b->origin)) {
      b->uses++;
      mList_arr(d->decls)[b->decl].used = 1;
    }
    break;
  case CSHL_ERROR:
    d->failed = 1;
    d->error = dup_str(d->arena, m->name, m->name_len);
    d->error_file = message_file(d, m);
    d->error_off = m->offset, d->error_len = m->length;
    break;
  case CSHL_TRACE:
    if (m->file_len) mList_push(d->trace, (frame){message_file(d, m), m->offset, m->length});
    break;
  }
}

static void forget(doc *d) {
  if (d->session) cshl_free(d->session);
  if (d->arena) arena_cleanup(d->arena);
  d->session = NULL;
  d->arena = NULL;
  d->failed = 0;
  d->last_raw = NULL;
}

static void compile(doc *d) {
  forget(d);
  forget_files();
  d->arena = arena_new_ext(server, 1 << 20);
  d->binds = mList_init(d->arena, binding);
  d->uses = mList_init(d->arena, use);
  d->decls = mList_init(d->arena, decl);
  d->decl_of = mxmap_init(d->arena, decl_key, size_t);
  d->trace = mList_init(d->arena, frame);
  /* lowered, as for C: it reports more than interpreting does, and files
     with @cexpr only work that way */
  d->session = cshl_compile(d->path, 1, on_message, d);
  fprintf(stderr, "cshl-lsp: compiled %s: %zu bindings, %zu uses, %zu declarations%s\n", d->path,
          (size_t)mList_len(d->binds), (size_t)mList_len(d->uses), (size_t)mList_len(d->decls),
          d->failed ? ", failed" : "");
}

static decl *decl_of(doc *d, const binding *b) { return &mList_arr(d->decls)[b->decl]; }

/* ---------------------------------------------------------- protocol */

static void send_msg(buf *body) {
  printf("Content-Length: %zu\r\n\r\n", buf_len(body));
  fwrite(buf_data(body), 1, buf_len(body), stdout);
  fflush(stdout);
}

static void reply(const json *id, buf *result) {
  buf b = buf_new(req);
  buf_lit(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
  if (id && id->kind == JSON_STRING) buf_str(&b, id->string, id->len);
  else buf_printf(&b, "%ld", json_int(id, 0));
  buf_lit(&b, ",\"result\":");
  if (result && buf_len(result)) buf_add(&b, buf_data(result), buf_len(result));
  else buf_lit(&b, "null");
  buf_lit(&b, "}");
  send_msg(&b);
}

static doc *find_doc(const char *uri) {
  if (!uri) return NULL;
  for (size_t i = 0; i < mList_len(docs); i++)
    if (!strcmp(mList_arr(docs)[i]->uri, uri)) return mList_arr(docs)[i];
  return NULL;
}

static void publish(doc *d) {
  buf b = buf_new(req);
  buf_lit(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
  buf_str(&b, d->uri, strlen(d->uri));
  buf_lit(&b, ",\"diagnostics\":[");
  int first = 1;
  if (d->failed) {
    /* where it's shown: the error itself when it's in this file, otherwise
       the innermost call in this file it came through (a library's error
       shows on the line that called into the library) */
    frame at = {d->error_file, d->error_off, d->error_len};
    if (at.file != d->path)
      for (size_t i = 0; i < mList_len(d->trace); i++)
        if (mList_arr(d->trace)[i].file == d->path) {
          at = mList_arr(d->trace)[i];
          break;
        }
    buf_lit(&b, "{\"range\":");
    if (at.file == d->path) add_range(&b, d->path, at.off, at.len);
    else buf_lit(&b, "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}");
    buf_lit(&b, ",\"severity\":1,\"source\":\"cshl\",\"message\":");
    buf c = buf_new(req);
    buf_add(&c, d->error, strlen(d->error));
    if (d->error_file && d->error_file != d->path) {
      long l, ch;
      to_position(file_get(d->error_file), d->error_off, &l, &ch);
      buf_printf(&c, "\n(in %s:%ld:%ld)", d->error_file, l + 1, ch + 1);
    }
    buf_str(&b, buf_data(&c), buf_len(&c));
    /* the error and every call it came through, to jump along */
    buf_lit(&b, ",\"relatedInformation\":[");
    int n = 0;
    if (d->error_file) {
      buf_lit(&b, "{\"location\":");
      add_location(&b, d->error_file, d->error_off, d->error_len);
      buf_lit(&b, ",\"message\":\"error here\"}");
      n++;
    }
    for (size_t i = 0; i < mList_len(d->trace); i++) {
      frame *f = &mList_arr(d->trace)[i];
      if (n++) buf_lit(&b, ",");
      buf_lit(&b, "{\"location\":");
      add_location(&b, f->file, f->off, f->len);
      buf_lit(&b, ",\"message\":\"called from here\"}");
    }
    buf_lit(&b, "]}");
    first = 0;
  }
  /* after a failed compile, what came after the error never ran, so
     nothing can be called unused */
  for (size_t i = 0; !d->failed && i < mList_len(d->decls); i++) {
    decl *dc = &mList_arr(d->decls)[i];
    binding *bd = &mList_arr(d->binds)[dc->first];
    if (dc->used || bd->file != d->path || bd->origin) continue;
    /* names starting with _ are unused on purpose */
    if (bd->name_len && bd->name[0] == '_') continue;
    if (!first) buf_lit(&b, ",");
    first = 0;
    buf_lit(&b, "{\"range\":");
    add_range(&b, d->path, bd->off, bd->len);
    /* severity 2 is a warning; tag 1 is "unnecessary", shown faded */
    buf_lit(&b, ",\"severity\":2,\"tags\":[1],\"source\":\"cshl\",\"message\":");
    buf c = buf_new(req);
    buf_printf(&c, "`%.*s` is never used", (int)bd->name_len, bd->name);
    buf_str(&b, buf_data(&c), buf_len(&c));
    buf_lit(&b, "}");
  }
  buf_lit(&b, "]}}");
  send_msg(&b);
}

/* the binding at a position in d's file: a use's, or a declaration's */
static binding *binding_at(doc *d, const json *params) {
  if (!d->arena) return NULL;
  file_t *f = file_get(d->path);
  size_t off = to_offset(f, json_int(json_at(params, "position", "line", NULL), 0),
                         json_int(json_at(params, "position", "character", NULL), 0));
  for (size_t i = 0; i < mList_len(d->uses); i++) {
    use *u = &mList_arr(d->uses)[i];
    if (u->file == d->path && u->off <= off && off < (size_t)u->off + u->len) {
      binding *b = find_binding(d, u->id);
      if (b) return b;
    }
  }
  for (size_t i = 0; i < mList_len(d->binds); i++) {
    binding *b = &mList_arr(d->binds)[i];
    if (b->file == d->path && b->off <= off && off < (size_t)b->off + b->len) return b;
  }
  return NULL;
}

/* the original of a copy made by @using */
static binding *original(doc *d, binding *b) {
  for (binding *o; b->origin && (o = find_binding(d, b->origin));) b = o;
  return b;
}

static void add_type(buf *t, doc *d, uint64_t T) {
  size_t tl;
  const char *name = cshl_type_name(d->session, T, &tl);
  buf_add(t, name, tl);
}

/* what's in a struct: fields with <-, the namespace with <~ */
static void add_struct(buf *t, doc *d, uint64_t S) {
  size_t n = cshl_type_len(d->session, S), width = 0;
  for (size_t i = 0; i < n; i++) {
    size_t nl;
    cshl_type_member_name(d->session, S, i, &nl);
    if (nl > width) width = nl;
  }
  buf_lit(t, "@struct{\n");
  for (size_t i = 0; i < n; i++) {
    size_t nl;
    const char *name = cshl_type_member_name(d->session, S, i, &nl);
    uint64_t m = cshl_type_member(d->session, S, i);
    uint64_t held = cshl_type_member_holds(d->session, S, i);
    buf_printf(t, "  %.*s%*s %s ", (int)nl, name, (int)(width - nl), "", cshl_type_is_comptime(m) ? "<~" : "<-");
    add_type(t, d, held ? held : m);
    buf_lit(t, ";\n");
  }
  buf_lit(t, "}");
}

static void hover(const json *id, const json *params) {
  doc *d = find_doc(json_str(json_at(params, "textDocument", "uri", NULL)));
  binding *b = d ? binding_at(d, params) : NULL;
  if (!b) return reply(id, NULL);
  binding *orig = original(d, b);
  buf text = buf_new(req);
  buf_lit(&text, "```cshl\n");
  if (orig->holds) {
    /* a type: what it is */
    buf_printf(&text, "%.*s <~ ", (int)b->name_len, b->name);
    if (cshl_type_kind(d->session, orig->holds) == CSHL_TYPE_STRUCT) add_struct(&text, d, orig->holds);
    else add_type(&text, d, orig->holds);
  } else {
    /* a value: every type the declaration had */
    buf_printf(&text, "%.*s: ", (int)b->name_len, b->name);
    decl *dc = decl_of(d, b);
    for (size_t i = 0; i < mList_len(dc->types); i++) {
      if (i) buf_lit(&text, " | ");
      add_type(&text, d, mList_arr(dc->types)[i]);
    }
    /* a struct value, or a place holding one: its insides too */
    uint64_t T = mList_arr(dc->types)[0];
    if (mList_len(dc->types) == 1 && cshl_type_kind(d->session, T) == CSHL_TYPE_STRUCT) {
      buf_lit(&text, "\n");
      add_struct(&text, d, T);
    }
  }
  buf_lit(&text, "\n```");
  if (orig != b && orig->file) buf_printf(&text, "\n\nfrom %s", orig->file);
  buf r = buf_new(req);
  buf_lit(&r, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
  buf_str(&r, buf_data(&text), buf_len(&text));
  buf_lit(&r, "}}");
  reply(id, &r);
}

static void definition(const json *id, const json *params) {
  doc *d = find_doc(json_str(json_at(params, "textDocument", "uri", NULL)));
  binding *b = d ? binding_at(d, params) : NULL;
  if (b) b = original(d, b);
  if (!b || !b->file) return reply(id, NULL);
  buf r = buf_new(req);
  add_location(&r, b->file, b->off, b->len);
  reply(id, &r);
}

static void references(const json *id, const json *params) {
  doc *d = find_doc(json_str(json_at(params, "textDocument", "uri", NULL)));
  binding *b = d ? binding_at(d, params) : NULL;
  if (!b) return reply(id, NULL);
  size_t target = original(d, b)->decl;
  binding *db = &mList_arr(d->binds)[mList_arr(d->decls)[target].first];
  const json *inc = json_at(params, "context", "includeDeclaration", NULL);
  buf r = buf_new(req);
  buf_lit(&r, "[");
  int n = 0;
  if (inc && inc->boolean && db->file) add_location(&r, db->file, db->off, db->len), n++;
  /* a use of any binding of the declaration, or of a copy of it; a place
     used by several runs of the same code once */
  allocfn tmp = arena_new_ext(server, 1 << 12);
  mxmap(uint64_t, int) seen = mxmap_init(tmp, uint64_t, int);
  for (size_t i = 0; i < mList_len(d->uses); i++) {
    use *u = &mList_arr(d->uses)[i];
    binding *ub = find_binding(d, u->id);
    if (!ub || !u->file || original(d, ub)->decl != target) continue;
    uint64_t at = ((uint64_t)(uintptr_t)u->file << 32) ^ u->off;
    if (mxmap_get(seen, at)) continue;
    mxmap_set(seen, at, 1);
    if (n++) buf_lit(&r, ",");
    add_location(&r, u->file, u->off, u->len);
  }
  mxmap_deinit(seen);
  arena_cleanup(tmp);
  buf_lit(&r, "]");
  reply(id, &r);
}

static void symbols(const json *id, const json *params) {
  doc *d = find_doc(json_str(json_at(params, "textDocument", "uri", NULL)));
  if (!d || !d->arena) return reply(id, NULL);
  buf r = buf_new(req);
  buf_lit(&r, "[");
  int n = 0;
  for (size_t i = 0; i < mList_len(d->decls); i++) {
    binding *b = &mList_arr(d->binds)[mList_arr(d->decls)[i].first];
    if (b->file != d->path || b->origin) continue;
    /* SymbolKind: 12 function, 23 struct, 13 variable */
    int kind;
    switch (cshl_type_kind(d->session, b->type)) {
    case CSHL_TYPE_FUNCTION: case CSHL_TYPE_FNPTR: kind = 12; break;
    case CSHL_TYPE_TYPE: kind = 23; break;
    default: kind = 13;
    }
    if (n++) buf_lit(&r, ",");
    buf_lit(&r, "{\"name\":");
    buf_str(&r, b->name, b->name_len);
    buf_printf(&r, ",\"kind\":%d,\"location\":", kind);
    add_location(&r, b->file, b->off, b->len);
    buf_lit(&r, "}");
  }
  buf_lit(&r, "]");
  reply(id, &r);
}

static void open_doc(const json *params) {
  const char *uri = json_str(json_at(params, "textDocument", "uri", NULL));
  if (!uri) return;
  doc *d = find_doc(uri);
  if (!d) {
    d = acreate(server, doc);
    d->uri = dup_str(server, uri, strlen(uri));
    char *p = uri_to_path(server, uri);
    d->path = intern_path(p, strlen(p));
    mList_push(docs, d);
  }
  compile(d);
  publish(d);
}

static void close_doc(const json *params) {
  doc *d = find_doc(json_str(json_at(params, "textDocument", "uri", NULL)));
  if (!d) return;
  forget(d);
  /* clear its diagnostics */
  buf b = buf_new(req);
  buf_lit(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
  buf_str(&b, d->uri, strlen(d->uri));
  buf_lit(&b, ",\"diagnostics\":[]}}");
  send_msg(&b);
  for (size_t i = 0; i < mList_len(docs); i++)
    if (mList_arr(docs)[i] == d) {
      mList_rem(docs, i);
      break;
    }
}

static const char capabilities[] =
    "{\"capabilities\":{"
    /* open and close, full text on change (not compiled yet), save */
    "\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":false}},"
    "\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,"
    "\"documentSymbolProvider\":true},"
    "\"serverInfo\":{\"name\":\"cshl-lsp\"}}";

/* one message's body, read after its headers into req; NULL at the end of
   input */
static char *read_message(size_t *len) {
  size_t length = 0;
  char line[1024];
  for (;;) {
    if (!fgets(line, sizeof line, stdin)) return NULL;
    if (!strcmp(line, "\r\n") || !strcmp(line, "\n")) break;
    if (!strncasecmp(line, "Content-Length:", 15)) length = strtoul(line + 15, NULL, 10);
  }
  char *body = (char *)acreate_extra(req, char, length + 1);
  if (fread(body, 1, length, stdin) != length) return NULL;
  body[length] = 0;
  *len = length;
  return body;
}

int main(void) {
  server = stdAlloc;
  paths = msxmap_init(server, char *);
  docs = mList_init(server, doc *);
  forget_files();
  int shutting_down = 0;
  for (;;) {
    if (req) arena_cleanup(req);
    req = arena_new_ext(server, 1 << 16);
    size_t len;
    char *body = read_message(&len);
    if (!body) break;
    json *msg = json_parse(req, body, len);
    if (!msg) continue;
    const char *method = json_str(json_get(msg, "method"));
    const json *id = json_get(msg, "id");
    const json *params = json_get(msg, "params");
    if (!method) {
    } else if (!strcmp(method, "initialize")) {
      buf r = buf_new(req);
      buf_add(&r, capabilities, sizeof capabilities - 1);
      reply(id, &r);
    } else if (!strcmp(method, "shutdown")) {
      shutting_down = 1;
      reply(id, NULL);
    } else if (!strcmp(method, "exit")) {
      return shutting_down ? 0 : 1;
    } else if (!strcmp(method, "textDocument/didOpen") || !strcmp(method, "textDocument/didSave")) {
      open_doc(params);
    } else if (!strcmp(method, "textDocument/didClose")) {
      close_doc(params);
    } else if (!strcmp(method, "textDocument/hover")) {
      hover(id, params);
    } else if (!strcmp(method, "textDocument/definition")) {
      definition(id, params);
    } else if (!strcmp(method, "textDocument/references")) {
      references(id, params);
    } else if (!strcmp(method, "textDocument/documentSymbol")) {
      symbols(id, params);
    } else if (id) {
      /* a request it doesn't know: MethodNotFound */
      buf b = buf_new(req);
      buf_printf(&b, "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"error\":{\"code\":-32601,\"message\":\"unsupported\"}}",
                 json_int(id, 0));
      send_msg(&b);
    }
  }
  return 1;
}

/* wheels' implementations */
#include "wheels.h"
