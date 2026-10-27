test_that("a version bump without changes does not require a rebuild", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  install_pkg(make_consumer(root), lib)

  with_lib(lib, {
    deps <- critical_deps("conspkg")
    expect_equal(deps$package, rep("provpkg", 3))
    expect_equal(deps$type, c("S4 class", "copied code", "headers"))
    expect_equal(deps$detail, c("Base", "plus_one", ""))

    record <- abi_record("conspkg")
    expect_named(record$dependencies$provpkg$classes, "Base")
    expect_null(record$dependencies$provpkg$headers)
    expect_equal(nrow(abi_check(record)), 0)
    fp1 <- abi_fingerprint("provpkg")
  })

  # Same code, new version: only the copied function is suspect
  install_pkg(make_provider(root, "1.1"), lib)
  with_lib(lib, {
    fp2 <- abi_fingerprint("provpkg")
    expect_equal(fp1$classes, fp2$classes)
    expect_equal(fp1$headers, fp2$headers)
    expect_equal(abi_check(record)$reason, "version changed from 1.0 to 1.1")
    expect_equal(nrow(stale_classes("conspkg")), 0)
  })
})

test_that("a changed superclass requires a rebuild", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  install_pkg(make_consumer(root), lib)
  record <- with_lib(lib, abi_record("conspkg"))

  install_pkg(make_provider(root, "1.0", slots = 'representation(x = "numeric", z = "integer")',
                            header = "#define PROV 2"), lib)
  with_lib(lib, {
    expect_equal(abi_check(record)$reason, "S4 class Base changed")
    stale <- stale_classes("conspkg")
    expect_equal(stale$class, "Derived")
    expect_equal(stale$reason, "slots of superclass changed")
  })

  # Fingerprints can also be supplied by the caller, e.g. from a repository
  expect_equal(abi_check(record, fingerprints = list())$reason, "dependency not found")
})
