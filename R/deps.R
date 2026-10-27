#' Critical dependencies of an installed package
#'
#' Finds the dependencies of which the installed package holds a copy, or
#' whose binary interface it was compiled against. When one of these changes,
#' the package may need to be rebuilt.
#'
#' The `type` column in the result is one of:
#'
#'  - `C API`: a `LinkingTo` dependency that the shared library calls at
#'    runtime via `R_GetCCallable()`. Changes in its headers (struct layouts,
#'    function signatures) break the binary.
#'  - `headers`: a `LinkingTo` dependency that is not called at runtime, for
#'    example a header-only or static library. The binary keeps working when
#'    it changes, so this is informational only.
#'  - `S4 class`: an S4 or reference class in the package extends this class
#'    from the dependency. The definition of the subclass, including the
#'    inherited slots, was copied at install time.
#'  - `copied code`: objects in the package (such as `f <- dep:::g`) contain
#'    functions or environments of the dependency.
#'
#' The package is inspected without loading it, but namespaces referenced by
#' its lazyload database are loaded. Call this in the library that was used to
#' build the package.
#'
#' @param pkg name of an installed package
#' @param lib.loc library to search, defaults to [.libPaths()]
#' @param ignore namespaces whose code is copied by design, such as the
#' generator functions of R6 classes.
#' @return a data frame with columns `package`, `type` and `detail`
#' @export
#' @examples
#' critical_deps("stats4")
critical_deps <- function(pkg, lib.loc = NULL, ignore = "R6"){
  path <- find.package(pkg, lib.loc)
  desc <- read_description(path)
  rows <- list()
  add <- function(package, type, detail = ""){
    rows[[length(rows) + 1]] <<- data.frame(package = package, type = type, detail = detail)
  }

  libs <- shared_objects(path)
  for (dep in parse_deps(desc$LinkingTo)) {
    add(dep, if (mentions_package(libs, dep)) "C API" else "headers")
  }

  db <- load_rdb(path, pkg)
  for (def in class_defs(db)) {
    for (ext in def@contains) {
      dep <- super_package(ext)
      if (dep %in% c(pkg, base_packages, "", ".GlobalEnv"))
        next
      provider <- provider_class(dep, ext@superClass, lib.loc)
      if (length(provider) && !"oldClass" %in% names(provider@contains))
        add(dep, "S4 class", as.character(ext@superClass))
    }
  }

  copied <- copied_code(db, pkg, ignore)
  for (dep in names(copied)) {
    add(dep, "copied code", paste(copied[[dep]], collapse = ", "))
  }

  out <- do.call(rbind, c(rows, list(data.frame(package = character(), type = character(), detail = character()))))
  out <- unique(out)
  out <- out[order(out$package, out$type, out$detail, method = "radix"), ]
  row.names(out) <- NULL
  out
}

provider_class <- function(dep, class, lib.loc){
  path <- tryCatch(find.package(dep, lib.loc), error = function(e) NULL)
  if (is.null(path))
    return(NULL)
  db <- load_rdb(path, dep)
  get0(paste0(".__C__", class), envir = db, inherits = FALSE)
}

# Walk all objects in the lazyload db and find closures or environments
# whose enclosure is the namespace of another package.
copied_code <- function(db, pkg, ignore = character()){
  skip <- "^\\.__(C|T)__|^\\.__NAMESPACE__\\.$|^\\.__S3MethodsTable__\\.$|^\\.packageName$|^\\.__rlang_hook__\\.$|^\\.S3MethodsClasses$"
  seen <- new.env(hash = TRUE, parent = emptyenv())
  hits <- list()
  walk <- function(x, name, depth = 0){
    if (depth > 30)
      return()
    if (methods::is(x, "genericFunction"))
      return() # method caches in generics are rebuilt when loaded
    if (is.function(x) && !is.primitive(x))
      return(walk(environment(x), name, depth + 1))
    if (is.environment(x)) {
      if (isNamespace(x)) {
        ns <- getNamespaceName(x)
        if (ns != pkg)
          hits[[ns]] <<- unique(c(hits[[ns]], name))
        return()
      }
      if (identical(x, globalenv()) || identical(x, baseenv()) || identical(x, emptyenv()))
        return()
      id <- format(x)
      if (exists(id, envir = seen, inherits = FALSE))
        return()
      assign(id, TRUE, envir = seen)
      for (nm in ls(x, all.names = TRUE)) {
        if (!bindingIsActive(nm, x))
          tryCatch(walk(get(nm, envir = x), name, depth + 1), error = function(e) NULL)
      }
      return(walk(parent.env(x), name, depth + 1))
    }
    if (is.list(x) || is.pairlist(x)) {
      for (el in x) walk(el, name, depth + 1)
    }
    if (isS4(x) && !is.function(x)) {
      for (sl in methods::slotNames(x)) walk(methods::slot(x, sl), name, depth + 1)
    }
    for (a in setdiff(names(attributes(x)), c("names", "class", "srcref", "row.names", "dim", "dimnames"))) {
      walk(attr(x, a), name, depth + 1)
    }
  }
  for (name in grep(skip, ls(db, all.names = TRUE), value = TRUE, invert = TRUE)) {
    tryCatch(walk(get(name, envir = db), name), error = function(e) NULL)
  }
  hits[setdiff(names(hits), c(base_packages, ignore))]
}
