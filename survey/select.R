# Select the packages for the survey: commonly used packages with C APIs or
# S4 classes that other packages build on, their most used dependents, and a
# curated list of packages that do unusual things.
db <- available.packages()
db <- db[!duplicated(rownames(db)), ]
linkingto <- tools::package_dependencies(rownames(db), db = db, which = "LinkingTo")
revdeps <- lengths(tools::package_dependencies(rownames(db), db = db, reverse = TRUE,
                                               which = c("Depends", "Imports", "LinkingTo")))

# Providers: LinkingTo targets of at least 3 packages
counts <- table(unlist(linkingto))
providers <- intersect(names(counts)[counts >= 3], rownames(db))

# The 2 most used dependents of each provider (by their own reverse dependencies)
consumers <- unlist(lapply(providers, function(p){
  users <- names(Filter(function(x) p %in% x, linkingto))
  head(users[order(-revdeps[users])], 2)
}))

# The 40 most used Bioconductor packages (S4 infrastructure)
bioc <- rownames(db)[grepl("bioc", db[, "Repository"])]
hubs <- head(bioc[order(-revdeps[bioc])], 40)

curated <- c(
  # C APIs that are registered without being a common LinkingTo target, or in
  # unusual ways (function pointers, casts at call sites, macros)
  "rlang", "vctrs", "glmmTMB", "RNifti", "rxode2", "rxode2ll", "PreciseSums",
  "libgeos", "libproj", "h3lib", "actuar", "expint", "revdbayes", "dparser",
  "fastmatrix", "VineCopula", "xts", "zoo", "data.table", "digest", "checkmate",
  "stringi", "systemfonts", "textshaping", "qs2", "stringfish", "lotri",
  # Vendored and linked libraries, very large binaries
  "RcppParallel", "rstan", "arrow", "duckdb", "V8", "sf", "terra", "igraph",
  "Rhtslib", "Rhdf5lib", "rhdf5", "h5mread", "HDF5Array", "mzR", "rJava",
  # Copied code (ggproto, R6, S7) and S4 classes on CRAN
  "ggplot2", "ggforce", "ggraph", "patchwork", "shiny", "R6", "S7", "Matrix",
  "lme4", "TMB", "RTMB", "SeuratObject", "sp", "raster",
  # Bioconductor infrastructure and packages that use its C APIs
  "S4Vectors", "IRanges", "XVector", "Biostrings", "GenomicRanges",
  "GenomicAlignments", "Rsamtools", "VariantAnnotation", "SummarizedExperiment",
  "SingleCellExperiment", "DelayedArray", "SparseArray", "S4Arrays", "BSgenome",
  "ShortRead", "DropletUtils", "scuttle", "scran", "beachmat", "csaw",
  "bamsignals", "DECIPHER", "pwalign", "cigarillo", "BiocParallel"
)

packages <- sort(unique(intersect(c(providers, consumers, hubs, curated), rownames(db))), method = "radix")
message(sprintf("Selected %d packages: %d providers, %d dependents, %d Bioconductor, %d curated",
                length(packages), length(providers), length(unique(consumers)), length(hubs), length(curated)))
writeLines(packages)
