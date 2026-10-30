# Inspect one installed package with abitools, and print one line of JSON with
# diagnostics. Runs in its own process (see survey.sh), because inspecting a
# package loads its namespace and those of its dependencies.
pkg <- commandArgs(TRUE)[1]
ns <- asNamespace("abitools")
warnings <- character()
start <- Sys.time()

kinds <- function(keys){
  c(classes = sum(grepl("::", keys) & !endsWith(keys, "()")),
    functions = sum(endsWith(keys, "()")),
    headers = sum(grepl("/include$", keys)))
}

result <- withCallingHandlers(tryCatch({
  path <- find.package(pkg)
  x <- abitools::abi_list(pkg)
  deps <- abitools::abi_deps(pkg)
  registered <- ns$registered_callables(pkg, path)
  sigs <- ns$clang_signatures(pkg, path, registered)
  back <- jsonlite::fromJSON(jsonlite::toJSON(x))

  # Possible calls to R_GetCCallable() of packages that are not a dependency:
  # the binary contains the name of another package that registers C functions,
  # and the name of at least one of those functions
  strings <- ns$binary_strings(ns$shared_objects(path))
  undeclared <- character()
  if ("R_GetCCallable" %in% strings) {
    desc <- ns$read_description(path)
    strong <- unlist(lapply(desc[c("LinkingTo", "Imports", "Depends")], ns$parse_deps))
    others <- setdiff(intersect(strings, rownames(installed.packages())), c(pkg, strong, ns$base_packages))
    undeclared <- Filter(function(p){
      any(ns$registered_callables(p, find.package(p)) %in% strings)
    }, others)
  }

  list(
    status = "ok",
    exports = as.list(kinds(x$exports$key)),
    imports = as.list(kinds(x$imports$key)),
    json_bytes = nchar(jsonlite::toJSON(x)),
    registered = length(registered),
    with_signature = sum(!is.na(sigs)),
    without_signature = registered[is.na(sigs)],
    deps = as.list(table(deps$type)),
    c_api = unique(deps$package[deps$type == "C API"]),
    linked_library = unique(deps$package[deps$type == "linked library"]),
    undeclared_c_api = undeclared,
    # Within a consistent library, nothing should be reported
    check = abitools::abi_check(back)$reason,
    stale_classes = nrow(abitools::stale_classes(pkg))
  )
}, error = function(e) list(status = "error", error = conditionMessage(e))),
warning = function(w){
  warnings <<- c(warnings, conditionMessage(w))
  invokeRestart("muffleWarning")
})

result <- c(list(package = pkg, seconds = round(as.numeric(Sys.time() - start, units = "secs"), 1)),
            result, list(warnings = unique(warnings)))
cat(jsonlite::toJSON(result, auto_unbox = TRUE), "\n")
