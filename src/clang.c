/* Signatures of C functions with libclang, see R/clang.R */
#include <Rinternals.h>

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
  const char *own;     /* the source directory of the package itself */
  /* results */
  int n, cap;
  char **found, **kind, **sig;
  /* records that are being described, to stop recursion */
  int names_only;
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

/* The name of a record or enum from other headers (R, system, C++ library):
 * the names of the enclosing namespaces and classes, the name of the type,
 * and its template arguments (types without names, or integer values). The
 * names of anonymous types are not used, because these contain a path. */
static void qualified_name(buf_t *b, CXCursor decl, state_t *s, int depth){
  CXCursor parent = clang_getCursorSemanticParent(decl);
  switch (clang_getCursorKind(parent)) {
  case CXCursor_Namespace:
  case CXCursor_StructDecl:
  case CXCursor_ClassDecl:
  case CXCursor_UnionDecl:
  case CXCursor_ClassTemplate:
    qualified_name(b, parent, s, depth);
    put(b, "::");
    break;
  default:
    break;
  }
  CXString name = clang_getCursorSpelling(decl);
  const char *str = clang_getCString(name);
  int anonymous = !*str || strchr(str, '(') || clang_Cursor_isAnonymous(decl);
  put(b, anonymous ? "anonymous" : str);
  clang_disposeString(name);
  int n = clang_Cursor_getNumTemplateArguments(decl);
  if (n > 0) {
    put(b, "<");
    for (int i = 0; i < n; i++) {
      if (i) put(b, ",");
      switch (clang_Cursor_getTemplateArgumentKind(decl, i)) {
      case CXTemplateArgumentKind_Type:
        s->names_only++;
        describe(b, clang_Cursor_getTemplateArgumentType(decl, i), s, depth + 1);
        s->names_only--;
        break;
      case CXTemplateArgumentKind_Integral:
        putf(b, "%lld", clang_Cursor_getTemplateArgumentValue(decl, i));
        break;
      default:
        put(b, "?");
      }
    }
    put(b, ">");
  }
}

static void describe_record(buf_t *b, CXType t, state_t *s, int depth){
  CXCursor decl = clang_getTypeDeclaration(t);
  long long size = clang_Type_getSizeOf(t);
  if (size < 0 || depth > 30 || s->names_only || !in_dirs(decl, s)) {
    put(b, "record(");
    qualified_name(b, decl, s, depth);
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
    put(b, "|");
    if (in_dirs(decl, s) && !s->names_only) {
      clang_visitChildren(decl, describe_enum_constant, b);
    } else {
      qualified_name(b, decl, s, depth);
    }
    put(b, ")");
    return;
  }
  case CXType_Char_S:
  case CXType_Char_U:
    /* Plain char is signed or unsigned depending on the platform */
    put(b, "Char");
    return;
  case CXType_Short:
  case CXType_Int:
  case CXType_Long:
  case CXType_LongLong:
  case CXType_Int128:
    /* Integers by size: int64_t is 'long' on Linux but 'long long' on macOS */
    putf(b, "Int%lld", 8 * clang_Type_getSizeOf(t));
    return;
  case CXType_UShort:
  case CXType_UInt:
  case CXType_ULong:
  case CXType_ULongLong:
  case CXType_UInt128:
    putf(b, "UInt%lld", 8 * clang_Type_getSizeOf(t));
    return;
  case CXType_Half:
  case CXType_Float16:
  case CXType_Float:
  case CXType_Double:
  case CXType_LongDouble:
  case CXType_Float128:
    putf(b, "Float%lld", 8 * clang_Type_getSizeOf(t));
    return;
  case CXType_Bool:
    put(b, "Bool");
    return;
  case CXType_Void:
    put(b, "Void");
    return;
  default: {
    /* Other types by the name of their kind in libclang and their size */
    CXString kind = clang_getTypeKindSpelling(t.kind);
    put(b, clang_getCString(kind));
    clang_disposeString(kind);
    putf(b, "%lld", 8 * clang_Type_getSizeOf(t));
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

static enum CXChildVisitResult last_child(CXCursor c, CXCursor parent, CXClientData data){
  *(CXCursor *) data = c;
  return CXChildVisit_Continue;
}

/* An expression without casts, parentheses, and address-of operators */
static CXCursor strip(CXCursor c){
  for (;;) {
    switch (clang_getCursorKind(c)) {
    case CXCursor_UnexposedExpr:
    case CXCursor_ParenExpr:
    case CXCursor_CStyleCastExpr:
    case CXCursor_CXXStaticCastExpr:
    case CXCursor_CXXReinterpretCastExpr:
    case CXCursor_CXXFunctionalCastExpr:
    case CXCursor_UnaryOperator: {
      CXCursor child = clang_getNullCursor();
      clang_visitChildren(c, last_child, &child);
      if (clang_Cursor_isNull(child)) return c;
      c = child;
      break;
    }
    default:
      return c;
    }
  }
}

/* The text of a string literal; literals can be concatenated ("_" #name) */
static int literal_text(CXCursor c, char *out, size_t size){
  c = strip(c);
  if (clang_getCursorKind(c) != CXCursor_StringLiteral) return 0;
  CXString str = clang_getCursorSpelling(c);
  const char *in = clang_getCString(str);
  size_t len = 0;
  int quoted = 0;
  for (; *in && len < size - 1; in++) {
    if (*in == '"') quoted = !quoted;
    else if (quoted) out[len++] = *in;
  }
  out[len] = 0;
  clang_disposeString(str);
  return 1;
}

/* The function that an expression refers to, e.g. (DL_FUNC) &fun */
static int function_ref(CXCursor c, CXCursor *fun){
  c = strip(c);
  if (clang_getCursorKind(c) != CXCursor_DeclRefExpr) return 0;
  CXCursor ref = clang_getCursorReferenced(c);
  enum CXCursorKind kind = clang_getCursorKind(ref);
  if (kind != CXCursor_FunctionDecl && kind != CXCursor_CXXMethod) return 0;
  *fun = ref;
  return 1;
}

typedef struct { int n; CXCursor items[64]; } children_t;

static enum CXChildVisitResult collect_child(CXCursor c, CXCursor parent, CXClientData data){
  children_t *ch = data;
  if (ch->n < 64) ch->items[ch->n++] = c;
  return CXChildVisit_Continue;
}

/* In the arguments of a call or the elements of an initializer list: a string
 * literal followed by a reference to a function. This covers calls to
 * R_RegisterCCallable("pkg", "name", fun) (also through macros or wrapper
 * functions), and tables such as {"name", (DL_FUNC) &fun, 1}. */
static void find_pairs(state_t *s, children_t *ch, const char *kind){
  char name[256];
  CXCursor fun;
  for (int i = 0; i + 1 < ch->n; i++) {
    if (literal_text(ch->items[i], name, sizeof name) && name[0] && function_ref(ch->items[i + 1], &fun))
      add_result(s, name, kind, clang_getCursorType(fun));
  }
}

static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData data){
  state_t *s = data;
  /* Only code of the package itself, not from R or system headers */
  if (!in_dir(c, s->own)) return CXChildVisit_Continue;
  enum CXCursorKind kind = clang_getCursorKind(c);
  children_t ch = {0};
  if (kind == CXCursor_CallExpr) {
    int n = clang_Cursor_getNumArguments(c);
    for (int i = 0; i < n && i < 64; i++) ch.items[ch.n++] = clang_Cursor_getArgument(c, i);
    CXString callee = clang_getCursorSpelling(c);
    int registers = strcmp(clang_getCString(callee), "R_RegisterCCallable") == 0;
    clang_disposeString(callee);
    find_pairs(s, &ch, registers ? "register" : "pair");
  } else if (kind == CXCursor_InitListExpr) {
    clang_visitChildren(c, collect_child, &ch);
    find_pairs(s, &ch, "pair");
  }
  return CXChildVisit_Recurse;
}

static const char **as_strings(SEXP x){
  const char **out = (const char **) R_alloc(Rf_length(x), sizeof(char *));
  for (int i = 0; i < Rf_length(x); i++) out[i] = CHAR(STRING_ELT(x, i));
  return out;
}

/* Parse a source file of a package with the given compiler arguments, and find
 * the pairs of a name and a function in it (see find_pairs). Returns NULL if
 * the file could not be parsed. */
SEXP abitools_clang_pairs(SEXP file, SEXP args, SEXP own, SEXP dirs){
  state_t s = {0};
  s.own = CHAR(STRING_ELT(own, 0));
  s.ndirs = Rf_length(dirs);
  s.dirs = as_strings(dirs);
  CXIndex index = clang_createIndex(0, 0);
  CXTranslationUnit tu = NULL;
  enum CXErrorCode err = clang_parseTranslationUnit2(index, CHAR(STRING_ELT(file, 0)),
    as_strings(args), Rf_length(args), NULL, 0,
    CXTranslationUnit_KeepGoing, &tu);
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
