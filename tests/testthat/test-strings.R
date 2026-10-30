test_that("package names only match as separate C strings", {
  file <- tempfile()
  on.exit(unlink(file))
  write_bytes <- function(...) writeBin(c(...), file)
  nul <- as.raw(0)

  write_bytes(nul, charToRaw("Rsamtools"), nul)
  expect_true(abitools:::contains_string(file, "Rsamtools"))

  # The first string of a section may directly follow machine code
  write_bytes(as.raw(c(0xc0, 0x03, 0x5f, 0xd6)), charToRaw("prov_add"), nul)
  expect_true(abitools:::contains_string(file, "prov_add"))
  expect_equal(abitools:::read_strings(file), "prov_add")

  # Part of a longer string
  write_bytes(nul, charToRaw("libBH"), nul)
  expect_false(abitools:::contains_string(file, "BH"))
  write_bytes(nul, charToRaw("BHx"), nul)
  expect_false(abitools:::contains_string(file, "BH"))

  # Linked libraries are referenced by path, e.g. @rpath/libtbb.dylib
  write_bytes(charToRaw("@rpath/libtbb.dylib"), nul)
  expect_true(abitools:::contains_string(file, "libtbb.dylib", after = "/"))
})

test_that("package names of C APIs also match as the tail of a string", {
  file <- tempfile()
  on.exit(unlink(file))
  # Linkers merge "IRanges" into the tail of "_new_IRanges"
  writeBin(c(as.raw(0), charToRaw("_new_IRanges"), as.raw(0)), file)
  expect_false(abitools:::contains_string(file, "IRanges"))
  expect_true(abitools:::contains_string_end(file, "IRanges"))
  expect_false(abitools:::contains_string_end(file, "Ranges_"))
})
