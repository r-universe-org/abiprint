# Triggering rebuilds in a package repository

This describes how a package repository can use abiprint to rebuild packages
as soon as one of their dependencies makes a breaking change, and only then.
It is written for [r-universe](https://r-universe.dev), but applies to any
system that builds binary packages from source.

## What to store for each build

Run these right after the package has been installed in the build
environment, using the same library that it was built against:

- `abi_fingerprint(pkg)`: the hashes of the S4 classes and C headers of the
  package itself. Dependents are compared against this.
- `abi_record(pkg)`: the fingerprints of the parts of its critical
  dependencies that the package uses.

Store both with the package metadata. For efficient queries, store the record
as a flat list of entries, one per class or header set:

```js
_abi: [
  {package: 'S4Vectors', key: 'class:Vector', hash: '10ab26d3...'},
  {package: 'S4Vectors', key: 'class:List', hash: '7cded7a2...'},
  {package: 'S4Vectors', key: 'headers', hash: 'e2fc1251...'},
  {package: 'S4Vectors', key: 'version', hash: '0.51.10'}
]
```

The `version` entry is only present for dependencies of which the package
copied code (`check_version` in the record).

Fingerprints from one platform are enough, provided the hashes are identical
across platforms (not yet verified).

## After a package is deployed

Suppose a new version of S4Vectors changes the `Vector` and `List` classes.

### 1. Diff the old and new fingerprint

Fetch the fingerprint of the previous build of the package before replacing
it, and compare it with the new one, per class and for the headers. If
nothing changed, stop. This is the case for most deployments, including
version bumps without code changes, such as the twice-yearly version bump of
all Bioconductor packages.

The `version` entry is the exception: if the version changed, dependents that
recorded a `version` entry are affected as well.

### 2. Find the affected dependents

Query the packages that recorded one of the changed keys:

```js
{_abi: {$elemMatch: {package: 'S4Vectors', key: {$in: ['class:Vector', 'class:List']}}}}
```

Packages that only extend other classes of S4Vectors, such as `Rle` or
`DataFrame`, are not affected.

### 3. Rebuild only the first layer

S4 inheritance is transitive: the stored definition of a class includes all
of its superclasses. So the query above finds IRanges (`Ranges` extends
`Vector`), but also GenomicRanges (`GRanges` extends `IRanges::Ranges`, which
extends `Vector`).

Rebuilding both at once is wrong: GenomicRanges would be built against the
old IRanges, and need another rebuild once IRanges is updated. Therefore, skip
the affected packages that also have a critical dependency on another affected
package.

In the example, only IRanges is rebuilt. When its new build is deployed, the
hash of its `Ranges` class has changed, because it includes the inherited
slots of `Vector`. Step 1 and 2 then run for IRanges, and find GenomicRanges.
This way, the rebuilds propagate through the dependency graph one layer per
deployment, and each package is rebuilt exactly once, without any scheduling
logic.

## Nightly sweep

Rebuilds triggered by deployments can be missed:

- A rebuild of a package in the middle fails, so the next layer is never
  triggered.
- A change that does not affect the hash of subclasses, such as a class
  becoming virtual.
- Packages that were built before the fingerprints were introduced, or of
  which the trigger was lost.

As a safety net, a nightly job checks each package against the current
fingerprints of its dependencies (as `abi_check()` does), and rebuilds the
packages with differences, again skipping those that depend on another package
that needs a rebuild.

## Throttling

A real change in a core class can legitimately affect hundreds of packages.
The triggers should go into a rate-limited queue rather than a hard limit on
the number of dependents.

## Implementation in r-universe

What would need to change:

- **Build**: compute the fingerprint and the record in the build job, and
  deploy them with the package metadata.
- **cranlike-server**: store them (e.g. `_abi`), add an index on the record
  entries, and an endpoint that returns the affected dependents for a
  package and a list of changed keys.
- **Deploy workflow**: replace the `version_change` check in
  [`version.sh`](https://github.com/r-universe-org/actions/blob/v12/deploy-packages/version.sh)
  by the fingerprint diff, and let the `rechecks` job trigger the first layer
  of affected dependents. This also makes it possible to enable rebuilds for
  the Bioconductor universes again, see
  [help#740](https://github.com/r-universe-org/help/issues/740).
- **rebuilds**: a nightly job for the sweep, and a queue instead of the limit
  of 50 dependents in `trigger_revdeps()`.
