# Hashes of the C functions that a package registers with R_RegisterCCallable(),
# from the signatures that abi_install() stored in the installed package. For
# packages that were installed otherwise, these are unknown.
c_function_hashes <- function(pkg, path){
  file <- file.path(path, "abi.json")
  if (!file.exists(file))
    return(character())
  functions <- jsonlite::fromJSON(file)$functions
  if (!length(functions) || !nrow(functions))
    return(character())
  functions <- functions[!is.na(functions$signature), ]
  hashes <- vapply(functions$signature, hash_text, "", USE.NAMES = FALSE)
  names(hashes) <- paste0(pkg, "::", functions$name, "()")
  hashes
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
