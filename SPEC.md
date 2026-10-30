# abitools specification

This document specifies how abitools computes the ABI exports and imports of
an installed R package, such that the results can be reproduced by other
implementations. It describes format version 1.

## 1. Overview

The **exports** of a package are hashes of the parts that dependents may copy
when they are built: S4 class definitions, C functions, and C headers. The
**imports** of a package are the exports of its dependencies that it copied,
with the hashes at the time it was built. A package needs to be rebuilt when
one of its imports no longer matches the current export of the dependency
(section 7).

Both are lists of entries with a `key` and a `hash`. The key identifies what
is hashed:

| key                    | what                                    |
|------------------------|-----------------------------------------|
| `<package>::<class>`   | an S4 class (section 3)                 |
| `<package>::<name>()`  | a registered C function (section 4)     |
| `<package>/include`    | all files in the `include` directory (section 2) |

Package names cannot contain `:` or `/`, so the package of a key is the part
before the first `::` or `/`.

Conventions in this document:

- `hash(lines)` is the first 16 characters of the SHA-256 hash, in lowercase
  hexadecimal, of the UTF-8 strings `lines` joined with a newline (`\n`),
  without a trailing newline.
- Sorting is by bytes (as in the C locale).
- The `include` directory of a package is `<installed package>/include`. The
  shared libraries of a package are the files in `<installed package>/libs`
  (recursively) with extension `.so`, `.dll` or `.dylib`, except for the debug
  information in `*.dSYM` directories on macOS.

## 2. Headers

If the `include` directory of a package contains files, the package exports
`<package>/include` with the hash

```
hash(for each file, sorted by path: "<path> <sha256 of the file>")
```

where `<path>` is the path of the file relative to the `include` directory,
with `/` as separator, and `<sha256 of the file>` is the full SHA-256 of its
bytes in lowercase hexadecimal.

## 3. S4 classes

A package exports every S4 or reference class that is defined in its
lazy-load database (the objects named `.__C__<class>`), with the hash

```
hash(<class name>,
    "virtual: TRUE" or "virtual: FALSE",
    sorted lines "slot <name>: <class>@<package>",
    sorted lines "contains <class>@<package>")
```

The slots include the inherited slots, and the superclasses include the
indirect ones (as stored in the class definition by R). `<package>` is the
`package` attribute of the slot class or superclass, or empty if it has none.

## 4. C functions

### 4.1 Registered functions

A package exports a C function `<name>` if:

1. its shared libraries contain the bytes `R_RegisterCCallable`,
2. `<name>` is a *string* (section 4.2) in its shared libraries,
3. `<name>` is a *derived name* of an identifier in its headers: for an
   identifier `w` (a match of `[A-Za-z_][A-Za-z0-9_]*` anywhere in a file in
   the `include` directory), the derived names are `w`, `_w`, `_<package>_w`,
   and `w` without a prefix that matches `^_?[A-Za-z0-9]+_`,
4. after loading the namespace of the package, `R_GetCCallable("<package>",
   "<name>")` succeeds.

The hash is `hash(signature)`, with the signature from section 5. If no
signature is found, the hash is the hash of the headers (section 2).

### 4.2 Strings in shared libraries

A *string* in a shared library is a maximal run of 2 to 128 bytes from
`[A-Za-z0-9_]` that is followed by a NUL byte. (It is usually also preceded by
a NUL byte, but not if it is the first string in a section, which may follow
machine code.)

## 5. Signatures

The signature of a registered function is found by parsing the headers of the
package with libclang.

### 5.1 Names to look for

For a registered name `<name>`, the *variants* are, in this order and without
duplicates: `<name>`; `<name>` without the prefix `_<package>_`; and `<name>`
without the prefix `_`. These cover the prefixes that stub macros add to the
registered name (e.g. `_new_IntAE` for `new_IntAE` in Bioconductor, and
`_pkg_fun` in Rcpp interfaces).

### 5.2 Headers to parse

The candidate headers are the files in the `include` directory (recursively)
with extension `.h`, `.hpp`, `.hh`, `.c`, `.cc`, `.cpp`, or no extension.
They are parsed in this order, without duplicates:

1. the candidates at the lowest directory depth, sorted by path,
2. the candidates whose text contains any variant of any registered name,
   sorted by path.

Parsing stops when a signature was found for every registered name.

### 5.3 Parsing

Each header is parsed as a translation unit by libclang with the arguments:

```
-x c -std=gnu17            (C)
-x c++ -std=gnu++17 -DR_NO_REMAP   (C++)
-resource-dir <the resource directory of the libclang>
-I<R include directory>
-I<include directory of the package>
-I<include directory of each LinkingTo dependency of the package, in order>
-w
-include Rinternals.h
-include R_ext/Rdynload.h
-isysroot <SDK path>        (macOS only)
```

Headers with extension `.hpp`, `.hh`, `.cc`, `.cpp`, or no extension are
parsed as C++. Other headers are parsed as C, and if that gives errors, as
C++. A header is only used if it parses without diagnostics of severity error
or higher.

The *package directories* are the include directories of the package and of
its LinkingTo dependencies.

### 5.4 Candidate signatures

In a parsed header, only declarations and expressions whose location (after
macro expansion) is in a file in the include directory of the package itself
are considered:

- **callsite**: a cast (C-style, `static_cast`, `reinterpret_cast`, or a
  functional cast) whose operand contains a call to `R_GetCCallable` with two
  arguments, without another cast in between, where the second argument is a
  string literal (or concatenated literals) equal to a variant. The signature
  is the description of the type of the cast.
- **declaration**: a function declaration or variable declaration whose
  canonical type is a function type or a pointer to a function type, and
  whose name equals a variant.
- **prefix**: as declaration, but the name is `<prefix>_<variant>` where
  `<prefix>` is a non-empty run of characters other than `_`, optionally
  preceded by `_` (e.g. `M_cholmod_aat` in Matrix, `_p_rxLlikBeta` in
  rxode2ll).

For each registered name, the signature is taken from the first header (in
the order of section 5.2) that has a candidate for it. Within that header, the
first kind in the order callsite, declaration, prefix, and within the kind the
first variant in the order of section 5.1, that has candidates is used. If
there are several (different) candidates of that kind and variant, the
signature is their descriptions, sorted and joined with a newline.

### 5.5 Type descriptions

A type is described by the following rules, applied to its canonical type
(typedefs are resolved, and qualifiers such as `const` are ignored). If the
type of a candidate is a pointer to a function, the function type is
described.

| type | description |
|------|-------------|
| pointer to `T` | `*T` |
| lvalue reference to `T` | `&T` |
| rvalue reference to `T` | `&&T` |
| array of `n` elements `T` | `[n]T` |
| array of unknown size of `T` | `[]T` |
| function | `function(T1,T2,...)->R`, with `,...` (or `...` without parameters) for variadic functions; `function()->R` for a function without a prototype |
| plain `char` | `Char` |
| signed integer types (`short`, `int`, `long`, `long long`, `__int128`) | `Int<bits>`, e.g. `Int32` |
| unsigned integer types | `UInt<bits>` |
| floating point types (`_Float16`, `float`, `double`, `long double`, `__float128`) | `Float<bits>` |
| `bool` | `Bool` |
| `void` | `Void` |
| other types | the name of the libclang type kind (`CXTypeKind` without prefix, e.g. `SChar`, `UChar`, `WChar`) followed by the size in bits |
| enum | `enum(I|v1,v2,...,)`: `I` is the description of the underlying integer type, followed by the values of the constants in order of declaration, each followed by `,`. For enums that are not defined in a package directory: `enum(I|Q)` with `Q` the qualified name |
| struct, union, or class | see below |

Sizes are in bits for builtin types (`<bits>` is 8 times the size in bytes).

A record (struct, union, or class) is **expanded** if it is defined in a file
in a package directory, its size is known, it is not described as a template
argument, it is at most 30 levels deep in the description, and it was not
already expanded in the same signature:

```
{<size>,<alignment>|<offset>:<field>;<offset>:<field>;...}
```

with the size and alignment in bytes, and for each field (in order of
declaration, excluding base classes): its offset in bits, followed by
`bits<width>:` for bit-fields, and the description of its type. Field names
are not used.

A record that was already expanded in the same signature is described as
`record#<i>`, where `<i>` is its position (starting at 1) in the order in
which records were expanded in that signature. This also stops recursion.

Other records are described as `record(Q,<size>)`, with the size in bytes as
reported by libclang (negative if unknown, e.g. `-2` for incomplete types).

The **qualified name** `Q` of a record or enum is the qualified name of its
enclosing namespace or class (if any) followed by `::`, its name (or
`anonymous` if it has none), and, for template specializations, its template
arguments between `<` and `>`, separated by `,`: types are described by the
rules above (where records are not expanded), integral values by their decimal
value, and other arguments as `?`. Inline namespaces are included (e.g.
`std::__1::basic_string` in libc++).

For example, `new_IntAE()` in S4Vectors, declared as

```c
typedef struct int_ae {
	size_t _buflength;
	size_t _nelt;
	int *elts;
} IntAE;

IntAE *new_IntAE(size_t buflength, size_t nelt, int val);
```

has the signature (on 64-bit platforms)

```
function(UInt64,UInt64,Int32)->*{24,8|0:UInt64;64:UInt64;128:*Int32;}
```

## 6. Imports

The imports of a package `D` are entries copied from the exports of its
dependencies, as computed when `D` was built (in the same library).

**S4 classes.** For each class in the lazy-load database of `D`, and each of
its superclasses (including indirect ones) from another package `P` (not `D`
itself, not a base package), `D` imports `P::<superclass>`. Superclasses that
were registered with `setOldClass()` (i.e. that extend `oldClass`) are
excluded.

**LinkingTo dependencies.** For each package `P` in the `LinkingTo` field of
`D`:

- If the shared libraries of `P` contain the bytes `R_RegisterCCallable`, and
  the shared libraries of `D` contain `P` as a string (followed by a NUL byte,
  and not preceded by a character from `[A-Za-z0-9._]`), then `P` is a
  **C API** dependency. `D` imports `P::<name>()` for each C function exported
  by `P` whose name is a string (section 4.2) in the shared libraries of `D`.
  If there are none, `D` imports `P/include` instead.
- Otherwise, if `P` ships a shared library in its `lib` directory (a file
  with extension `.so`, `.dylib` or `.dll`, optionally followed by a version
  such as `.so.2`) and the shared libraries of `D` contain its file name as a
  string (followed by NUL, preceded by `/` or by a character that is not in
  `[A-Za-z0-9._]`), then `P` is a **linked library** dependency, and `D`
  imports `P/include`.
- Otherwise, `D` imports nothing from `P` (header-only or static libraries are
  compiled into the binary of `D`).

## 7. Checking

Given the imports of a package and the current exports of its dependencies,
for each import `(key, hash)` with package `P`:

- if there are no exports of `P`: the dependency was not found,
- else if there is no export with `key`: it was removed,
- else if the hash of the export differs from `hash`: it changed.

The package needs to be rebuilt if any of these apply. New exports do not
matter.

## 8. Not covered

- Objects in a package that hold code of a dependency (e.g. `f <- dep:::g`)
  are reported by `abi_deps()` but not hashed.
- Registered C functions of a package that are not declared in its headers
  (or that have no headers at all) cannot be hashed.
- Signatures depend on the platform ABI (sizes and alignments), and C++ types
  of the standard library (such as `std::string`) differ between libc++ and
  libstdc++. Results should only be compared between packages that were
  inspected on the same platform, with the same R and libclang setup.
