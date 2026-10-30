#' Record the C API of a package at build time
#'
#' `abi_record()` records the signatures of the C functions that a package
#' registers with `R_RegisterCCallable()`, right after it was installed from
#' source with `R CMD INSTALL`. It needs the source directory of the package and
#' the output of `R CMD INSTALL`, which contains the compile commands. The
#' signatures are stored in the installed package (in `abi.json`), and are part
#' of the exports in [abi_list()].
#'
#' The compiled source files are parsed by libclang with the arguments of their
#' compile commands (include directories, macros, language standard). In these
#' files, the signature of a registered function is the type of the function
#' that follows its name as a string literal: in the arguments of
#' `R_RegisterCCallable()` (also through a macro or a wrapper function), or in a
#' table such as `{"name", (DL_FUNC) &fun, 1}`. Only the names for which
#' `R_GetCCallable()` succeeds are recorded. See SPEC.md for the details.
#'
#' `abi_install()` installs a package with `R CMD INSTALL`, and calls
#' `abi_record()` with its output.
#'
#' @param path the source directory of the package (for `abi_install()` also a
#' tarball)
#' @param log the output of `R CMD INSTALL`: a file, or a character vector of
#' lines
#' @param lib the library that the package was installed into
#' @return the signatures of the registered C functions (invisibly)
#' @export
#' @rdname abi_record
abi_record <- function(path, log, lib = .libPaths()[1]){
  path <- normalizePath(path)
  pkg <- read_description(path)$Package
  lines <- if (length(log) == 1 && file.exists(log)) readLines(log, warn = FALSE) else log
  installed <- file.path(lib, pkg)
  libs <- shared_objects(installed)
  out <- character()
  if (length(libs) && contains_bytes(libs, "R_RegisterCCallable")) {
    commands <- log_commands(lines, file.path(path, "src"))
    if (!length(commands))
      warning("No compile commands found in the output of R CMD INSTALL for ", pkg, call. = FALSE)
    linkingto <- parse_deps(read_description(path)$LinkingTo)
    dirs <- c(path, file.path(find.package(linkingto, c(lib, .libPaths()), quiet = TRUE), "include"))
    dirs <- normalizePath(dirs[dir.exists(dirs)])
    pairs <- clang_pairs(commands, path, dirs)
    names <- registered_names(pkg, lib, unique(pairs$name))
    out <- pick_signatures(pairs, names)
    names(out) <- names
  }
  functions <- data.frame(name = names(out) %||% character(), signature = unname(out))
  writeLines(jsonlite::toJSON(list(functions = functions), pretty = TRUE), file.path(installed, "abi.json"))
  invisible(out)
}

#' @param args extra arguments for `R CMD INSTALL`
#' @param quiet hide the output of `R CMD INSTALL` (unless it fails)
#' @export
#' @rdname abi_record
abi_install <- function(path, lib = .libPaths()[1], args = character(), quiet = FALSE){
  if (!dir.exists(path)) {
    exdir <- tempfile()
    utils::untar(path, exdir = exdir)
    path <- list.dirs(exdir, recursive = FALSE)[1]
  }
  path <- normalizePath(path)
  log <- tempfile()
  on.exit(unlink(log))
  status <- system2(file.path(R.home("bin"), "R"),
                    c("CMD", "INSTALL", "--preclean", paste0("--library=", shQuote(lib)), args, shQuote(path)),
                    env = paste0("R_LIBS=", shQuote(paste(.libPaths(), collapse = .Platform$path.sep))),
                    stdout = log, stderr = log)
  if (!quiet || status != 0)
    cat(readLines(log, warn = FALSE), sep = "\n")
  if (status != 0)
    stop("Failed to install ", read_description(path)$Package)
  abi_record(path, log, lib)
}

# The names for which R_GetCCallable() succeeds, after loading the installed
# package. This runs in a new R process, because the package (or an older
# version) may already be loaded in this one.
#' @useDynLib abitools, .registration = TRUE
registered_names <- function(pkg, lib, candidates){
  if (!length(candidates))
    return(character())
  input <- tempfile()
  output <- tempfile()
  on.exit(unlink(c(input, output)))
  writeLines(candidates, input)
  dll <- getLoadedDLLs()[["abitools"]][["path"]]
  code <- sprintf(
    '.libPaths(%s); loadNamespace("%s"); dyn.load("%s"); names <- readLines("%s");
     ok <- vapply(names, function(n) isTRUE(tryCatch(.Call("abitools_ccallable", "%s", n, PACKAGE = "abitools"),
       error = function(e) FALSE)), logical(1)); writeLines(names[ok], "%s")',
    deparse1(c(lib, .libPaths())), pkg, dll, input, pkg, output)
  status <- system2(file.path(R.home("bin"), "Rscript"), c("-e", shQuote(code)), stdout = FALSE, stderr = FALSE)
  if (status != 0 || !file.exists(output))
    stop("Failed to load ", pkg, " to find its registered C functions")
  sort(readLines(output), method = "radix")
}
