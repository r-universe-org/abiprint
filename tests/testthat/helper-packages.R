# Create and install small test packages in a temporary library
make_pkg <- function(root, name, version, code, namespace, imports = NULL,
                     linkingto = NULL, header = NULL){
  dir <- file.path(root, name)
  unlink(dir, recursive = TRUE)
  dir.create(file.path(dir, "R"), recursive = TRUE)
  desc <- c(Package = name, Version = version, Title = "Test Package",
            Description = "Test package.", License = "MIT",
            Author = "Test", Maintainer = "Test <test@example.com>",
            Imports = paste(c("methods", imports), collapse = ", "))
  if (length(linkingto))
    desc["LinkingTo"] <- linkingto
  write.dcf(t(desc), file.path(dir, "DESCRIPTION"))
  writeLines(code, file.path(dir, "R", "code.R"))
  writeLines(namespace, file.path(dir, "NAMESPACE"))
  if (length(header)) {
    dir.create(file.path(dir, "inst", "include"), recursive = TRUE)
    writeLines(header, file.path(dir, "inst", "include", paste0(name, ".h")))
  }
  dir
}

install_pkg <- function(dir, lib){
  for (pkg in c("conspkg", "provpkg")) {
    if (isNamespaceLoaded(pkg)) unloadNamespace(pkg)
  }
  status <- system2(file.path(R.home("bin"), "R"),
    c("CMD", "INSTALL", "--no-test-load", paste0("--library=", shQuote(lib)), shQuote(dir)),
    env = paste0("R_LIBS=", shQuote(lib)), stdout = FALSE, stderr = FALSE)
  stopifnot(status == 0)
}

make_provider <- function(root, version, slots = 'representation(x = "numeric")', header = "#define PROV 1"){
  make_pkg(root, "provpkg", version,
    code = c(sprintf('setClass("Base", %s)', slots),
             'setClass("Other", representation(a = "logical"))',
             'helper <- function(x) x + 1'),
    namespace = c("import(methods)", "exportClasses(Base, Other)", "export(helper)"),
    header = header)
}

make_consumer <- function(root){
  make_pkg(root, "conspkg", "1.0",
    code = c('setClass("Derived", contains = "Base", representation(y = "character"))',
             'plus_one <- provpkg::helper'),
    namespace = c("import(methods)", "importClassesFrom(provpkg, Base)",
                  "exportClasses(Derived)", "export(plus_one)"),
    imports = "provpkg", linkingto = "provpkg")
}

with_lib <- function(lib, code){
  old <- .libPaths()
  on.exit(.libPaths(old))
  .libPaths(c(lib, old))
  force(code)
}
