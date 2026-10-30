# Signatures of the C functions that a package registers, from its own sources
# (see SPEC.md). The source files are parsed by libclang with the arguments of
# the compile commands that were logged while the package was installed (see
# abi_install()), and the types are described with the rules in clang.c.

clang_resource_dir <- function(){
  .Call(abitools_clang_resource_dir)
}

# The logged compile commands: the directory, the source file, and the
# arguments for libclang (include directories, macros, language standard)
compile_commands <- function(logdir){
  files <- sort(list.files(logdir, full.names = TRUE), method = "radix")
  out <- lapply(files, function(file){
    fields <- strsplit(rawToChar(readBin(file, "raw", file.size(file))), "\037", fixed = TRUE)[[1]]
    dir <- fields[1]
    args <- fields[-1]
    src <- args[grepl("\\.(c|cc|cpp|cxx|C)$", args)]
    if (!"-c" %in% args || length(src) != 1)
      return(NULL)
    list(dir = dir, file = normalizePath(file.path(dir, src), mustWork = FALSE),
         args = clang_args(args, dir))
  })
  Filter(Negate(is.null), out)
}

# Keep the arguments that affect parsing, with paths relative to 'dir'
clang_args <- function(args, dir){
  out <- character()
  path_flags <- c("-I", "-isystem", "-iquote", "-include", "-isysroot")
  i <- 1
  while (i <= length(args)) {
    a <- args[i]
    flag <- path_flags[vapply(path_flags, startsWith, logical(1), x = a)]
    if (length(flag)) {
      flag <- flag[which.max(nchar(flag))]
      value <- if (a == flag) { i <- i + 1; args[i] } else substring(a, nchar(flag) + 1)
      if (!grepl("^/", value))
        value <- file.path(dir, value)
      out <- c(out, flag, value)
    } else if (grepl("^-(D|U)", a) || grepl("^-std=", a)) {
      out <- c(out, a)
    }
    i <- i + 1
  }
  out
}

# All pairs of a name and a function in the source files that register C
# functions (see find_pairs in clang.c)
clang_pairs <- function(commands, own, dirs){
  out <- list()
  for (cmd in commands) {
    if (!file.exists(cmd$file))
      next
    text <- readBin(cmd$file, "raw", file.size(cmd$file))
    if (!length(grepRaw("R_RegisterCCallable", text, fixed = TRUE)))
      next
    lang <- if (grepl("\\.c$", cmd$file)) "c" else "c++"
    args <- c("-x", lang, "-resource-dir", clang_resource_dir(), cmd$args, "-w")
    if (Sys.info()[["sysname"]] == "Darwin" && !"-isysroot" %in% args) {
      sdk <- tryCatch(system2("xcrun", "--show-sdk-path", stdout = TRUE, stderr = FALSE), error = function(e) NULL)
      if (length(sdk))
        args <- c(args, "-isysroot", sdk)
    }
    res <- .Call(abitools_clang_pairs, cmd$file, args, own, dirs)
    if (length(res) && res[[4]] == 0) {
      out[[length(out) + 1]] <- data.frame(name = res[[1]], kind = res[[2]], sig = res[[3]])
    } else if (length(res)) {
      warning(sprintf("Could not parse %s: %s", basename(cmd$file),
                      paste(na.omit(res[[5]]), collapse = "; ")), call. = FALSE)
    }
  }
  do.call(rbind, c(list(data.frame(name = character(), kind = character(), sig = character())), out))
}

# The signature of each name: from the arguments of R_RegisterCCallable() if
# possible, otherwise from other pairs (tables, wrapper functions)
pick_signatures <- function(pairs, names){
  vapply(names, function(name){
    for (kind in c("register", "pair")) {
      sig <- pairs$sig[pairs$kind == kind & pairs$name == name]
      if (length(sig))
        return(paste(sort(unique(sig), method = "radix"), collapse = "\n"))
    }
    NA_character_
  }, "", USE.NAMES = FALSE)
}
