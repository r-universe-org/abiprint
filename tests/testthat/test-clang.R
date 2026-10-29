# Signatures from headers in a temporary package directory
clang_sig <- function(header, names){
  path <- tempfile()
  dir.create(file.path(path, "include"), recursive = TRUE)
  writeLines(header, file.path(path, "include", "test.h"))
  on.exit(unlink(path, recursive = TRUE))
  abitools:::clang_signatures("test", path, names)
}

test_that("libclang describes the ABI of a function", {
  skip_if_not(abitools:::has_libclang())
  sig <- clang_sig(c("typedef struct { int x; double y; } point_t;",
                     "point_t *move(point_t *p, int n);"), "move")
  # A struct that was already described is referred to by its position
  expect_equal(unname(sig), "function(*{16,8|0:Int;64:Double;},Int)->*record#1")
})

test_that("names, formatting and qualifiers do not matter", {
  skip_if_not(abitools:::has_libclang())
  a <- clang_sig(c("typedef struct { int x; double y; } point_t;",
                   "point_t *move(point_t *p, int n);"), "move")
  b <- clang_sig(c("typedef struct point { int a;  double b; } POINT;",
                   "/* renamed */ POINT *move(const POINT *point,", "  int count);"), "move")
  expect_equal(a, b)
})

test_that("changes in types are detected, also through macros", {
  skip_if_not(abitools:::has_libclang())
  header <- function(n, type = "double") c(sprintf("#define N %d", n),
    sprintf("typedef struct { %s values[N]; } vec_t;", type), "int sum(vec_t *v);")
  base <- clang_sig(header(2), "sum")
  expect_false(identical(base, clang_sig(header(3), "sum")))
  expect_false(identical(base, clang_sig(header(2, "float"), "sum")))
  # Changes in other functions and types do not matter
  expect_equal(base, clang_sig(c(header(2), "typedef struct { int z; } other_t;", "int other(other_t *o);"), "sum"))
})

test_that("function pointers and casts at call sites are found", {
  skip_if_not(abitools:::has_libclang())
  sig <- clang_sig(c("extern double (*scale)(double x, int n);",
                     "static inline void init(void){",
                     '  void *f = (void *) (int (*)(const char *)) R_GetCCallable("test", "parse");',
                     "}"), c("scale", "parse", "missing"))
  expect_equal(unname(sig), c("function(Double,Int)->Double", "function(*Char_S)->Int", NA))
})

test_that("headers that do not parse are not used", {
  skip_if_not(abitools:::has_libclang())
  sig <- clang_sig(c("unknown_t broken(int x);", "int fine(int x);"), c("broken", "fine"))
  expect_equal(unname(sig), c(NA_character_, NA_character_))
})
