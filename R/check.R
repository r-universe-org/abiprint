#' Check if a package needs to be rebuilt
#'
#' `abi_check()` compares the ABI imports of a package, as stored when it was
#' built (see [abiprint()]), with the current ABI exports of its
#' dependencies. The package needs to be rebuilt if the result has any rows.
#'
#' `stale_classes()` needs no stored imports: it compares the S4 class
#' definitions in an installed package with the current definitions of their
#' superclasses in other packages. This finds packages in a local library that
#' must be reinstalled after a dependency was updated.
#'
#' @param x list as returned by [abiprint()], possibly read from JSON. Only
#' the imports are used.
#' @param exports named list with the current exports of the dependencies,
#' e.g. `list(S4Vectors = abiprint("S4Vectors")$exports)`. If `NULL`, they are
#' computed from the installed packages.
#' @inheritParams critical_deps
#' @return a data frame with the dependency and reason for each change
#' @export
#' @rdname check
abi_check <- function(x, exports = NULL, lib.loc = NULL){
  imports <- x$imports
  if (is.null(exports)) {
    deps <- unique(imports$package)
    exports <- lapply(deps, function(dep){
      tryCatch(abi_exports(dep, lib.loc), error = function(e) NULL)
    })
    names(exports) <- deps
  }
  out <- data.frame(package = character(), reason = character())
  for (i in seq_len(nrow(imports))) {
    dep <- imports$package[i]
    key <- imports$key[i]
    current <- exports[[dep]]
    what <- if (key == "headers") "C headers" else paste("S4 class", sub("^class:", "", key))
    new <- current$hash[current$key == key]
    reason <- if (is.null(current)) {
      "dependency not found"
    } else if (!length(new)) {
      paste(what, "was removed")
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
  for (def in class_defs(load_rdb(path, pkg))) {
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
