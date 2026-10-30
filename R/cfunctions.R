# Hashes of the C functions that a package registers with R_RegisterCCallable().
# The hash covers the signature of the function as described by libclang (see
# clang.R and SPEC.md). For functions that are not found in the headers, the
# hash of all headers is used instead.
c_function_hashes <- function(pkg, path, lib.loc = NULL){
  libs <- shared_objects(path)
  if (!length(libs) || !contains_bytes(libs, "R_RegisterCCallable"))
    return(character())
  names <- registered_callables(pkg, path, lib.loc)
  if (!length(names))
    return(character())
  fallback <- header_hash(path) %||% ""
  sigs <- clang_signatures(pkg, path, names, lib.loc)
  hashes <- ifelse(is.na(sigs), fallback, vapply(sigs, md5_text, ""))
  names(hashes) <- paste0(pkg, "::", names, "()")
  hashes
}

# There is no list of registered functions, so try the identifiers that are
# stored as strings in the shared library of the package, and that are also
# found in its headers (possibly with a prefix, see callable_variants()).
# Trying a name that is not registered is slow, so the headers narrow it down.
#' @useDynLib abitools, .registration = TRUE
registered_callables <- function(pkg, path, lib.loc = NULL){
  libs <- shared_objects(path)
  words <- header_words(path)
  if (!length(libs) || !length(words))
    return(character())
  loaded <- tryCatch(loadNamespace(pkg, lib.loc = lib.loc), error = function(e) NULL)
  if (is.null(loaded))
    return(character())
  words <- c(words, paste0("_", words), paste0("_", pkg, "_", words), sub("^_?[A-Za-z0-9]+_", "", words))
  candidates <- intersect(binary_strings(libs), words)
  ok <- vapply(candidates, function(name){
    isTRUE(tryCatch(.Call(abitools_ccallable, pkg, name), error = function(e) FALSE))
  }, logical(1))
  sort(candidates[ok], method = "radix")
}

# Identifiers in a binary that are stored as separate C strings. Cached,
# because a package is inspected both as a dependency and as a dependent.
strings_cache <- new.env(parent = emptyenv())

binary_strings <- function(files){
  unique(unlist(lapply(files, function(file){
    info <- file.info(file)
    id <- paste(normalizePath(file), info$size, as.numeric(info$mtime))
    strings_cache[[id]] <- strings_cache[[id]] %||% read_strings(file)
  })))
}

# Read the file in chunks that end at a NUL byte, to limit memory use for
# large binaries (the extraction needs about 20 bytes per byte of the chunk).
read_strings <- function(file, chunk_size = 16e6){
  con <- file(file, "rb")
  on.exit(close(con))
  out <- list()
  carry <- raw()
  repeat {
    bytes <- readBin(con, "raw", chunk_size)
    if (!length(bytes))
      break
    bytes <- c(carry, bytes)
    nul <- which(bytes == 0)
    if (!length(nul)) {
      # A long run without NUL contains no strings
      carry <- raw()
      next
    }
    last <- nul[length(nul)]
    out[[length(out) + 1]] <- chunk_strings(bytes[seq_len(last)])
    carry <- bytes[last:length(bytes)]
  }
  unique(unlist(out))
}

# Identifiers that end with a NUL byte. They usually also start after a NUL,
# but not if they are the first string of a section, which may follow code.
chunk_strings <- function(bytes){
  ident <- logical(256)
  ident[as.integer(charToRaw("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")) + 1L] <- TRUE
  ok <- ident[as.integer(bytes) + 1L]
  n <- length(bytes)
  starts <- which(ok & !c(FALSE, ok[-n]))
  ends <- which(ok & !c(ok[-1], FALSE))
  keep <- ends < n & ends > starts & ends - starts < 128L
  keep[keep] <- bytes[ends[keep] + 1L] == 0
  if (!any(keep))
    return(character())
  # Extract all strings at once, including the NUL that ends each of them
  chars <- bytes[sequence(ends[keep] - starts[keep] + 2L, from = starts[keep])]
  chars[chars == 0] <- as.raw(10)
  strsplit(rawToChar(chars), "\n", fixed = TRUE)[[1]]
}

# All identifiers in the headers of a package, also in comments and strings
header_words <- function(path){
  files <- list.files(file.path(path, "include"), recursive = TRUE, full.names = TRUE)
  unique(unlist(lapply(files, function(file){
    text <- readLines(file, warn = FALSE)
    regmatches(text, gregexpr("[A-Za-z_][A-Za-z0-9_]*", text, useBytes = TRUE))
  })))
}
