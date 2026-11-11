/* A plugin over libccshl: watches a compilation and reports from it.
 *   cshl-inspect unused file.cshl [other.cshl]   bindings nothing used
 *   cshl-inspect types file.cshl [other.cshl]    every binding with its type
 * Both report on file.cshl, or on other.cshl when it's given (a library
 * file.cshl imports). Add --lower to watch the lowering for C instead of the
 * interpreter. Only code that ran is seen, so "unused" means unused in what
 * ran; copies @using made aren't reported as unused, their originals are. */
#include "ccshl.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint64_t id, origin, type;
  const char *name, *file;
  size_t name_len, file_len;
  uint32_t offset;
  size_t uses;
} binding;

typedef struct {
  binding *items;
  size_t len, cap;
  int failed;
  cshl_message error;
} state;

static binding *find(state *st, uint64_t id) {
  /* ids count up from 1 in order, so id - 1 is the index */
  if (id == 0 || id > st->len) return NULL;
  return &st->items[id - 1];
}

static void on_message(void *ctx, const cshl_message *m) {
  state *st = ctx;
  switch (m->kind) {
  case CSHL_BIND:
    if (st->len == st->cap) {
      st->cap = st->cap ? st->cap * 2 : 256;
      st->items = realloc(st->items, st->cap * sizeof *st->items);
    }
    st->items[st->len++] = (binding){
        m->id, m->origin, m->type, m->name, m->file, m->name_len, m->file_len, m->offset, 0};
    break;
  case CSHL_USE:
    /* a use of a copy is a use of what it was copied from, too */
    for (binding *b = find(st, m->id); b; b = find(st, b->origin)) b->uses++;
    break;
  case CSHL_ERROR:
    st->failed = 1;
    st->error = *m;
    break;
  }
}

/* line and column of offset in the file at path[0..len] */
static void position(const char *path, size_t len, uint32_t offset, unsigned *line, unsigned *col) {
  *line = 1, *col = 1;
  char name[4096];
  if (len >= sizeof name) return;
  memcpy(name, path, len), name[len] = 0;
  FILE *f = fopen(name, "rb");
  if (!f) return;
  for (uint32_t i = 0; i < offset; i++) {
    int c = fgetc(f);
    if (c == EOF) break;
    if (c == '\n') (*line)++, *col = 1;
    else (*col)++;
  }
  fclose(f);
}

/* whether b is in path; imports are reported as @path builds them, like
   ./lib/x.cshl, so a leading ./ doesn't count */
static int in_file(const binding *b, const char *path) {
  const char *f = b->file;
  size_t n = b->file_len;
  while (n >= 2 && f[0] == '.' && f[1] == '/') f += 2, n -= 2;
  while (path[0] == '.' && path[1] == '/') path += 2;
  return n == strlen(path) && memcmp(f, path, n) == 0;
}

/* the same declaration: the same name at the same place */
static int same_decl(const binding *a, const binding *b) {
  return a->offset == b->offset && a->file_len == b->file_len && !memcmp(a->file, b->file, a->file_len) &&
         a->name_len == b->name_len && !memcmp(a->name, b->name, a->name_len);
}

int main(int argc, char **argv) {
  int lower = 0;
  const char *mode = NULL, *path = NULL, *report = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--lower") == 0) lower = 1;
    else if (!mode) mode = argv[i];
    else if (!path) path = argv[i];
    else report = argv[i];
  }
  if (!mode || !path || (strcmp(mode, "unused") && strcmp(mode, "types"))) {
    fprintf(stderr, "usage: %s [--lower] unused|types file.cshl [other.cshl]\n", argv[0]);
    return 2;
  }
  if (!report) report = path;
  state st = {0};
  cshl *s = cshl_compile(path, lower, on_message, &st);
  if (!s) return fprintf(stderr, "out of memory\n"), 1;
  int unused = strcmp(mode, "unused") == 0;
  /* a declaration binds once per run of its code (a local, each call), so
     report by declaration: its name where it's written. It's used if any of
     its bindings is, and its types are all the ones they had. */
  for (size_t i = 0; i < st.len; i++) {
    binding *b = &st.items[i];
    if (!in_file(b, report)) continue;
    int first = 1, used = 0;
    for (size_t j = 0; j < st.len; j++) {
      binding *o = &st.items[j];
      if (!same_decl(o, b)) continue;
      if (j < i) first = 0;
      if (o->uses || o->origin) used = 1;
    }
    if (!first) continue;
    /* names starting with _ are unused on purpose */
    if (unused && (used || (b->name_len && b->name[0] == '_'))) continue;
    unsigned line, col;
    position(report, strlen(report), b->offset, &line, &col);
    printf("%s:%u:%u: %s%.*s:", report, line, col, unused ? "unused " : "", (int)b->name_len, b->name);
    /* each distinct type, once */
    for (size_t j = i; j < st.len; j++) {
      binding *o = &st.items[j];
      if (!same_decl(o, b)) continue;
      int seen = 0;
      for (size_t k = i; k < j && !seen; k++) {
        binding *p = &st.items[k];
        seen = same_decl(p, b) && p->type == o->type;
      }
      if (seen) continue;
      size_t tl;
      const char *t = cshl_type_name(s, o->type, &tl);
      printf("%s %.*s", j == i ? "" : " |", (int)tl, t);
    }
    printf("\n");
  }
  if (st.failed) {
    unsigned line, col;
    position(st.error.file, st.error.file_len, st.error.offset, &line, &col);
    fprintf(stderr, "%.*s:%u:%u: error: %.*s\n", (int)st.error.file_len, st.error.file, line, col,
            (int)st.error.name_len, st.error.name);
  }
  int failed = cshl_failed(s);
  cshl_free(s);
  free(st.items);
  return failed;
}
