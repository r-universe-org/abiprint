# Signatures from headers in a temporary package directory
clang_sig <- function(header, names){
  path <- tempfile()
  dir.create(file.path(path, "include"), recursive = TRUE)
  writeLines(header, file.path(path, "include", "test.h"))
  on.exit(unlink(path, recursive = TRUE))
  abitools:::clang_signatures("test", path, names)
}

test_that("libclang describes the ABI of a function", {
  sig <- clang_sig(c("typedef struct { int x; double y; } point_t;",
                     "point_t *move(point_t *p, int n);"), "move")
  # A struct that was already described is referred to by its position
  expect_equal(unname(sig), "function(*{16,8|0:Int32;64:Float64;},Int32)->*record#1")
})

test_that("names, formatting and qualifiers do not matter", {
  a <- clang_sig(c("typedef struct { int x; double y; } point_t;",
                   "point_t *move(point_t *p, int n);"), "move")
  b <- clang_sig(c("typedef struct point { int a;  double b; } POINT;",
                   "/* renamed */ POINT *move(const POINT *point,", "  int count);"), "move")
  expect_equal(a, b)
})

test_that("changes in types are detected, also through macros", {
  header <- function(n, type = "double") c(sprintf("#define N %d", n),
    sprintf("typedef struct { %s values[N]; } vec_t;", type), "int sum(vec_t *v);")
  base <- clang_sig(header(2), "sum")
  expect_false(identical(base, clang_sig(header(3), "sum")))
  expect_false(identical(base, clang_sig(header(2, "float"), "sum")))
  # Changes in other functions and types do not matter
  expect_equal(base, clang_sig(c(header(2), "typedef struct { int z; } other_t;", "int other(other_t *o);"), "sum"))
})

test_that("function pointers and casts at call sites are found", {
  sig <- clang_sig(c("extern double (*scale)(double x, int n);",
                     "static inline void init(void){",
                     '  void *f = (void *) (int (*)(const char *)) R_GetCCallable("test", "parse");',
                     "}"), c("scale", "parse", "missing"))
  expect_equal(unname(sig), c("function(Float64,Int32)->Float64", "function(*Char)->Int32", NA))
})

test_that("headers that do not parse are not used", {
  sig <- clang_sig(c("unknown_t broken(int x);", "int fine(int x);"), c("broken", "fine"))
  expect_equal(unname(sig), c(NA_character_, NA_character_))
})

test_that("the different ways in which packages declare a C API are found", {
  sig <- clang_sig(c(
    "#define MY_EXTERN(type) extern type",
    "typedef int (*fun_t)(int x);",
    "MY_EXTERN(double) nlopt_style(int n);",   # macro as return type (nloptr)
    "int new_thing(int n);",                   # registered as _new_thing (Bioconductor stubs)
    "extern fun_t precise_sum;",               # variable with a function pointer type (PreciseSums)
    "extern fun_t _p_prefixed;",               # with a prefix (rxode2ll)
    "int M_matrix_style(double x);"            # with a prefix (Matrix)
  ), c("nlopt_style", "_new_thing", "precise_sum", "prefixed", "matrix_style"))
  expect_equal(unname(sig), c("function(Int32)->Float64", "function(Int32)->Int32",
    "function(Int32)->Int32", "function(Int32)->Int32", "function(Float64)->Int32"))
})

test_that("types from other headers are described by name", {
  sig <- clang_sig(c("#include <stdio.h>", "int write_to(FILE *f, SEXP x);"), "write_to")
  expect_match(sig, "^function\\(\\*record\\([A-Za-z_:]+,[0-9]+\\),\\*record\\(SEXPREC,-2\\)\\)->Int32$")
})
