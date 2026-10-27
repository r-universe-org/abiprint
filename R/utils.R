`%||%` <- function(x, y) if (is.null(x)) y else x

base_packages <- c("base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils")

md5_text <- function(x){
  tmp <- tempfile()
  on.exit(unlink(tmp))
  writeBin(charToRaw(paste(x, collapse = "\n")), tmp)
  unname(tools::md5sum(tmp))
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

shared_objects <- function(path){
  list.files(file.path(path, "libs"), pattern = "\\.(so|dll|dylib)$",
             recursive = TRUE, full.names = TRUE)
}

# Packages that provide a C API via R_RegisterCCallable() are called through
# R_GetCCallable("pkg", "fun"), so the name of the package is stored as a
# string in the shared library of the caller.
mentions_package <- function(files, pkg){
  needle <- c(charToRaw(pkg), as.raw(0))
  for (file in files) {
    bytes <- readBin(file, "raw", file.size(file))
    for (pos in grepRaw(needle, bytes, fixed = TRUE, all = TRUE)) {
      if (pos == 1 || !grepl("[A-Za-z0-9._]", rawToChar(bytes[pos - 1])))
        return(TRUE)
    }
  }
  FALSE
}
