#' Install a package and record its C API
#'
#' Installs a package from source with `R CMD INSTALL`, and records the
#' signatures of the C functions that it registers with
#' `R_RegisterCCallable()`. These are stored in the installed package (in
#' `abi.json`), and are part of the exports in [abi_list()].
#'
#' The compile commands are logged with a compiler wrapper, which is set via
#' `R_MAKEVARS_USER` (on top of the user's own Makevars, if any). After the
#' installation, the source files that call `R_RegisterCCallable()` are parsed
#' by libclang with the same arguments. In these files, the signature of a
#' registered function is the type of the function that follows its name as a
#' string literal: in the arguments of `R_RegisterCCallable()` (also through a
#' macro or a wrapper function) or in a table such as `{"name", (DL_FUNC)
#' &fun, 1}`. Only the names for which `R_GetCCallable()` succeeds are
#' recorded. See SPEC.md for the details.
#'
#' Packages that do not register C functions are installed as usual.
#'
#' @param path a source package: a directory or a tarball
#' @param lib library to install the package into
#' @param args extra arguments for `R CMD INSTALL`
#' @param quiet hide the output of `R CMD INSTALL` (unless it fails)
#' @return the signatures of the registered C functions (invisibly)
#' @export
abi_install <- function(path, lib = .libPaths()[1], args = character(), quiet = FALSE){
  if (!dir.exists(path)) {
    exdir <- tempfile()
    utils::untar(path, exdir = exdir)
    path <- list.dirs(exdir, recursive = FALSE)[1]
  }
  path <- normalizePath(path)
  pkg <- read_description(path)$Package
  logdir <- tempfile("compile")
  dir.create(logdir)
  makevars <- tempfile(fileext = ".mk")
  on.exit(unlink(c(logdir, makevars), recursive = TRUE), add = TRUE)
  writeLines(compiler_makevars(), makevars)
  env <- c(paste0("R_MAKEVARS_USER=", shQuote(makevars)),
           paste0("ABITOOLS_COMPILE_LOG=", shQuote(logdir)),
           paste0("R_LIBS=", shQuote(paste(.libPaths(), collapse = .Platform$path.sep))))
  output <- if (quiet) tempfile() else ""
  status <- system2(file.path(R.home("bin"), "R"),
                    c("CMD", "INSTALL", "--preclean", paste0("--library=", shQuote(lib)), args, shQuote(path)),
                    env = env, stdout = output, stderr = output)
  if (status != 0) {
    if (quiet) cat(readLines(output), sep = "\n")
    stop("Failed to install ", pkg)
  }
  sigs <- record_c_functions(pkg, path, logdir, lib)
  invisible(sigs)
}

# Wrap the C and C++ compilers of R (from Makeconf) with the logging wrapper,
# on top of the user's own Makevars
compiler_makevars <- function(){
  wrapper <- system.file("bin", "abitools-cc", package = "abitools", mustWork = TRUE)
  user <- Sys.getenv("R_MAKEVARS_USER", path.expand("~/.R/Makevars"))
  c(if (file.exists(user)) paste("include", user),
    sprintf("%s := sh '%s' $(%s)", c("CC", "CXX", "CXX11", "CXX14", "CXX17", "CXX20", "CXX23"), wrapper,
            c("CC", "CXX", "CXX11", "CXX14", "CXX17", "CXX20", "CXX23")))
}

# Find the signatures of the registered C functions, and store them in the
# installed package
record_c_functions <- function(pkg, path, logdir, lib){
  installed <- file.path(lib, pkg)
  libs <- shared_objects(installed)
  out <- character()
  if (length(libs) && contains_bytes(libs, "R_RegisterCCallable")) {
    linkingto <- parse_deps(read_description(path)$LinkingTo)
    dirs <- c(path, file.path(find.package(linkingto, c(lib, .libPaths()), quiet = TRUE), "include"))
    dirs <- normalizePath(dirs[dir.exists(dirs)])
    pairs <- clang_pairs(compile_commands(logdir), path, dirs)
    names <- registered_names(pkg, lib, unique(pairs$name))
    out <- pick_signatures(pairs, names)
    names(out) <- names
  }
  functions <- data.frame(name = names(out) %||% character(), signature = unname(out))
  writeLines(jsonlite::toJSON(list(functions = functions), pretty = TRUE), file.path(installed, "abi.json"))
  out
}

# The names for which R_GetCCallable() succeeds, after loading the package
#' @useDynLib abitools, .registration = TRUE
registered_names <- function(pkg, lib, candidates){
  if (isNamespaceLoaded(pkg)) {
    unloadNamespace(pkg)
    for (dll in getLoadedDLLs()) {
      if (dll[["name"]] == pkg) dyn.unload(dll[["path"]])
    }
  }
  loadNamespace(pkg, lib.loc = c(lib, .libPaths()))
  ok <- vapply(candidates, function(name){
    isTRUE(tryCatch(.Call(abitools_ccallable, pkg, name), error = function(e) FALSE))
  }, logical(1))
  sort(candidates[ok], method = "radix")
}
