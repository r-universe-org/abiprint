test_that("package names only match as separate C strings", {
  file <- tempfile()
  on.exit(unlink(file))
  write_bytes <- function(...) writeBin(c(...), file)
  nul <- as.raw(0)

  write_bytes(nul, charToRaw("Rsamtools"), nul)
  expect_true(abitools:::contains_string(file, "Rsamtools"))

  # Random bytes in machine code followed by the name
  write_bytes(as.raw(0xd0), charToRaw("BH"), nul)
  expect_false(abitools:::contains_string(file, "BH"))

  # Part of a longer string
  write_bytes(nul, charToRaw("libBH"), nul)
  expect_false(abitools:::contains_string(file, "BH"))
  write_bytes(nul, charToRaw("BHx"), nul)
  expect_false(abitools:::contains_string(file, "BH"))

  # Linked libraries are referenced by path, e.g. @rpath/libtbb.dylib
  write_bytes(charToRaw("@rpath/libtbb.dylib"), nul)
  expect_false(abitools:::contains_string(file, "libtbb.dylib"))
  expect_true(abitools:::contains_string(file, "libtbb.dylib", after = "/"))
})
