#' ABI imports and exports of a package
#'
#' Lists the parts of the binary interface of an installed package that matter
#' for deciding when packages need to be rebuilt. Run this right after a
#' package was built, in the library that it was built with.
#'
#' The **exports** are the parts of the package that dependents may copy at
#' build time: a hash of each S4 class definition, a hash of the C headers in
#' its `include` directory, and the version. Unlike the version, the hashes
#' only change when something relevant changes.
#'
#' The **imports** are the exports of its critical dependencies (see
#' [critical_deps()]) that the package copied when it was built: the classes
#' that it extends and the headers of `C API` dependencies. Other classes of
#' the dependency are not included, so a change in those does not trigger a
#' rebuild. For dependencies without a hash (copied code, or a C API without
#' headers), the version is imported instead.
#'
#' A package needs to be rebuilt when one of its imports no longer matches the
#' current export of the dependency, see [abi_check()].
#'
#' The result is a flat data frame, so that [jsonlite::toJSON()] gives a list
#' of entries that is easy to store and query in a database.
#'
#' @inheritParams critical_deps
#' @return a data frame with columns `type` (`export` or `import`), `package`
#' (the package that exports it), `key` (`class:<name>`, `headers` or
#' `version`) and `hash`.
#' @export
#' @examples
#' abiprint("stats4")
abiprint <- function(pkg, lib.loc = NULL, ignore = "R6"){
  rbind(abi_exports(pkg, lib.loc), abi_imports(pkg, lib.loc, ignore))
}

abi_exports <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  classes <- vapply(class_defs(load_rdb(path, pkg)), class_hash, "")
  names(classes) <- paste0("class:", names(classes))
  hashes <- c(version = read_description(path)$Version, headers = header_hash(path), classes)
  abi_table("export", pkg, names(hashes), unname(hashes))
}

abi_imports <- function(pkg, lib.loc = NULL, ignore = "R6"){
  deps <- critical_deps(pkg, lib.loc = lib.loc, ignore = ignore)
  deps <- deps[deps$type != "headers", ]
  out <- abi_table()
  for (dep in unique(deps$package)) {
    rows <- deps[deps$package == dep, ]
    wanted <- paste0("class:", rows$detail[rows$type == "S4 class"])
    if ("C API" %in% rows$type)
      wanted <- c(wanted, "headers")
    exports <- abi_exports(dep, lib.loc)
    # Without a hash, fall back to the version of the dependency
    if ("copied code" %in% rows$type || ("C API" %in% rows$type && !"headers" %in% exports$key))
      wanted <- c(wanted, "version")
    out <- rbind(out, exports[exports$key %in% wanted, ])
  }
  abi_table("import", out$package, out$key, out$hash)
}

abi_table <- function(type = character(), package = character(), key = character(), hash = character()){
  out <- data.frame(type = rep(type, length.out = length(package)), package = package, key = key, hash = hash)
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
