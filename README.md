# abitools

> Detect when installed R packages need to be rebuilt

A binary R package is not only compiled code: it also contains state that was
copied from its dependencies at build time. When such a dependency changes, the
binary may break even though its own code has not changed. Package repositories
typically guess when this happens from version numbers. That is both too much
and too little: Bioconductor bumps the version of every package twice per year
without changing anything, while a package built from git may change its
classes without a version bump.

This package finds the dependencies that an installed package actually
depends on at the binary level, and computes fingerprints of exactly those
parts. A repository can then rebuild just the packages that are affected by a
change.

## What gets copied into a binary package

Calling `dep::foo()` from R code is fine: only the symbol is stored, and the
current version of the dependency is used at runtime. Problems come from state
that is copied by value when the package is installed:

1. **C API of a LinkingTo dependency.** Packages such as S4Vectors, IRanges,
   XVector, Biostrings and Rcpp export C functions with `R_RegisterCCallable()`
   and ship headers with stubs that call `R_GetCCallable("pkg", "fun")`. The
   caller is compiled against the struct layouts and function signatures in
   those headers. Similarly, RcppParallel ships a shared TBB library that
   packages such as rstan link to. Header-only libraries (RcppArmadillo,
   RcppEigen, BH, cpp11) and bundled static libraries (Rhtslib, Rhdf5lib) are
   different: their code is compiled into the binary, which keeps working when
   the dependency changes.
2. **S4 classes that extend a class from another package.** The stored
   definition of the subclass includes all inherited slots and superclasses. If
   the superclass changes, the subclass becomes inconsistent. This is the most
   common reason why Bioconductor packages need to be reinstalled.
3. **Copied code.** Objects created at install time that hold functions or
   environments of another package, such as `f <- dep:::helper`, ggproto
   objects inheriting from ggplot2, or S7 classes. These are reported by
   `abi_deps()`, but not fingerprinted: they are usually small aliases
   of internal helpers that keep working, and are left to periodic rebuilds.

Methods for generics from other packages (e.g. BiocGenerics) are registered
when the package is loaded and are not considered critical.

## Usage

`abi_deps()` lists the dependencies that an installed package holds a
copy of:

```r
abi_deps("Rsamtools")
#>     package        type           detail
#>  Biostrings       C API
#>     IRanges       C API
#>     Rhtslib     headers
#>   S4Vectors       C API
#>   S4Vectors    S4 class        Annotated
#>   S4Vectors    S4 class             List
#>   ...
#>   S4Vectors copied code            .some
#>     XVector       C API
```

A `LinkingTo` dependency is classified as `C API` if it registers C functions
with `R_RegisterCCallable()`, and its name appears as a separate string in the
shared library of the package (which is how `R_GetCCallable()` refers to it).
It is classified as `linked library` if it ships a shared library in its `lib`
directory that the package links to, and as `headers` otherwise.

`abi_list()` lists the ABI **exports** and **imports** of a package. The
exports are the parts that dependents may copy: a hash of each S4 class
definition (slots, superclasses, virtual), a hash of each C function that it
registers with `R_RegisterCCallable()`, and a hash of the files in its
`include` directory. Unlike the version, these hashes only change when
something changes that affects dependents. The imports are the exports of its
critical dependencies that the package copied when it was built: the classes
that it extends, the C functions of `C API` dependencies that it calls, and
the headers of `linked library` dependencies.

```r
abi_list("minqa")
#> $exports
#> [1] key  hash
#> <0 rows> (or 0-length row.names)
#>
#> $imports
#>                              key                             hash
#> 1 Rcpp::Rcpp_precious_preserve() db326d5386e653731de061cef9d03e24
#> 2   Rcpp::Rcpp_precious_remove() 84acf2c1e7fac9022b40c1e5c1c249e2
#> 3               Rcpp::demangle() b7df01794cea5ffd92afa5cd4cc9fd17
#> 4   Rcpp::rcpp_get_stack_trace() 11b1009f8761b93fbbdce90d8a3e5d32
#> 5   Rcpp::rcpp_set_stack_trace() 8f9e78c8c3a7d415f3b31e11af05ec05

abi_list("Rsamtools")$imports
#>                            key                             hash
#> 1      Biostrings::_AAdecode() 2b5149b1b683df2f924ed4fdabba29b8
#> ...
#> 65        S4Vectors::Annotated 95bf8c6a9de4f2f9373d24ccc74fe28a
#> 66             S4Vectors::List 7cded7a2c2addcb2a2d3392a89042c1e
#> ...
```

The key is `<package>::<class>` for an S4 class, `<package>::<function>()`
for a C function, and `<package>/include` for the C headers. Because package
names cannot contain `:` or `/`, the package is always the part before the
first `::` or `/`. An import is identical to the export of the dependency that
it was copied from, as long as that has not changed.

### C functions

R loads the shared library of each package privately, so packages cannot
call each other's C functions through the linker. Instead, a package registers
them with `R_RegisterCCallable("pkg", "fun")` and a dependent looks them up with
`R_GetCCallable("pkg", "fun")`. The names of the functions that a dependent
calls are therefore stored as strings in its shared library.

The registered functions of a package are found by asking `R_GetCCallable()`
for each name that appears both as a string in its shared library and in its
headers. The hash of a function describes its signature: the types of the
return value and the parameters (not their names), plus the structs and other
types that it uses, recursively. A change in a struct that is passed to a
function changes the hash of that function, while changes in inline code,
comments, or other functions do not.

#### With libclang (recommended)

If abitools is built with libclang (the `configure` script looks for
`llvm-config`, `/usr/lib/llvm-*` on Ubuntu, and Homebrew's llvm on macOS), the
headers are parsed by clang as they would be by a package that links to them:
with the preprocessor, and with the include directories of R and of the
LinkingTo dependencies of the package. The signature then describes the actual
ABI: canonical types, and for structs their size, alignment and field offsets.
Names, qualifiers, formatting, and macros do not matter; a changed array size
from a `#define` or a reordered struct field does. For example, for
`S4Vectors::_new_IntAE()`:

```
function(ULong,ULong,Int)->*{24,8|0:ULong;64:ULong;128:*Int;}
```

The signature is taken from the cast at a call site of `R_GetCCallable()` in
the headers (the type that dependents actually use to call the function), or
else from a declaration of the function. Only headers that parse without
errors are used. On Ubuntu, install `libclang-dev`.

#### Without libclang

Otherwise, a simple parser finds the declarations in the headers. Packages
declare their C API in different ways, which are all supported:

- a plain declaration `int fun(int x);` (cli, xts, actuar, ...), possibly with
  a macro as return type `EXTERN(int) fun(int x);` (nloptr)
- a declaration without the prefix that the stubs add to the registered name:
  `_fun` (Bioconductor), `_pkg_fun` (Rcpp interfaces), or the other way
  around `M_fun` (Matrix), `_p_fun` (rxode2ll)
- a function pointer `extern int (*fun)(int x);` (libgeos), or a variable with
  a function pointer type `extern fun_type fun;` (PreciseSums)
- only a cast at the call site `f = (int (*)(int)) R_GetCCallable("pkg", "fun");`
  (RNifti, rxode2)

This parser is also used for the functions that libclang does not find, for
example in an `#ifdef` branch that is not active. If neither finds a function,
the hash of all headers is used instead.

Rcpp packages call only the few Rcpp functions they use, because these are
inline functions in the Rcpp headers. Bioconductor packages include stubs for
all functions of the C API of their dependencies, so they import all of them.
Over the last six Rcpp releases, the headers changed every time, but none of
the hashes of the 36 C functions of Rcpp did:

| Rcpp version | headers | C functions changed |
|--------------|---------|---------------------|
| 1.0.11       | changed | 0 of 36             |
| 1.0.12       | changed | 0 of 36             |
| 1.0.13       | changed | 0 of 36             |
| 1.0.14       | changed | 0 of 36             |
| 1.1.0        | changed | 0 of 36             |
| 1.1.2        | changed | 0 of 36             |

Matrix records an ABI version in its headers, which it increased in 1.6-2 and
1.7-0. Over its releases from 1.6-0 to 1.7-3, the libclang signatures of its
C functions changed in exactly these two releases: in 1.6-2, the parameters of
`cholmod_band_inplace()` and `cholmod_solve2()` and the return type of
`cholmod_nnz()` changed, and in 1.7-0 (which updated to CHOLMOD 5), the size
of the `cholmod_common` struct that is passed to most functions changed.

This should be run right after the package is built, in the library that it
was built with. Both data frames are flat, so `jsonlite::toJSON()` gives lists
of entries that are easy to store and query in a database:

```json
{
  "exports": [
    {"key": "Rsamtools::ApplyPileupsParam", "hash": "614f6d9b9a46c60ec2728a5e00a85d0d"},
    ...
  ],
  "imports": [
    {"key": "S4Vectors::Vector", "hash": "10ab26d37b3e0ebc9fdf82fbfee25632"},
    ...
  ]
}
```

A package needs to be rebuilt when one of its imports no longer matches the
current export of the dependency. `abi_check()` compares the stored output of
`abi_list()` with the current exports of the dependencies, and returns the
reasons for a rebuild (zero rows means no rebuild is needed). For example, if a
slot was added to the `Vector` class:

```r
abi_check(x)
#>     package                 reason
#>   S4Vectors S4 class Vector changed
```

The current exports are computed from the installed dependencies by default,
or can be supplied by the caller as a data frame with the combined exports of
the dependencies, e.g. from the API of a package repository.

For a local library without stored imports, `stale_classes()` compares the S4 class
definitions stored in an installed package with the current definitions of
their superclasses, to find packages that must be reinstalled after a
dependency was updated.

## Using this in a package repository

1. When building a package, store the output of `abi_list()` with the binary.
2. Periodically (e.g. nightly), run `abi_check()` for each package against the
   latest exports of its dependencies, and rebuild the ones with changes.
   Checking periodically rather than after every deployment means that a
   package is rebuilt at most once, even if many of its dependencies changed
   on the same day.
3. A rebuilt package stores new imports and exports, and its own class hashes may
   change because they include the inherited slots. Dependents further down
   are picked up in the next round, so no cascade logic is needed.

To trigger rebuilds right after a breaking change is deployed, rather than
nightly, see [rebuild-procedure.md](rebuild-procedure.md).

## Findings

Between the current Bioconductor release and devel (versions bumped many
times), the fingerprints of the core infrastructure barely changed:

| package      | versions          | S4 classes   | headers   |
|--------------|-------------------|--------------|-----------|
| S4Vectors    | 0.50.3 → 0.51.10  | changed      | unchanged |
| IRanges      | 2.46.0 → 2.47.5   | unchanged    | unchanged |
| BiocGenerics | 0.58.1 → 0.59.12  | unchanged    | (none)    |
| S4Arrays     | 1.12.1 → 1.13.2   | unchanged    | (none)    |
| DelayedArray | 0.38.2 → 0.39.8   | unchanged    | (none)    |

The only change was the removal of two classes from S4Vectors that no other
package extends. Because imports are per class, this would not trigger
any rebuilds. A version-based policy would have rebuilt every dependent of
all five packages.

Inspecting a package takes 0 to 2.5 seconds.

## Limitations

- The package is inspected without being loaded, but unserializing its
  lazyload database loads the namespaces it refers to. Run it in the library
  that was used to build the package.
- Without libclang, C function declarations and types are found with a
  simple parser rather than a compiler: macros are not expanded, and types
  that are defined in the headers of another package are not followed.
- Functions that are not mentioned in the headers at all (some packages
  declare them only in their own sources) are not exported, so changes to
  them are not detected.
- Hashes from libclang and from the simple parser differ, so all packages in
  a repository should be inspected with the same setup.
- The headers of `linked library` dependencies are hashed as a whole: any
  change in them triggers a rebuild.
- The class hash ignores prototypes and validity methods. A changed prototype
  only results in stale defaults, and validity methods are looked up at
  runtime.
- Calls to `R_GetCCallable()` of a package that is not in `LinkingTo` are not
  detected.
- Copied code is not fingerprinted, so a change in a copied function does not
  trigger a rebuild. Objects copied by design, such as the generator functions
  of R6 classes, are not reported by `abi_deps()`.
- Hashes have not yet been verified to be identical across platforms, and the
  detection of `C API` and `linked library` dependencies has only been tested
  on macOS binaries.
