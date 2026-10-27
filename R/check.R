#' Check if a package needs to be rebuilt
#'
#' `abi_check()` compares the record that was stored when the package was
#' built (see [abi_record()]) with the current fingerprints of its
#' dependencies. The package needs to be rebuilt if the result has any rows.
#'
#' `stale_classes()` needs no record: it compares the S4 class definitions in
#' an installed package with the current definitions of their superclasses in
#' other packages. This finds packages in a local library that must be
#' reinstalled after a dependency was updated.
#'
#' @param record list as returned by [abi_record()], possibly read from JSON
#' @param fingerprints named list with the current [abi_fingerprint()] of the
#' dependencies. If `NULL`, they are computed from the installed packages.
#' @inheritParams critical_deps
#' @return a data frame with the dependency and reason for each change
#' @export
#' @rdname check
abi_check <- function(record, fingerprints = NULL, lib.loc = NULL){
  out <- data.frame(package = character(), reason = character())
  add <- function(package, reason){
    out[nrow(out) + 1, ] <<- list(package, reason)
  }
  deps <- record$dependencies
  for (dep in names(deps)) {
    entry <- deps[[dep]]
    fp <- if (is.null(fingerprints)) {
      tryCatch(abi_fingerprint(dep, lib.loc), error = function(e) NULL)
    } else {
      fingerprints[[dep]]
    }
    if (is.null(fp)) {
      add(dep, "dependency not found")
      next
    }
    if (length(entry$headers) && !identical(entry$headers, fp$headers))
      add(dep, "C headers changed")
    for (class in names(entry$classes)) {
      now <- fp$classes[[class]]
      if (is.null(now)) {
        add(dep, sprintf("S4 class %s was removed", class))
      } else if (!identical(now, entry$classes[[class]])) {
        add(dep, sprintf("S4 class %s changed", class))
      }
    }
    if (isTRUE(entry$check_version) && !identical(entry$version, fp$version))
      add(dep, sprintf("version changed from %s to %s", entry$version, fp$version))
  }
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
