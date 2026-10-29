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

    record <- abiprint("conspkg")
    imports <- record[record$type == "import", ]
    expect_equal(imports$package, c("provpkg", "provpkg"))
    expect_equal(imports$key, c("class:Base", "version"))
    expect_equal(imports$hash[2], "1.0")
    exports <- record[record$type == "export", ]
    expect_equal(exports$package, c("conspkg", "conspkg"))
    expect_equal(exports$key, c("class:Derived", "version"))
    expect_equal(nrow(abi_check(record)), 0)
    fp1 <- abiprint("provpkg")
    expect_equal(unique(fp1$type), "export")
  })

  # Same code, new version: only the copied function is suspect
  install_pkg(make_provider(root, "1.1"), lib)
  with_lib(lib, {
    fp2 <- abiprint("provpkg")
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
  record <- with_lib(lib, abiprint("conspkg"))

  install_pkg(make_provider(root, "1.0", slots = 'representation(x = "numeric", z = "integer")',
                            header = "#define PROV 2"), lib)
  with_lib(lib, {
    expect_equal(abi_check(record)$reason, "S4 class Base changed")
    stale <- stale_classes("conspkg")
    expect_equal(stale$class, "Derived")
    expect_equal(stale$reason, "slots of superclass changed")
  })

  # Exports can also be supplied by the caller, e.g. from a repository
  expect_equal(abi_check(record, exports = record[0, ])$reason, "dependency not found")
})

test_that("imports and exports are stored as a flat list in JSON", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  record <- data.frame(type = c("export", "import", "import"), package = c("IRanges", "S4Vectors", "S4Vectors"),
                       key = c("version", "class:Vector", "version"), hash = c("2.47.5", "10ab26d3", "0.51.10"))
  json <- jsonlite::toJSON(record)
  expect_equal(as.character(json), paste0('[{"type":"export","package":"IRanges","key":"version","hash":"2.47.5"},',
                                          '{"type":"import","package":"S4Vectors","key":"class:Vector","hash":"10ab26d3"},',
                                          '{"type":"import","package":"S4Vectors","key":"version","hash":"0.51.10"}]'))
  exports <- data.frame(type = "export", package = "S4Vectors", key = c("class:Vector", "class:List", "version"),
                        hash = c("10ab26d3", "7cded7a2", "0.52.0"))
  check <- abi_check(jsonlite::fromJSON(json), exports = exports)
  expect_equal(check$reason, "version changed from 0.51.10 to 0.52.0")
  exports$hash[1] <- "changed"
  check <- abi_check(jsonlite::fromJSON(json), exports = exports[-3, ])
  expect_equal(check$reason, c("S4 class Vector changed", "version was removed"))
})
