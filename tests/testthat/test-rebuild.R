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
    expect_equal(record$exports$key, "class:Derived")
    expect_equal(record$imports$package, "provpkg")
    expect_equal(record$imports$key, "class:Base")
    expect_equal(nrow(abi_check(record)), 0)
    fp1 <- abiprint("provpkg")
    expect_equal(fp1$exports$key, c("class:Base", "class:Other", "headers"))
    expect_equal(nrow(fp1$imports), 0)
  })

  # Same code, new version: nothing changed
  install_pkg(make_provider(root, "1.1"), lib)
  with_lib(lib, {
    expect_equal(abiprint("provpkg"), fp1)
    expect_equal(nrow(abi_check(record)), 0)
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
  expect_equal(abi_check(record, exports = list())$reason, "dependency not found")
})

test_that("packages without classes or headers have no exports", {
  x <- abiprint("tools")
  expect_equal(names(x$exports), c("key", "hash"))
  expect_equal(nrow(x$exports), 0)
  expect_equal(nrow(x$imports), 0)
})

test_that("imports and exports are stored as flat lists in JSON", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  record <- list(
    exports = data.frame(key = "class:Ranges", hash = "5f7f937e"),
    imports = data.frame(package = "S4Vectors", key = c("class:List", "class:Vector"), hash = c("7cded7a2", "10ab26d3"))
  )
  json <- jsonlite::toJSON(record)
  expect_equal(as.character(json), paste0('{"exports":[{"key":"class:Ranges","hash":"5f7f937e"}],',
                                          '"imports":[{"package":"S4Vectors","key":"class:List","hash":"7cded7a2"},',
                                          '{"package":"S4Vectors","key":"class:Vector","hash":"10ab26d3"}]}'))
  exports <- list(S4Vectors = data.frame(key = c("class:List", "class:Vector"), hash = c("7cded7a2", "10ab26d3")))
  expect_equal(nrow(abi_check(jsonlite::fromJSON(json), exports = exports)), 0)
  exports$S4Vectors$hash[2] <- "changed"
  expect_equal(abi_check(jsonlite::fromJSON(json), exports = exports)$reason, "S4 class Vector changed")
  exports$S4Vectors <- exports$S4Vectors[2, ]
  expect_equal(abi_check(jsonlite::fromJSON(json), exports = exports)$reason,
               c("S4 class List was removed", "S4 class Vector changed"))
})
