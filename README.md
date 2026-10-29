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
   those headers. Header-only libraries (RcppArmadillo, BH, cpp11) and bundled
   static libraries (Rhtslib, Rhdf5lib) are different: their code is compiled
   into the binary, which keeps working when the dependency changes.
2. **S4 classes that extend a class from another package.** The stored
   definition of the subclass includes all inherited slots and superclasses. If
   the superclass changes, the subclass becomes inconsistent. This is the most
   common reason why Bioconductor packages need to be reinstalled.
3. **Copied code.** Objects created at install time that hold functions or
   environments of another package, such as `f <- dep:::helper`, ggproto
   objects inheriting from ggplot2, or S7 classes. These are reported by
   `critical_deps()`, but not fingerprinted: they are usually small aliases
   of internal helpers that keep working, and are left to periodic rebuilds.

Methods for generics from other packages (e.g. BiocGenerics) are registered
when the package is loaded and are not considered critical.

## Usage

`critical_deps()` lists the dependencies that an installed package holds a
copy of:

```r
critical_deps("Rsamtools")
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

A `LinkingTo` dependency is classified as `C API` if its name appears as a
string in the shared library of the package (which is how `R_GetCCallable()`
refers to it), and as `headers` otherwise.

`abiprint()` lists the ABI **exports** and **imports** of a package. The
exports are the parts that dependents may copy: a hash of each S4 class
definition (slots, superclasses, virtual) and of the files in its `include`
directory. Unlike the version, these hashes only change when something changes
that affects dependents. The imports are the exports of its critical
dependencies that the package copied when it was built: the classes that it
extends, and the headers of `C API` dependencies.

```r
abiprint("Rsamtools")
#> $exports
#>                            key                             hash
#> 1 Rsamtools::ApplyPileupsParam 614f6d9b9a46c60ec2728a5e00a85d0d
#> 2           Rsamtools::BamFile ee6ceb9eb98d7600984ba1d3c68a9288
#> ...
#>
#> $imports
#>                            key                             hash
#> 1           Biostrings/include dce746f9584e23b1fd191f87d0bb21c5
#> 2              IRanges/include 8b347f47098d58de136577ff44f8f7c0
#> 3            S4Vectors/include e2fc12515bdb6bc9b5b51ed7bcc79378
#> 4         S4Vectors::Annotated 95bf8c6a9de4f2f9373d24ccc74fe28a
#> 5              S4Vectors::List 7cded7a2c2addcb2a2d3392a89042c1e
#> 6        S4Vectors::SimpleList 0857578da91dd860b1c84fbffb582a79
#> 7            S4Vectors::Vector 10ab26d37b3e0ebc9fdf82fbfee25632
#> 8      S4Vectors::list_OR_List d8ee15be3bab82ef301792952f2d7259
#> 9  S4Vectors::vector_OR_Vector d1d36135046af6ee3cce1f81922f3392
#> 10             XVector/include 3e1b8282380e0e124f309ebac42e49c5
```

The key is `<package>::<class>` for an S4 class, and `<package>/include` for
the C headers. Because package names cannot contain `:` or `/`, the package is
always the part before the first `::` or `/`. An import is identical to the
export of the dependency that it was copied from, as long as that has not
changed.

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
`abiprint()` with the current exports of the dependencies, and returns the
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

1. When building a package, store the output of `abiprint()` with the binary.
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
- The header hash is coarse: any change in the `include` directory of a
  `C API` dependency triggers a rebuild. Headers of packages such as Rcpp
  change often, mostly in inline code that does not affect the ABI.
- The class hash ignores prototypes and validity methods. A changed prototype
  only results in stale defaults, and validity methods are looked up at
  runtime.
- Calls to `R_GetCCallable()` of a package that is not in `LinkingTo` are not
  detected.
- Copied code is not fingerprinted, so a change in a copied function does not
  trigger a rebuild. Objects copied by design, such as the generator functions
  of R6 classes, are not reported by `critical_deps()`.
- Hashes have not yet been verified to be identical across platforms.
