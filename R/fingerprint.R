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
#' change in other classes of the dependency does not trigger a rebuild.
#'
#' Both return plain lists that can be stored as JSON.
#'
#' @inheritParams critical_deps
#' @export
#' @rdname fingerprint
#' @examples
#' fp <- abi_fingerprint("stats4")
#' str(fp)
abi_fingerprint <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  defs <- class_defs(load_rdb(path, pkg))
  list(
    package = pkg,
    version = read_description(path)$Version,
    headers = header_hash(path),
    classes = lapply(defs, class_hash)
  )
}

#' @export
#' @rdname fingerprint
abi_record <- function(pkg, lib.loc = NULL, ignore = "R6"){
  path <- find.package(pkg, lib.loc)
  deps <- critical_deps(pkg, lib.loc = lib.loc, ignore = ignore)
  deps <- deps[deps$type != "headers", ]
  record <- list()
  for (dep in unique(deps$package)) {
    rows <- deps[deps$package == dep, ]
    fp <- abi_fingerprint(dep, lib.loc)
    entry <- list(version = fp$version)
    if ("C API" %in% rows$type)
      entry$headers <- fp$headers
    classes <- rows$detail[rows$type == "S4 class"]
    if (length(classes))
      entry$classes <- fp$classes[classes]
    # Without fingerprint, fall back to the version of the dependency
    if ("copied code" %in% rows$type || ("C API" %in% rows$type && is.null(fp$headers)))
      entry$check_version <- TRUE
    record[[dep]] <- entry
  }
  list(
    package = pkg,
    version = read_description(path)$Version,
    dependencies = record
  )
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
