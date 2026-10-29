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
    expect_equal(record$package, c("provpkg", "provpkg"))
    expect_equal(record$key, c("class:Base", "version"))
    expect_equal(record$hash[2], "1.0")
    expect_equal(nrow(abi_check(record)), 0)
    fp1 <- abi_fingerprint("provpkg")
  })

  # Same code, new version: only the copied function is suspect
  install_pkg(make_provider(root, "1.1"), lib)
  with_lib(lib, {
    fp2 <- abi_fingerprint("provpkg")
    expect_equal(fp1$key, c("class:Base", "class:Other", "headers", "version"))
    expect_equal(fp1[fp1$key != "version", ], fp2[fp2$key != "version", ])
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
  expect_equal(abi_check(record, fingerprints = record[0, ])$reason, "dependency not found")
})

test_that("records and fingerprints are stored as a flat list in JSON", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  record <- data.frame(package = "S4Vectors", key = c("class:Vector", "version"), hash = c("10ab26d3", "0.51.10"))
  json <- jsonlite::toJSON(record)
  expect_equal(as.character(json), paste0('[{"package":"S4Vectors","key":"class:Vector","hash":"10ab26d3"},',
                                          '{"package":"S4Vectors","key":"version","hash":"0.51.10"}]'))
  fingerprints <- data.frame(package = "S4Vectors", key = c("class:Vector", "class:List", "version"),
                             hash = c("10ab26d3", "7cded7a2", "0.52.0"))
  check <- abi_check(jsonlite::fromJSON(json), fingerprints = fingerprints)
  expect_equal(check$reason, "version changed from 0.51.10 to 0.52.0")
  fingerprints$hash[1] <- "changed"
  check <- abi_check(jsonlite::fromJSON(json), fingerprints = fingerprints[-3, ])
  expect_equal(check$reason, c("S4 class Vector changed", "version was removed"))
})
