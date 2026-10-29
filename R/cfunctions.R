# Hashes of the C functions that a package registers with R_RegisterCCallable().
# The hash covers the declaration of the function in the headers of the
# package, and the definitions of the types that it uses. If no declaration is
# found, the hash of all headers is used instead.
c_function_hashes <- function(pkg, path, lib.loc = NULL){
  libs <- shared_objects(path)
  if (!length(libs) || !contains_bytes(libs, "R_RegisterCCallable"))
    return(character())
  headers <- read_headers(path)
  names <- registered_callables(pkg, path, headers, lib.loc)
  if (!length(names))
    return(character())
  statements <- unlist(lapply(headers, header_statements))
  defs <- type_definitions(statements)
  fallback <- header_hash(path) %||% ""
  hashes <- vapply(names, function(name){
    sig <- callable_signature(statements, defs, name, pkg, headers)
    if (length(sig)) md5_text(sig) else fallback
  }, "")
  names(hashes) <- paste0(pkg, "::", names, "()")
  hashes
}

# There is no list of registered functions, so try the identifiers that are
# stored as strings in the shared library of the package, and that are also
# found in its headers (possibly with a prefix, see callable_signature()).
# Trying a name that is not registered is slow, so the headers narrow it down.
#' @useDynLib abitools, .registration = TRUE
registered_callables <- function(pkg, path, headers, lib.loc = NULL){
  libs <- shared_objects(path)
  if (!length(libs) || !length(headers))
    return(character())
  loaded <- tryCatch(loadNamespace(pkg, lib.loc = lib.loc), error = function(e) NULL)
  if (is.null(loaded))
    return(character())
  words <- unique(unlist(regmatches(headers, gregexpr("[A-Za-z_]\\w*", headers, perl = TRUE))))
  words <- sub(paste0("^", callsite_marker), "", words)
  words <- c(words, paste0("_", words), paste0("_", pkg, "_", words), sub(paste0("^", name_prefix), "", words))
  candidates <- intersect(binary_strings(libs), words)
  ok <- vapply(candidates, function(name){
    isTRUE(tryCatch(.Call(abitools_ccallable, pkg, name), error = function(e) FALSE))
  }, logical(1))
  sort(candidates[ok])
}

# Identifiers in a binary that are stored as separate C strings. Cached,
# because a package is inspected both as a dependency and as a dependent.
strings_cache <- new.env(parent = emptyenv())

binary_strings <- function(files){
  unique(unlist(lapply(files, function(file){
    info <- file.info(file)
    id <- paste(normalizePath(file), info$size, as.numeric(info$mtime))
    strings_cache[[id]] <- strings_cache[[id]] %||% read_strings(file)
  })))
}

# Read the file in chunks that end at a NUL byte, to limit memory use for
# large binaries (the extraction needs about 20 bytes per byte of the chunk).
read_strings <- function(file, chunk_size = 16e6){
  con <- file(file, "rb")
  on.exit(close(con))
  out <- list()
  carry <- raw()
  repeat {
    bytes <- readBin(con, "raw", chunk_size)
    if (!length(bytes))
      break
    bytes <- c(carry, bytes)
    nul <- which(bytes == 0)
    if (!length(nul)) {
      # A long run without NUL contains no strings
      carry <- raw()
      next
    }
    last <- nul[length(nul)]
    out[[length(out) + 1]] <- chunk_strings(bytes[seq_len(last)])
    carry <- bytes[last:length(bytes)]
  }
  unique(unlist(out))
}

chunk_strings <- function(bytes){
  ident <- logical(256)
  ident[as.integer(charToRaw("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")) + 1L] <- TRUE
  nul <- which(bytes == 0)
  starts <- nul[-length(nul)] + 1L
  ends <- nul[-1] - 1L
  bad <- c(0L, cumsum(!ident[as.integer(bytes) + 1L]))
  keep <- ends > starts & ends - starts < 128L & bad[ends + 1L] == bad[starts]
  if (!any(keep))
    return(character())
  # Extract all strings at once, including the NUL that ends each of them
  chars <- bytes[sequence(ends[keep] - starts[keep] + 2L, from = starts[keep])]
  chars[chars == 0] <- as.raw(10)
  strsplit(rawToChar(chars), "\n", fixed = TRUE)[[1]]
}

# Header files without comments, string literals and preprocessor lines
read_headers <- function(path){
  files <- sort(list.files(file.path(path, "include"), recursive = TRUE, full.names = TRUE))
  vapply(files, function(file){
    clean_header(paste(readLines(file, warn = FALSE), collapse = "\n"))
  }, "", USE.NAMES = FALSE)
}

clean_header <- function(text){
  # Keep the name in R_GetCCallable("pkg", "name") as an identifier
  text <- gsub('R_GetCCallable\\s*\\(\\s*"[^"]*"\\s*,\\s*"([A-Za-z_]\\w*)"\\s*\\)',
               paste0("R_GetCCallable(", callsite_marker, "\\1)"), text, perl = TRUE, useBytes = TRUE)
  text <- gsub('(?s)/\\*.*?\\*/|//[^\n]*|"(?:\\\\.|[^"\\\\\n])*"|\'(?:\\\\.|[^\'\\\\\n])*\'',
               " ", text, perl = TRUE, useBytes = TRUE)
  text <- gsub("\\\\\n", " ", text, useBytes = TRUE)
  gsub("(?m)^[ \t]*#[^\n]*", "", text, perl = TRUE, useBytes = TRUE)
}

# Split a header into statements at file scope. The contents of namespace
# and extern "C" blocks are at file scope as well.
header_statements <- function(text){
  pos <- gregexpr("[{};]", text, useBytes = TRUE)[[1]]
  if (pos[1] < 0)
    return(character())
  chars <- substring(text, pos, pos)
  type_keyword <- "^[ \t\n]*(typedef|template|struct|union|enum|class)"
  out <- character()
  start <- 1L
  stack <- logical() # TRUE for blocks whose contents are at file scope
  for (i in seq_along(pos)) {
    p <- pos[i]
    depth <- sum(!stack)
    if (chars[i] == "{") {
      head <- substring(text, start, p - 1L)
      # Macro calls without ';' run into the next statement, e.g. in the
      # stubs of Bioconductor packages: restart at the last type keyword
      if (depth == 0 && !grepl(type_keyword, head, perl = TRUE)) {
        m <- regexpr("(?<![A-Za-z0-9_])(typedef|struct|union|enum|class)(?![A-Za-z0-9_])(?!.*(?<![A-Za-z0-9_])(typedef|struct|union|enum|class)(?![A-Za-z0-9_]))",
                     head, perl = TRUE)
        if (m > 1) {
          # Include a preceding typedef, as in 'typedef struct x {'
          before <- regexpr("(?<![A-Za-z0-9_])typedef\\s+$", substring(head, 1L, m - 1L), perl = TRUE)
          if (before > 0)
            m <- before
          start <- start + m - 1L
          head <- substring(text, start, p - 1L)
        }
      }
      transparent <- depth == 0 &&
        grepl("(^|[^A-Za-z0-9_])(namespace[ \t\n]*[A-Za-z0-9_:]*|extern)[ \t\n]*$", head, perl = TRUE)
      stack <- c(stack, transparent)
      if (transparent)
        start <- p + 1L
    } else if (chars[i] == "}") {
      if (!length(stack)) {
        start <- p + 1L
        next
      }
      transparent <- stack[length(stack)]
      stack <- stack[-length(stack)]
      if (transparent) {
        start <- p + 1L
      } else if (sum(!stack) == 0) {
        # A type definition continues until the ';' after its body
        statement <- substring(text, start, p)
        if (!grepl(type_keyword, statement, perl = TRUE)) {
          out <- c(out, statement)
          start <- p + 1L
        }
      }
    } else if (depth == 0) {
      out <- c(out, substring(text, start, p))
      start <- p + 1L
    }
  }
  out <- trimws(gsub("[ \t\n\r]+", " ", out, perl = TRUE, useBytes = TRUE))
  out[nzchar(out) & out != ";"]
}

# Statements that define a type, by name: typedefs, struct, union, enum and
# class definitions, and using aliases
type_definitions <- function(statements){
  defs <- list()
  add <- function(name, statement) defs[[name]] <<- c(defs[[name]], statement)
  for (statement in statements) {
    if (startsWith(statement, "typedef")) {
      # The name follows the body of a struct, or is the name of a function pointer
      tail <- sub(".*\\}", "", statement, perl = TRUE)
      fp <- regmatches(tail, regexec("\\(\\s*\\*\\s*([A-Za-z_]\\w*)\\s*\\)", tail, perl = TRUE))[[1]]
      add(if (length(fp)) fp[2] else sub(".*?([A-Za-z_]\\w*)\\s*(\\[[^]]*\\])?\\s*;$", "\\1", tail, perl = TRUE), statement)
      tag <- regmatches(statement, regexec("^typedef\\s+(?:struct|union|enum)\\s+([A-Za-z_]\\w*)", statement, perl = TRUE))[[1]]
      if (length(tag))
        add(tag[2], statement)
    } else if (grepl("^(template\\s*<.*?>\\s*)?(struct|union|enum|class)\\s+[A-Za-z_]\\w*[^;{]*\\{", statement, perl = TRUE)) {
      add(sub("^(template\\s*<.*?>\\s*)?(struct|union|enum|class)\\s+([A-Za-z_]\\w*).*", "\\3", statement, perl = TRUE), statement)
    } else if (grepl("^using\\s+[A-Za-z_]\\w*\\s*=", statement, perl = TRUE)) {
      add(sub("^using\\s+([A-Za-z_]\\w*).*", "\\1", statement, perl = TRUE), statement)
    }
  }
  defs
}

# Registered names may differ from the declared names, because stub macros
# add a prefix: "_name" (Bioconductor), "_pkg_name" (Rcpp interfaces). If no
# declaration is found, use the call site: the cast in
# 'fun = (int (*)(int)) R_GetCCallable("pkg", "name")' has the signature. As
# a last resort, accept a declaration with a single-word prefix: M_name
# (Matrix) or _p_name (rxode2ll).
callable_signature <- function(statements, defs, name, pkg, headers = character()){
  names <- unique(c(name, sub(paste0("^_", pkg, "_"), "", name), sub("^_", "", name)))
  for (n in names) {
    decls <- declarations(statements, defs, n)
    if (length(decls))
      return(with_types(decls, defs))
  }
  callsite <- callsite_clauses(headers, name)
  if (length(callsite))
    return(with_types(callsite, defs))
  for (n in names) {
    decls <- declarations(statements, defs, paste0(name_prefix, n))
    if (length(decls))
      return(with_types(decls, defs))
  }
  NULL
}

name_prefix <- "_?[A-Za-z0-9]+_"

# Functions, or variables with a function pointer type: 'extern fun_type name;'
# (PreciseSums). The name is a regular expression.
declarations <- function(statements, defs, name){
  pattern <- paste0("^(extern\\s+)?(const\\s+)?([A-Za-z_]\\w*)\\s+", name, "\\s*;$")
  vars <- statements[grepl(pattern, statements, perl = TRUE)]
  vars <- vars[sub(pattern, "\\3", vars, perl = TRUE) %in% names(defs)]
  sort(unique(c(function_declarations(statements, name), vars)))
}

callsite_marker <- "abitools_callable__"

# The clauses around R_GetCCallable("pkg", "name"), up to the nearest ';', '{'
# or '}'. A plain regex for this is quadratic on long code without those.
callsite_clauses <- function(headers, name, window = 2000L){
  token <- paste0(callsite_marker, name)
  out <- character()
  for (text in headers) {
    pos <- gregexpr(token, text, fixed = TRUE)[[1]]
    for (p in pos[pos > 0]) {
      end <- p + nchar(token)
      if (grepl("[A-Za-z0-9_]", substr(text, end, end)))
        next
      left <- substr(text, max(1L, p - window), p - 1L)
      cut <- regexpr("[;{}][^;{}]*$", left)
      right <- substr(text, p, p + window)
      stop <- regexpr("[;{}]", right)
      out <- c(out, paste0(if (cut > 0) substring(left, cut + 1L) else left,
                           if (stop > 0) substr(right, 1L, stop - 1L) else right))
    }
  }
  # Only the cast matters, e.g. (int (*)(int)) in 'if (!f) f = (int (*)(int)) R_GetCCallable(...)'
  pattern <- "(\\((?:[^()]++|(?1))*\\))(?=\\s*\\(?\\s*R_GetCCallable\\s*\\()"
  m <- regexpr(pattern, out, perl = TRUE)
  out[m > 0] <- regmatches(out, m)
  sort(unique(compact_code(out)))
}

# Whitespace does not matter, except between identifiers
compact_code <- function(x){
  x <- gsub("[ \t\n\r]+", " ", x, perl = TRUE)
  trimws(gsub(" ?([^A-Za-z0-9_ ]) ?", "\\1", x, perl = TRUE))
}

# Declarations of a function, as 'type name(...)' or as a function pointer
# 'type (*name)(...)' (libgeos). For definitions, the part before the body.
# The name must not be inside parentheses, but the return type may be a macro
# such as 'NLOPT_EXTERN(nlopt_result) name(...)' (nloptr).
function_declarations <- function(statements, name){
  heads <- sub("\\{.*", "", statements, perl = TRUE)
  heads <- heads[!startsWith(heads, "typedef")]
  m <- regexpr(paste0("(?<![A-Za-z0-9_])", name, "\\s*\\("), heads, perl = TRUE)
  before <- substring(heads, 1L, m - 1L)
  balanced <- nchar(gsub("[^(]", "", before)) == nchar(gsub("[^)]", "", before))
  plain <- m > 0 & balanced & !grepl("=", before, fixed = TRUE)
  pointer <- grepl(paste0("^[^=]*\\(\\s*\\*\\s*", name, "\\s*\\)\\s*\\("), heads, perl = TRUE)
  sort(unique(heads[plain | pointer]))
}

# The declarations plus the definitions of the types that they use, recursively
with_types <- function(decls, defs){
  decls <- strip_parameter_names(decls)
  seen <- character()
  types <- character()
  queue <- decls
  while (length(queue)) {
    words <- unique(unlist(regmatches(queue, gregexpr("[A-Za-z_]\\w*", queue, perl = TRUE))))
    new <- setdiff(intersect(words, names(defs)), seen)
    seen <- c(seen, new)
    queue <- strip_parameter_names(unique(unlist(defs[new])))
    types <- c(types, queue)
  }
  compact_code(c(decls, sort(unique(types))))
}

# Parameter names and default values do not affect the ABI, so only the types
# of the parameters are kept: 'int f(int x, double y = 1)' becomes
# 'int f(int, double)'. A parameter list is a group in parentheses after an
# identifier or after ')', as in 'f(...)', 'MACRO(type)' or '(*f)(...)'.
strip_parameter_names <- function(x){
  pattern <- "(?<=[A-Za-z0-9_)])\\s*\\(((?:[^()]++|\\((?1)\\))*)\\)"
  vapply(x, function(code){
    m <- gregexpr(pattern, code, perl = TRUE)
    if (m[[1]][1] < 0)
      return(code)
    regmatches(code, m) <- list(vapply(regmatches(code, m)[[1]], function(group){
      inner <- sub("^\\s*\\((.*)\\)$", "\\1", group, perl = TRUE)
      params <- split_parameters(strip_parameter_names(inner))
      paste0("(", paste(vapply(params, parameter_type, ""), collapse = ","), ")")
    }, ""))
    code
  }, "", USE.NAMES = FALSE)
}

# Split at commas that are not inside (), <> or []
split_parameters <- function(x){
  chars <- strsplit(x, "")[[1]]
  depth <- cumsum(chars %in% c("(", "<", "[")) - cumsum(chars %in% c(")", ">", "]"))
  cuts <- which(chars == "," & depth == 0)
  substring(x, c(1L, cuts + 1L), c(cuts - 1L, nchar(x)))
}

parameter_type <- function(param){
  param <- trimws(sub("=.*$", "", param, perl = TRUE))
  # Array dimensions follow the name: 'double x[10]'
  dims <- regmatches(param, regexpr("(\\s*\\[[^]]*\\])+$", param, perl = TRUE))
  core <- if (length(dims)) substring(param, 1L, nchar(param) - nchar(dims)) else param
  tokens <- regmatches(core, gregexpr("::|\\.\\.\\.|[A-Za-z_]\\w*|[^\\sA-Za-z_]", core, perl = TRUE))[[1]]
  n <- length(tokens)
  if (n >= 2 && is_parameter_name(tokens))
    tokens <- tokens[-n]
  paste0(paste(tokens, collapse = " "), if (length(dims)) dims else "")
}

# The last token is a name if it is an identifier that is not a builtin type,
# and does not follow a qualifier such as 'const', 'struct' or '::' (but in
# 'char *const p', the const qualifies the pointer and p is the name).
is_parameter_name <- function(tokens){
  n <- length(tokens)
  last <- tokens[n]
  prev <- tokens[n - 1]
  builtin <- c("int", "char", "short", "long", "float", "double", "void", "bool",
               "signed", "unsigned", "wchar_t", "auto")
  if (!grepl("^[A-Za-z_]\\w*$", last) || last %in% c(builtin, "const", "volatile"))
    return(FALSE)
  if (prev %in% c("const", "volatile"))
    return(n >= 3 && tokens[n - 2] %in% c("*", "&"))
  !prev %in% c("struct", "union", "enum", "class", "typename", "::")
}
