#' Fingerprints of the binary interface of a package
#'
#' `abi_fingerprint()` is computed for a package that others depend on. It
#' contains a hash of each S4 class definition and of the C headers in its
#' `include` directory. Unlike the version number, these only change when
#' something changes that dependents copy at build time.
#'
#' `abi_record()` is computed for a package right after it was built. It
#' records the fingerprints of the critical dependencies it was built against,
#' see [critical_deps()]. Only the classes that it extends are recorded, so a
#' change in other classes of the dependency does not trigger a rebuild. For
#' dependencies without a fingerprint (copied code, or a C API without
#' headers), it records the version instead.
#'
#' Both return a data frame with one row per fingerprint, in the same format,
#' so that [jsonlite::toJSON()] gives a flat list of entries that is easy to
#' query in a database. The `key` column is one of `class:<name>`, `headers`
#' or `version`.
#'
#' @inheritParams critical_deps
#' @return a data frame with columns `package`, `key` and `hash`
#' @export
#' @rdname fingerprint
#' @examples
#' abi_fingerprint("stats4")
abi_fingerprint <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  classes <- vapply(class_defs(load_rdb(path, pkg)), class_hash, "")
  names(classes) <- paste0("class:", names(classes))
  hashes <- c(version = read_description(path)$Version, headers = header_hash(path), classes)
  abi_table(pkg, names(hashes), unname(hashes))
}

#' @export
#' @rdname fingerprint
abi_record <- function(pkg, lib.loc = NULL, ignore = "R6"){
  deps <- critical_deps(pkg, lib.loc = lib.loc, ignore = ignore)
  deps <- deps[deps$type != "headers", ]
  keys <- abi_table()
  for (dep in unique(deps$package)) {
    rows <- deps[deps$package == dep, ]
    wanted <- paste0("class:", rows$detail[rows$type == "S4 class"])
    if ("C API" %in% rows$type)
      wanted <- c(wanted, "headers")
    fp <- abi_fingerprint(dep, lib.loc)
    # Without fingerprint, fall back to the version of the dependency
    if ("copied code" %in% rows$type || ("C API" %in% rows$type && !"headers" %in% fp$key))
      wanted <- c(wanted, "version")
    keys <- rbind(keys, fp[fp$key %in% wanted, ])
  }
  abi_table(keys$package, keys$key, keys$hash)
}

abi_table <- function(package = character(), key = character(), hash = character()){
  out <- data.frame(package = package, key = key, hash = hash)
  out <- out[order(out$package, out$key, method = "radix"), ]
  row.names(out) <- NULL
  out
}

# The slots include the inherited ones, so a change in any of the
# superclasses also changes the hash of the class.
class_hash <- function(def){
  slots <- def@slots
  slots <- sprintf("slot %s: %s@%s", names(slots), slots,
                   vapply(slots, function(s) attr(s, "package") %||% "", ""))
  supers <- vapply(def@contains, function(ext){
    sprintf("contains %s@%s", ext@superClass, super_package(ext))
  }, "")
  md5_text(c(def@className, paste("virtual:", def@virtual), sort(slots), sort(supers)))
}

header_hash <- function(path){
  inc <- file.path(path, "include")
  files <- sort(list.files(inc, recursive = TRUE))
  if (!length(files))
    return(NULL)
  md5_text(paste(files, tools::md5sum(file.path(inc, files))))
}
