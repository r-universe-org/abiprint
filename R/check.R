#' Check if a package needs to be rebuilt
#'
#' `abi_check()` compares the ABI imports of a package, as stored when it was
#' built (see [abi_list()]), with the current ABI exports of its
#' dependencies. The package needs to be rebuilt if the result has any rows.
#'
#' `stale_classes()` needs no stored imports: it compares the S4 class
#' definitions in an installed package with the current definitions of their
#' superclasses in other packages. This finds packages in a local library that
#' must be reinstalled after a dependency was updated.
#'
#' @param x list as returned by [abi_list()], possibly read from JSON. Only
#' the imports are used.
#' @param exports data frame with the current exports of the dependencies,
#' e.g. the combined `exports` of [abi_list()] for each of them. If `NULL`,
#' they are computed from the installed packages.
#' @inheritParams abi_deps
#' @return a data frame with the dependency and reason for each change
#' @export
#' @rdname check
abi_check <- function(x, exports = NULL, lib.loc = NULL){
  # jsonlite::fromJSON() turns an empty array into list()
  imports <- abi_table(x$imports$key, x$imports$hash)
  if (is.null(exports)) {
    exports <- do.call(rbind, c(list(abi_table()), lapply(unique(key_package(imports$key)), function(dep){
      tryCatch(abi_exports(dep, lib.loc), error = function(e) NULL)
    })))
  }
  exports <- abi_table(exports$key, exports$hash)
  out <- data.frame(package = character(), reason = character())
  for (i in seq_len(nrow(imports))) {
    key <- imports$key[i]
    dep <- key_package(key)
    what <- if (endsWith(key, "()")) {
      paste("C function", sub("^[^:]*::", "", key))
    } else if (grepl("::", key, fixed = TRUE)) {
      paste("S4 class", sub("^[^:]*::", "", key))
    } else {
      "C headers"
    }
    new <- exports$hash[exports$key == key]
    reason <- if (!dep %in% key_package(exports$key)) {
      "dependency not found"
    } else if (!length(new)) {
      paste(what, "removed")
    } else if (!identical(new, imports$hash[i])) {
      paste(what, "changed")
    }
    if (length(reason))
      out[nrow(out) + 1, ] <- list(dep, reason)
  }
  out <- unique(out)
  row.names(out) <- NULL
  out
}

#' @export
#' @rdname check
stale_classes <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  out <- data.frame(class = character(), package = character(), superclass = character(), reason = character())
  for (def in class_defs(load_rdb(path, pkg), pkg)) {
    for (ext in def@contains) {
      dep <- super_package(ext)
      if (dep %in% c(pkg, base_packages, "", ".GlobalEnv"))
        next
      super <- as.character(ext@superClass)
      provider <- provider_class(dep, super, lib.loc)
      reason <- if (is.null(provider)) {
        "superclass no longer exists"
      } else if (!slots_match(provider@slots, def@slots)) {
        "slots of superclass changed"
      } else if (!all(names(provider@contains) %in% names(def@contains))) {
        "superclasses of superclass changed"
      }
      if (length(reason))
        out[nrow(out) + 1, ] <- list(def@className, dep, super, reason)
    }
  }
  out
}

# All slots of the superclass must be present in the subclass, with the same
# type or a subclass of it (subclasses may narrow the type of a slot).
slots_match <- function(super, sub){
  if (!all(names(super) %in% names(sub)))
    return(FALSE)
  for (name in names(super)) {
    a <- sub[[name]]
    b <- super[[name]]
    if (!identical(as.character(a), as.character(b)) && !isTRUE(tryCatch(methods::extends(a, b), error = function(e) FALSE)))
      return(FALSE)
  }
  TRUE
}
