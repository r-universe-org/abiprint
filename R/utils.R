base_packages <- c("base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils")

md5_text <- function(x){
  unname(tools::md5sum(bytes = charToRaw(paste(x, collapse = "\n"))))
}

read_description <- function(path){
  as.list(read.dcf(file.path(path, "DESCRIPTION"))[1, ])
}

parse_deps <- function(x){
  if (!length(x) || is.na(x))
    return(character())
  deps <- trimws(sub("\\(.*", "", strsplit(x, ",")[[1]]))
  setdiff(deps[nzchar(deps)], c("R", base_packages))
}

# Objects in the lazyload databases of an installed package. These hold the
# state at install time. Unserializing may load the namespaces they refer to.
load_rdb <- function(path, pkg){
  db <- new.env(parent = emptyenv())
  for (file in file.path(path, "R", c(pkg, "sysdata"))) {
    if (file.exists(paste0(file, ".rdb")))
      suppressMessages(lazyLoad(file, envir = db))
  }
  db
}

class_defs <- function(db){
  names <- grep("^\\.__C__", ls(db, all.names = TRUE), value = TRUE)
  defs <- lapply(names, get, envir = db)
  names(defs) <- sub("^\\.__C__", "", names)
  defs
}

super_package <- function(ext){
  attr(ext@superClass, "package") %||% ""
}

# Shared libraries of a package, but not the debug info that macOS stores in
# libs/pkg.so.dSYM/Contents/Resources/DWARF/pkg.so
shared_objects <- function(path){
  files <- list.files(file.path(path, "libs"), pattern = "\\.(so|dll|dylib)$",
                      recursive = TRUE, full.names = TRUE)
  files[!grepl(".dSYM/", files, fixed = TRUE)]
}

# Shared libraries that a package ships for others to link against, such as
# the TBB library in RcppParallel.
shipped_libraries <- function(path){
  list.files(file.path(path, "lib"), pattern = "\\.(so|dylib|dll)(\\.[0-9.]+)?$", recursive = TRUE)
}

# Check if any of the files contains the string as a separate C string, i.e.
# preceded by a NUL byte (or one of the characters in 'after') and followed by
# NUL. Short strings such as "BH" also occur by chance inside machine code.
contains_string <- function(files, string, after = ""){
  starts <- as.raw(c(0, utf8ToInt(after)))
  needle <- c(charToRaw(string), as.raw(0))
  for (file in files) {
    bytes <- readBin(file, "raw", file.size(file))
    for (pos in grepRaw(needle, bytes, fixed = TRUE, all = TRUE)) {
      if (pos > 1 && bytes[pos - 1] %in% starts)
        return(TRUE)
    }
  }
  FALSE
}

contains_bytes <- function(files, string){
  for (file in files) {
    if (length(grepRaw(string, readBin(file, "raw", file.size(file)), fixed = TRUE)))
      return(TRUE)
  }
  FALSE
}
