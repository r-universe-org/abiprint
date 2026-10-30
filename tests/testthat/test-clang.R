# A package that registers C functions in all the ways that we have seen
make_regstyles <- function(root, makevars = "PKG_CPPFLAGS = -DUSE_WIDE -DN=2"){
  src <- c(
    "#include <Rinternals.h>",
    "#include <R_ext/Rdynload.h>",
    "#ifdef USE_WIDE",
    "typedef long long val_t;",
    "#else",
    "typedef int val_t;",
    "#endif",
    "typedef struct { int a; double b; } point_t;",
    "typedef struct { double values[N]; } vec_t;",
    "static int f_direct(int x){ return x; }",
    "static double f_macro(double x){ return x; }",
    "static SEXP f_table(SEXP x){ return x; }",
    "static void f_wrapper(point_t *p){ }",
    "static val_t f_flag(val_t x){ return x; }",
    "static int f_vec(vec_t *v){ return 0; }",
    "#define REG(fun) R_RegisterCCallable(\"regstyles\", #fun, (DL_FUNC) &fun)",
    "static void register_fn(const char *name, DL_FUNC fun){ R_RegisterCCallable(\"regstyles\", name, fun); }",
    "static const R_CallMethodDef table[] = {{\"f_table\", (DL_FUNC) &f_table, 1}, {NULL, NULL, 0}};",
    "void R_init_regstyles(DllInfo *dll){",
    "  R_registerRoutines(dll, NULL, table, NULL, NULL);",
    "  R_RegisterCCallable(\"regstyles\", \"f_direct\", (DL_FUNC) &f_direct);",
    "  REG(f_macro);",
    "  REG(f_flag);",
    "  REG(f_vec);",
    "  for (const R_CallMethodDef *m = table; m->name; m++) R_RegisterCCallable(\"regstyles\", m->name, m->fun);",
    "  register_fn(\"f_wrapper\", (DL_FUNC) &f_wrapper);",
    "}")
  make_pkg(root, "regstyles", "1.0", code = "f <- function() NULL",
           namespace = c("useDynLib(regstyles)", "export(f)"), src = src, makevars = makevars)
}

test_that("signatures are found for all ways of registering C functions", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))
  sigs <- with_lib(lib, abi_install(make_regstyles(root), lib, quiet = TRUE))
  expect_equal(sigs[["f_direct"]], "function(Int32)->Int32")
  expect_equal(sigs[["f_macro"]], "function(Float64)->Float64")
  expect_equal(sigs[["f_table"]], "function(*record(SEXPREC,-2))->*record(SEXPREC,-2)")
  expect_equal(sigs[["f_wrapper"]], "function(*{16,8|0:Int32;64:Float64;})->Void")
  # With the compiler flags of the package (-DUSE_WIDE, -DN=2)
  expect_equal(sigs[["f_flag"]], "function(Int64)->Int64")
  expect_equal(sigs[["f_vec"]], "function(*{16,8|0:[2]Float64;})->Int32")
  # Stored in the installed package, and exported
  exports <- with_lib(lib, abi_list("regstyles")$exports)
  expect_setequal(exports$key, paste0("regstyles::", c("f_direct", "f_macro", "f_table", "f_wrapper", "f_flag", "f_vec"), "()"))

  # Other compiler flags change the signatures
  sigs <- with_lib(lib, abi_install(make_regstyles(root, "PKG_CPPFLAGS = -DN=3"), lib, quiet = TRUE))
  expect_equal(sigs[["f_flag"]], "function(Int32)->Int32")
  expect_equal(sigs[["f_vec"]], "function(*{24,8|0:[3]Float64;})->Int32")
})

test_that("names, formatting and qualifiers do not matter", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))
  provider <- function(src) make_pkg(root, "regstyles", "1.0", code = "f <- function() NULL",
    namespace = c("useDynLib(regstyles)", "export(f)"), src = c(
      "#include <Rinternals.h>", "#include <R_ext/Rdynload.h>", src,
      "void R_init_regstyles(DllInfo *dll){ R_RegisterCCallable(\"regstyles\", \"move\", (DL_FUNC) &move); }"))
  a <- with_lib(lib, abi_install(provider(c("typedef struct { int x; double y; } point_t;",
    "static point_t *move(point_t *p, int n){ return p; }")), lib, quiet = TRUE))
  b <- with_lib(lib, abi_install(provider(c("typedef struct point { int a;  double b; } POINT;",
    "/* renamed */ static POINT *move(const POINT *point,", "  int count){ return (POINT *) point; }")), lib, quiet = TRUE))
  expect_equal(a, b)
  expect_equal(a[["move"]], "function(*{16,8|0:Int32;64:Float64;},Int32)->*record#1")
})
