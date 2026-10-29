test_that("only changes in the C functions that a package calls require a rebuild", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_c_provider(root, "1.0"), lib)
  install_pkg(make_c_consumer(root), lib)
  record <- with_lib(lib, {
    expect_equal(abi_deps("cconspkg")$type, "C API")
    exports <- abi_list("cprovpkg")$exports
    expect_equal(exports$key, c("cprovpkg/include", "cprovpkg::prov_add()", "cprovpkg::prov_info()"))
    x <- abi_list("cconspkg")
    expect_equal(x$imports$key, "cprovpkg::prov_add()")
    expect_equal(nrow(abi_check(x)), 0)
    list(record = x, exports = exports)
  })

  # A new function, and a changed struct that prov_add() does not use
  install_pkg(make_c_provider(root, "1.1", struct = "int a; double b;", extra = "int prov_new(void);"), lib)
  with_lib(lib, {
    exports <- abi_list("cprovpkg")$exports
    changed <- exports$key[!exports$hash %in% record$exports$hash]
    expect_equal(changed, c("cprovpkg/include", "cprovpkg::prov_info()"))
    expect_equal(nrow(abi_check(record$record)), 0)
  })

  # Renamed parameters of prov_add()
  install_pkg(make_c_provider(root, "1.2", add_args = "int a, int b"), lib)
  with_lib(lib, {
    expect_equal(nrow(abi_check(record$record)), 0)
  })

  # A changed signature of prov_add()
  install_pkg(make_c_provider(root, "1.3", add_args = "int x, double y"), lib)
  with_lib(lib, {
    expect_equal(abi_check(record$record)$reason, "C function prov_add() changed")
  })
})

test_that("statements are found in C and C++ headers", {
  text <- abitools:::read_headers(test_path("headers"))
  statements <- unlist(lapply(text, abitools:::header_statements))
  defs <- abitools:::type_definitions(statements)
  expect_setequal(names(defs), c("point", "point_t", "fun_t", "Box", "Alias"))
  sig <- abitools:::callable_signature(statements, defs, "_area", "test")
  expect_equal(sig[1], "double area(const point_t*,Box);")
  expect_true(any(startsWith(sig, "typedef struct point")))
  expect_true(any(startsWith(sig, "class Box")))
  # Parameter names are not types
  expect_false(any(startsWith(sig, "using Alias")))
  # Function pointers, as in libgeos
  sig <- abitools:::callable_signature(statements, defs, "geos_area", "test")
  expect_equal(sig[1], "extern int(*)(fun_t,Box*);")
  expect_true(any(startsWith(sig, "typedef int(*)(int)")))
  expect_null(abitools:::callable_signature(statements, defs, "fun_t", "test"))
  # A macro as return type, as in nloptr
  sig <- abitools:::callable_signature(statements, defs, "nlopt_style", "test")
  expect_equal(sig[1], "MY_EXTERN(point_t)nlopt_style(int);")
  # Only the cast at the call site of R_GetCCallable(), as in RNifti
  sig <- abitools:::callable_signature(statements, defs, "shifted_name", "test", text)
  expect_equal(sig[1], "(double(*)(const point_t*))")
  expect_true(any(startsWith(sig, "typedef struct point")))
  # A variable with a function pointer type, as in PreciseSums
  sig <- abitools:::callable_signature(statements, defs, "precise_sum", "test")
  expect_equal(sig, c("extern fun_t precise_sum;", "typedef int(*)(int);"))
  # Formatting does not matter, only the cast at the call site
  other <- c("void g(){ if (!f) f = (double (*)( const point_t * )) R_GetCCallable(\"test\", \"shifted_name\"); }")
  expect_equal(abitools:::callsite_clauses(abitools:::clean_header(other), "shifted_name"), "(double(*)(const point_t*))")
  # With a prefix, as in rxode2ll
  sig <- abitools:::callable_signature(statements, defs, "prefixed", "test")
  expect_equal(sig, c("extern fun_t _p_prefixed;", "typedef int(*)(int);"))
})

test_that("only the types of parameters are part of the signature", {
  strip <- function(x) abitools:::compact_code(abitools:::strip_parameter_names(x))
  expect_equal(strip("int f(int x, double y = 1.0);"), "int f(int,double);")
  expect_equal(strip("int f(int a, double b);"), "int f(int,double);")
  # Unnamed parameters keep their full type
  expect_equal(strip("void g(const CHM_SP, unsigned long n, unsigned long, struct foo);"),
               "void g(const CHM_SP,unsigned long,unsigned long,struct foo);")
  expect_equal(strip("void g(const char *const p, const char *s, char *const);"),
               "void g(const char*const,const char*,char*const);")
  # Function pointers, arrays, templates and namespaces
  expect_equal(strip("SEXP h(int (*cb)(int x, void *d), double x[10], std::map<int, int> m, Rcpp::Module* mod);"),
               "SEXP h(int(*)(int,void*),double[10],std::map<int,int>,Rcpp::Module*);")
  expect_equal(strip("void v(int, ...);"), "void v(int,...);")
  expect_equal(strip("int k(void);"), "int k(void);")
})
