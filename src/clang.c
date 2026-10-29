/* Optional backend for C function signatures, see R/clang.R. Only compiled
 * if configure found libclang. */
#include <Rinternals.h>

#ifndef HAVE_LIBCLANG

SEXP abitools_clang_resource_dir(void){
  return R_NilValue;
}

SEXP abitools_clang_signatures(SEXP file, SEXP args, SEXP names, SEXP own, SEXP dirs){
  Rf_error("abitools was built without libclang");
}

#else

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <clang-c/Index.h>
#include "clang_config.h"

/* The location of the builtin headers (stddef.h, ...) of this clang */
SEXP abitools_clang_resource_dir(void){
  return Rf_mkString(CLANG_RESOURCE_DIR);
}

/* Growing string buffer */
typedef struct { char *data; size_t len, cap; } buf_t;

static void put(buf_t *b, const char *s){
  size_t n = strlen(s);
  if (b->len + n + 1 > b->cap) {
    b->cap = (b->len + n + 1) * 2;
    b->data = realloc(b->data, b->cap);
  }
  memcpy(b->data + b->len, s, n + 1);
  b->len += n;
}

static void putf(buf_t *b, const char *fmt, long long x){
  char tmp[64];
  snprintf(tmp, sizeof tmp, fmt, x);
  put(b, tmp);
}

typedef struct {
  int ndirs;
  const char **dirs;   /* records and enums declared here are expanded */
  const char *own;     /* the include directory of the package itself */
  int nnames;
  const char **names;  /* the names to look for */
  /* results */
  int n, cap;
  char **found, **kind, **sig;
  /* records that are being described, to stop recursion */
  int nvisit;
  char *visit[256];
} state_t;

static int in_dir(CXCursor cur, const char *dir){
  CXFile file;
  clang_getExpansionLocation(clang_getCursorLocation(cur), &file, NULL, NULL, NULL);
  if (!file) return 0;
  CXString name = clang_getFileName(file);
  const char *path = clang_getCString(name);
  int res = path && strncmp(path, dir, strlen(dir)) == 0;
  clang_disposeString(name);
  return res;
}

static int in_dirs(CXCursor cur, state_t *s){
  for (int i = 0; i < s->ndirs; i++)
    if (in_dir(cur, s->dirs[i])) return 1;
  return 0;
}

static void describe(buf_t *b, CXType t, state_t *s, int depth);

static enum CXVisitorResult describe_field(CXCursor field, CXClientData data){
  void **args = data;
  buf_t *b = args[0];
  state_t *s = args[1];
  int depth = *(int *) args[2];
  putf(b, "%lld:", clang_Cursor_getOffsetOfField(field));
  if (clang_Cursor_isBitField(field))
    putf(b, "bits%d:", clang_getFieldDeclBitWidth(field));
  describe(b, clang_getCursorType(field), s, depth + 1);
  put(b, ";");
  return CXVisit_Continue;
}

static enum CXChildVisitResult describe_enum_constant(CXCursor c, CXCursor parent, CXClientData data){
  if (clang_getCursorKind(c) == CXCursor_EnumConstantDecl)
    putf((buf_t *) data, "%lld,", clang_getEnumConstantDeclValue(c));
  return CXChildVisit_Continue;
}

/* Records and enums from other headers (R, system, C++ library) are only
 * described by name and size. Names of anonymous types contain a file path,
 * so these are not used. */
static void describe_name(buf_t *b, CXCursor decl, CXType t){
  if (clang_Cursor_isAnonymous(decl)) {
    put(b, "anonymous");
  } else {
    CXString name = clang_getTypeSpelling(t);
    const char *str = clang_getCString(name);
    if (strstr(str, "(unnamed") || strstr(str, "(anonymous")) {
      put(b, "anonymous");
    } else {
      /* Qualifiers do not affect the ABI, and C spells 'struct x' where C++
       * spells 'x' */
      const char *prefixes[] = {"const ", "volatile ", "struct ", "union ", "class ", "enum "};
      for (int i = 0; i < 6; i++) {
        size_t n = strlen(prefixes[i]);
        if (strncmp(str, prefixes[i], n) == 0) str += n;
      }
      put(b, str);
    }
    clang_disposeString(name);
  }
}

static void describe_record(buf_t *b, CXType t, state_t *s, int depth){
  CXCursor decl = clang_getTypeDeclaration(t);
  long long size = clang_Type_getSizeOf(t);
  if (size < 0 || depth > 30 || !in_dirs(decl, s)) {
    put(b, "record(");
    describe_name(b, decl, t);
    putf(b, ",%lld)", size);
    return;
  }
  CXString usr = clang_getCursorUSR(decl);
  const char *id = clang_getCString(usr);
  for (int i = 0; i < s->nvisit; i++) {
    if (strcmp(s->visit[i], id) == 0) {
      /* Refer to a record that was already described by its position */
      putf(b, "record#%d", i + 1);
      clang_disposeString(usr);
      return;
    }
  }
  if (s->nvisit < 256) s->visit[s->nvisit++] = strdup(id);
  clang_disposeString(usr);
  putf(b, "{%lld,", size);
  putf(b, "%lld|", clang_Type_getAlignOf(t));
  void *args[3] = {b, s, &depth};
  clang_Type_visitFields(t, describe_field, args);
  put(b, "}");
}

static void describe(buf_t *b, CXType t, state_t *s, int depth){
  t = clang_getCanonicalType(t);
  switch (t.kind) {
  case CXType_Pointer:
    put(b, "*");
    describe(b, clang_getPointeeType(t), s, depth + 1);
    return;
  case CXType_LValueReference:
    put(b, "&");
    describe(b, clang_getPointeeType(t), s, depth + 1);
    return;
  case CXType_RValueReference:
    put(b, "&&");
    describe(b, clang_getPointeeType(t), s, depth + 1);
    return;
  case CXType_ConstantArray:
    putf(b, "[%lld]", clang_getArraySize(t));
    describe(b, clang_getArrayElementType(t), s, depth + 1);
    return;
  case CXType_IncompleteArray:
  case CXType_VariableArray:
  case CXType_DependentSizedArray:
    put(b, "[]");
    describe(b, clang_getArrayElementType(t), s, depth + 1);
    return;
  case CXType_FunctionProto: {
    put(b, "function(");
    int n = clang_getNumArgTypes(t);
    for (int i = 0; i < n; i++) {
      if (i) put(b, ",");
      describe(b, clang_getArgType(t, i), s, depth + 1);
    }
    if (clang_isFunctionTypeVariadic(t)) put(b, n ? ",..." : "...");
    put(b, ")->");
    describe(b, clang_getResultType(t), s, depth + 1);
    return;
  }
  case CXType_FunctionNoProto:
    put(b, "function()->");
    describe(b, clang_getResultType(t), s, depth + 1);
    return;
  case CXType_Record:
    describe_record(b, t, s, depth);
    return;
  case CXType_Enum: {
    CXCursor decl = clang_getTypeDeclaration(t);
    put(b, "enum(");
    describe(b, clang_getEnumDeclIntegerType(decl), s, depth + 1);
    if (in_dirs(decl, s)) {
      put(b, "|");
      clang_visitChildren(decl, describe_enum_constant, b);
    } else {
      put(b, "|");
      describe_name(b, decl, t);
    }
    put(b, ")");
    return;
  }
  default: {
    /* Builtin types (Int, Double, ...) by kind. Other types (e.g. dependent
     * types in templates) by their spelling. */
    CXString kind = clang_getTypeKindSpelling(t.kind);
    put(b, clang_getCString(kind));
    clang_disposeString(kind);
    if (t.kind == CXType_Unexposed || t.kind >= CXType_Elaborated) {
      CXString name = clang_getTypeSpelling(t);
      put(b, "(");
      put(b, clang_getCString(name));
      put(b, ")");
      clang_disposeString(name);
    }
  }
  }
}

static void add_result(state_t *s, const char *name, const char *kind, CXType t){
  for (int i = 0; i < s->nvisit; i++) free(s->visit[i]);
  s->nvisit = 0;
  /* A function pointer (variable or cast) has the signature of the function */
  CXType c = clang_getCanonicalType(t);
  if (c.kind == CXType_Pointer) {
    CXType pointee = clang_getCanonicalType(clang_getPointeeType(c));
    if (pointee.kind == CXType_FunctionProto || pointee.kind == CXType_FunctionNoProto)
      t = pointee;
  }
  buf_t b = {NULL, 0, 0};
  put(&b, "");
  describe(&b, t, s, 0);
  if (s->n == s->cap) {
    s->cap = s->cap ? 2 * s->cap : 64;
    s->found = realloc(s->found, s->cap * sizeof(char *));
    s->kind = realloc(s->kind, s->cap * sizeof(char *));
    s->sig = realloc(s->sig, s->cap * sizeof(char *));
  }
  s->found[s->n] = strdup(name);
  s->kind[s->n] = strdup(kind);
  s->sig[s->n] = b.data;
  s->n++;
}

/* Exact match, or a match after a prefix such as 'M_' or '_p_' */
static const char *match_name(state_t *s, const char *name, int *prefixed){
  for (int i = 0; i < s->nnames; i++) {
    if (strcmp(name, s->names[i]) == 0) {
      *prefixed = 0;
      return s->names[i];
    }
  }
  const char *p = name + (name[0] == '_');
  while (*p && *p != '_') p++;
  if (*p == '_' && p > name + (name[0] == '_')) {
    for (int i = 0; i < s->nnames; i++) {
      if (strcmp(p + 1, s->names[i]) == 0) {
        *prefixed = 1;
        return s->names[i];
      }
    }
  }
  return NULL;
}

/* The string literal argument of R_GetCCallable("pkg", "name"). Literals
 * can be concatenated, as in "_" #name in Bioconductor stubs. */
static enum CXChildVisitResult find_literal(CXCursor c, CXCursor parent, CXClientData data){
  if (clang_getCursorKind(c) == CXCursor_StringLiteral) {
    CXString str = clang_getCursorSpelling(c);
    const char *in = clang_getCString(str);
    char *out = data;
    int quoted = 0;
    size_t len = strlen(out);
    for (; *in && len < 255; in++) {
      if (*in == '"') quoted = !quoted;
      else if (quoted) out[len++] = *in;
    }
    out[len] = 0;
    clang_disposeString(str);
    return CXChildVisit_Break;
  }
  return CXChildVisit_Recurse;
}

static int is_cast(enum CXCursorKind kind){
  return kind == CXCursor_CStyleCastExpr || kind == CXCursor_CXXStaticCastExpr ||
    kind == CXCursor_CXXReinterpretCastExpr || kind == CXCursor_CXXFunctionalCastExpr;
}

static enum CXChildVisitResult find_callable(CXCursor c, CXCursor parent, CXClientData data){
  /* Only the cast directly around the call */
  if (is_cast(clang_getCursorKind(c)))
    return CXChildVisit_Continue;
  if (clang_getCursorKind(c) == CXCursor_CallExpr) {
    CXString name = clang_getCursorSpelling(c);
    int is_call = strcmp(clang_getCString(name), "R_GetCCallable") == 0;
    clang_disposeString(name);
    if (is_call && clang_Cursor_getNumArguments(c) == 2) {
      char *out = data;
      out[0] = 0;
      CXCursor arg = clang_Cursor_getArgument(c, 1);
      if (clang_getCursorKind(arg) == CXCursor_StringLiteral) find_literal(arg, c, out);
      else clang_visitChildren(arg, find_literal, out);
      return CXChildVisit_Break;
    }
  }
  return CXChildVisit_Recurse;
}

static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData data){
  state_t *s = data;
  /* Skip declarations from R, system and C++ library headers */
  if (!in_dir(c, s->own)) return CXChildVisit_Continue;
  enum CXCursorKind kind = clang_getCursorKind(c);
  if (kind == CXCursor_FunctionDecl || kind == CXCursor_VarDecl) {
    CXType t = clang_getCanonicalType(clang_getCursorType(c));
    int is_function = t.kind == CXType_FunctionProto || t.kind == CXType_FunctionNoProto ||
      (t.kind == CXType_Pointer && clang_getCanonicalType(clang_getPointeeType(t)).kind == CXType_FunctionProto);
    if (is_function) {
      CXString name = clang_getCursorSpelling(c);
      int prefixed;
      const char *match = match_name(s, clang_getCString(name), &prefixed);
      if (match) add_result(s, match, prefixed ? "prefix" : "declaration", clang_getCursorType(c));
      clang_disposeString(name);
    }
  } else if (is_cast(kind)) {
    char name[256] = "";
    clang_visitChildren(c, find_callable, name);
    int prefixed;
    const char *match = name[0] ? match_name(s, name, &prefixed) : NULL;
    if (match && !prefixed) {
      add_result(s, match, "callsite", clang_getCursorType(c));
      return CXChildVisit_Continue;
    }
  }
  return CXChildVisit_Recurse;
}

static const char **as_strings(SEXP x){
  const char **out = (const char **) R_alloc(Rf_length(x), sizeof(char *));
  for (int i = 0; i < Rf_length(x); i++) out[i] = CHAR(STRING_ELT(x, i));
  return out;
}

/* Parse a header with the given compiler arguments, and find the signatures
 * of the given names. Returns NULL if the header could not be parsed. */
SEXP abitools_clang_signatures(SEXP file, SEXP args, SEXP names, SEXP own, SEXP dirs){
  state_t s = {0};
  s.own = CHAR(STRING_ELT(own, 0));
  s.ndirs = Rf_length(dirs);
  s.dirs = as_strings(dirs);
  s.nnames = Rf_length(names);
  s.names = as_strings(names);
  CXIndex index = clang_createIndex(0, 0);
  CXTranslationUnit tu = NULL;
  enum CXErrorCode err = clang_parseTranslationUnit2(index, CHAR(STRING_ELT(file, 0)),
    as_strings(args), Rf_length(args), NULL, 0,
    CXTranslationUnit_KeepGoing | CXTranslationUnit_Incomplete, &tu);
  if (err != CXError_Success || !tu) {
    clang_disposeIndex(index);
    return R_NilValue;
  }
  int errors = 0;
  SEXP messages = PROTECT(Rf_allocVector(STRSXP, 5));
  for (unsigned i = 0; i < clang_getNumDiagnostics(tu); i++) {
    CXDiagnostic d = clang_getDiagnostic(tu, i);
    if (clang_getDiagnosticSeverity(d) >= CXDiagnostic_Error) {
      if (errors < 5) {
        CXString msg = clang_formatDiagnostic(d, clang_defaultDiagnosticDisplayOptions());
        SET_STRING_ELT(messages, errors, Rf_mkChar(clang_getCString(msg)));
        clang_disposeString(msg);
      }
      errors++;
    }
    clang_disposeDiagnostic(d);
  }
  clang_visitChildren(clang_getTranslationUnitCursor(tu), visit, &s);
  SEXP out = PROTECT(Rf_allocVector(VECSXP, 5));
  SEXP found = PROTECT(Rf_allocVector(STRSXP, s.n));
  SEXP kind = PROTECT(Rf_allocVector(STRSXP, s.n));
  SEXP sig = PROTECT(Rf_allocVector(STRSXP, s.n));
  for (int i = 0; i < s.n; i++) {
    SET_STRING_ELT(found, i, Rf_mkChar(s.found[i]));
    SET_STRING_ELT(kind, i, Rf_mkChar(s.kind[i]));
    SET_STRING_ELT(sig, i, Rf_mkChar(s.sig[i]));
    free(s.found[i]); free(s.kind[i]); free(s.sig[i]);
  }
  free(s.found); free(s.kind); free(s.sig);
  for (int i = 0; i < s.nvisit; i++) free(s.visit[i]);
  SET_VECTOR_ELT(out, 0, found);
  SET_VECTOR_ELT(out, 1, kind);
  SET_VECTOR_ELT(out, 2, sig);
  SET_VECTOR_ELT(out, 3, Rf_ScalarInteger(errors));
  SET_VECTOR_ELT(out, 4, messages);
  clang_disposeTranslationUnit(tu);
  clang_disposeIndex(index);
  UNPROTECT(5);
  return out;
}

#endif
