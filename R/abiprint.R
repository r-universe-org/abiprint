#' ABI imports and exports of a package
#'
#' Lists the parts of the binary interface of an installed package that matter
#' for deciding when packages need to be rebuilt. Run this right after a
#' package was built, in the library that it was built with.
#'
#' The **exports** are the parts of the package that dependents may copy at
#' build time: a hash of each S4 class definition, and a hash of the C headers
#' in its `include` directory. Unlike the version, these hashes only change
#' when something changes that affects dependents.
#'
#' The **imports** are the exports of its dependencies that the package copied
#' when it was built: the classes that it extends, and the headers of `C API`
#' dependencies (see [critical_deps()]). Other classes of the dependency are
#' not included, so a change in those does not trigger a rebuild.
#'
#' A package needs to be rebuilt when one of its imports no longer matches the
#' current export of the dependency, see [abi_check()]. Code that was copied
#' from a dependency (such as `f <- dep:::g`) has no hash, and is left to
#' periodic rebuilds.
#'
#' The data frames are flat, so that [jsonlite::toJSON()] gives lists of
#' entries that are easy to store and query in a database.
#'
#' @inheritParams critical_deps
#' @return a list with data frames `exports` and `imports`, both with columns
#' `key` and `hash`. The key is `<package>::<class>` for an S4 class, or
#' `<package>/include` for the C headers. Package names cannot contain `:` or
#' `/`, so the package is everything before the first `::` or `/`.
#' @export
#' @examples
#' abiprint("stats4")
abiprint <- function(pkg, lib.loc = NULL){
  list(exports = abi_exports(pkg, lib.loc), imports = abi_imports(pkg, lib.loc))
}

abi_exports <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  defs <- class_defs(load_rdb(path, pkg))
  headers <- header_hash(path)
  abi_table(
    key = c(if (length(headers)) paste0(pkg, "/include"), if (length(defs)) paste0(pkg, "::", names(defs))),
    hash = c(headers, vapply(defs, class_hash, "", USE.NAMES = FALSE))
  )
}

abi_imports <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  deps <- rbind(linkingto_deps(path), s4_deps(load_rdb(path, pkg), pkg, lib.loc))
  deps <- deps[deps$type != "headers", ]
  out <- abi_table()
  for (dep in unique(deps$package)) {
    rows <- deps[deps$package == dep, ]
    wanted <- paste0(dep, "::", rows$detail[rows$type == "S4 class"])
    if ("C API" %in% rows$type)
      wanted <- c(wanted, paste0(dep, "/include"))
    exports <- abi_exports(dep, lib.loc)
    out <- rbind(out, exports[exports$key %in% wanted, ])
  }
  abi_table(out$key, out$hash)
}

abi_table <- function(key = character(), hash = character()){
  out <- data.frame(key = c(character(), key), hash = c(character(), hash))
  out <- out[order(out$key, method = "radix"), ]
  row.names(out) <- NULL
  out
}

# Package names cannot contain ':' or '/'
key_package <- function(key){
  sub("(::|/).*$", "", key)
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
