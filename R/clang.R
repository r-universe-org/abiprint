# Signatures of the C functions that a package registers, from its own sources
# (see SPEC.md). The source files are parsed by libclang with the arguments of
# the compile commands in the output of R CMD INSTALL (see abi_record()), and
# the types are described with the rules in clang.c.

clang_resource_dir <- function(){
  .Call(abitools_clang_resource_dir)
}

# The compile commands in the output of R CMD INSTALL: commands with the
# argument -c and exactly one source file. They run in the src directory of
# the package, unless make reports that it enters another directory.
log_commands <- function(lines, srcdir){
  dirs <- srcdir
  out <- list()
  for (line in lines) {
    m <- regmatches(line, regexec("make\\[[0-9]+\\]: (Entering|Leaving) directory ['`](.*)'", line))[[1]]
    if (length(m)) {
      if (m[2] == "Entering") dirs <- c(dirs, m[3]) else if (length(dirs) > 1) dirs <- dirs[-length(dirs)]
      next
    }
    if (!grepl(" -c ", line, fixed = TRUE))
      next
    args <- shell_words(line)
    src <- args[grepl("\\.(c|cc|cpp|cxx|C)$", args)]
    if (!"-c" %in% args || length(src) != 1)
      next
    dir <- dirs[length(dirs)]
    out[[length(out) + 1]] <- list(dir = dir, file = normalizePath(file.path(dir, src), mustWork = FALSE),
                                   args = clang_args(args, dir))
  }
  out
}

# Split a command line into words as a POSIX shell does (quotes, backslashes)
shell_words <- function(line){
  chars <- strsplit(line, "")[[1]]
  words <- character()
  cur <- character()
  inword <- FALSE
  quote <- ""
  i <- 1
  while (i <= length(chars)) {
    ch <- chars[i]
    if (quote == "'") {
      if (ch == "'") quote <- "" else cur <- c(cur, ch)
    } else if (quote == '"') {
      if (ch == '"') {
        quote <- ""
      } else if (ch == "\\" && i < length(chars) && chars[i + 1] %in% c('"', "\\", "$", "`")) {
        i <- i + 1
        cur <- c(cur, chars[i])
      } else {
        cur <- c(cur, ch)
      }
    } else if (ch %in% c("'", '"')) {
      quote <- ch
      inword <- TRUE
    } else if (ch == "\\" && i < length(chars)) {
      i <- i + 1
      cur <- c(cur, chars[i])
      inword <- TRUE
    } else if (ch %in% c(" ", "\t")) {
      if (inword) words <- c(words, paste(cur, collapse = ""))
      cur <- character()
      inword <- FALSE
    } else {
      cur <- c(cur, ch)
      inword <- TRUE
    }
    i <- i + 1
  }
  if (inword) words <- c(words, paste(cur, collapse = ""))
  words
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

# All pairs of a name and a function in the compiled source files (see
# find_pairs in clang.c). All files are parsed, because the registration may
# be in a file that is included by another one (unity builds), and tables of
# functions may be in a different file than the loop that registers them.
clang_pairs <- function(commands, own, dirs){
  sdk <- if (Sys.info()[["sysname"]] == "Darwin") {
    tryCatch(system2("xcrun", "--show-sdk-path", stdout = TRUE, stderr = FALSE), error = function(e) NULL)
  }
  # Files are parsed in parallel (each in a forked process on unix)
  cores <- getOption("abitools.cores", parallel::detectCores())
  out <- parallel::mclapply(commands, function(cmd){
    if (!file.exists(cmd$file))
      return(NULL)
    lang <- if (grepl("\\.c$", cmd$file)) "c" else "c++"
    args <- c("-x", lang, "-resource-dir", clang_resource_dir(), cmd$args, "-w")
    if (length(sdk) && !"-isysroot" %in% args)
      args <- c(args, "-isysroot", sdk)
    res <- .Call(abitools_clang_pairs, cmd$file, args, own, dirs)
    # Only files without errors: with errors, clang may substitute int for types
    if (length(res) && res[[4]] == 0)
      data.frame(name = res[[1]], kind = res[[2]], sig = res[[3]])
  }, mc.cores = if (.Platform$OS.type == "windows") 1L else cores)
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
