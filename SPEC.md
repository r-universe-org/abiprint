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

The C functions of a package are recorded when it is installed from source,
because this requires its source files and the compiler flags it was built
with (from the output of `R CMD INSTALL`). Packages that were installed
otherwise have no C function exports.

### 4.1 Compile commands

The package is installed with `R CMD INSTALL`, which prints the compile
commands. A compile command is a line of this output that, split into words as
by a POSIX shell, contains the argument `-c` and exactly one argument with
extension `.c`, `.cc`, `.cpp`, `.cxx` or `.C` (the source file). Commands run
in the `src` directory of the package, or in the directory that make reports
when it enters another one (`make[n]: Entering directory '...'`, until the
matching `Leaving directory`).

### 4.2 Parsing

If the shared libraries of the package contain the bytes
`R_RegisterCCallable`, the source files of all its compile commands are parsed
as a translation unit by libclang, with the arguments:

```
-x c                        (for .c files, otherwise -x c++)
-resource-dir <the resource directory of the libclang>
<the arguments of the compile command that start with -I, -isystem, -iquote,
 -include, -isysroot, -D, -U, or -std=, in order; relative paths are made
 absolute with respect to the working directory of the command>
-w
-isysroot <SDK path>        (macOS only, unless already given)
```

A file is only used if it parses without diagnostics of severity error or
higher.

The *package directories* are the source directory of the package (which
contains its `DESCRIPTION`), and the `include` directories of its `LinkingTo`
dependencies.

### 4.3 Names and functions

In a parsed file, only code whose location (after macro expansion) is in the
source directory of the package is considered. In the arguments of a call, and
in the elements of an initializer list, a *pair* is a string literal that is
directly followed by an expression that refers to a function. Both are taken
after removing casts, parentheses, and unary operators (such as `&`), and
concatenated string literals (e.g. `"_" "name"`) form one name. This covers:

- `R_RegisterCCallable("pkg", "name", (DL_FUNC) &fun)`, also through a macro
  (e.g. `#define REG(f) R_RegisterCCallable("pkg", #f, (DL_FUNC) f)`),
- wrapper functions, e.g. `register_fn("name", (DL_FUNC) &fun)`,
- tables that are registered in a loop, e.g. `{"name", (DL_FUNC) &fun, 1}`.

A pair is of kind *register* if it is in the arguments of a call to
`R_RegisterCCallable`, otherwise of kind *pair*.

### 4.4 Registered functions and signatures

The package exports a C function `<name>` if `<name>` is the name of a pair,
and `R_GetCCallable("<package>", "<name>")` succeeds after loading the
installed package.

Its signature is the description (section 5) of the type of the function of
the pairs of kind register with this name, or if there are none, of the pairs
of kind pair. If there are several different descriptions, the signature is
these descriptions, sorted and joined with a newline. The hash is
`hash(signature)`.

The signatures are stored in the installed package, in the file `abi.json`:

```json
{"functions": [{"name": "new_IntAE", "signature": "function(...)->..."}, ...]}
```

### 4.5 Strings in shared libraries

A *string* in a shared library is a maximal run of 2 to 128 bytes from
`[A-Za-z0-9_]` that is followed by a NUL byte. (It is usually also preceded by
a NUL byte, but not if it is the first string in a section, which may follow
machine code.)

## 5. Type descriptions

A type is described by the following rules, applied to its canonical type
(typedefs are resolved, and qualifiers such as `const` are ignored).

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
  by `P` whose name is a string (section 4.5) in the shared libraries of `D`.
- Otherwise, if `P` ships a shared library in its `lib` directory (a file
  with extension `.so`, `.dylib` or `.dll`, optionally followed by a version
  such as `.so.2`) and the shared libraries of `D` contain its file name as a
  string (followed by NUL, preceded by `/` or by a character that is not in
  `[A-Za-z0-9._]`), then `P` is a **linked library** dependency, and `D`
  imports `P/include`.
- Otherwise, `D` imports nothing from `P` (header-only or static libraries are
  compiled into the binary of `D`).

C functions of packages that are not in `LinkingTo` are never imported, even
if `D` calls them with `R_GetCCallable()`. Without `LinkingTo`, `D` is not
compiled against the headers of `P`, but declares the functions itself, so
rebuilding `D` would not adapt it to a changed signature.

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
- C functions of packages that were installed without recording them (section
  4) are not exported, so dependents do not import them. Compile commands
  that are not printed by make (e.g. `@$(CC) ...`) are not found.
- C functions that are registered with a name that is computed at runtime
  (not a string literal next to the function) are not exported.
- Signatures depend on the platform ABI (sizes and alignments), and C++ types
  of the standard library (such as `std::string`) differ between libc++ and
  libstdc++. Signatures also depend on the compiler flags of the package.
  Results should only be compared between packages that were built on the
  same platform, with the same R and libclang setup.
