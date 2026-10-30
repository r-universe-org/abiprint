# Summarize the results of the survey as markdown, and fail if there were
# errors, crashes, timeouts, or false positives
lines <- readLines(commandArgs(TRUE)[1])
results <- lapply(lines[nzchar(trimws(lines))], jsonlite::fromJSON, simplifyVector = FALSE)
get <- function(field, default = NA) vapply(results, function(r) r[[field]] %||% default, FUN.VALUE = default)
num <- function(r, ...) { x <- r[[...]]; if (is.null(x)) 0L else as.integer(x) }

pkg <- get("package", "")
status <- get("status", "")
seconds <- get("seconds", 0)
ok <- status == "ok"
out <- character()
say <- function(...) out <<- c(out, sprintf(...))
table_md <- function(df){
  c(paste("|", paste(names(df), collapse = " | "), "|"),
    paste("|", paste(rep("---", ncol(df)), collapse = " | "), "|"),
    apply(df, 1, function(row) paste("|", paste(row, collapse = " | "), "|")))
}

say("## abitools survey")
say("")
say("Inspected %d packages: %d ok, %d errors, %d crashed or timed out.", length(results),
    sum(ok), sum(status == "error"), sum(!status %in% c("ok", "error")))

failed <- which(!ok)
if (length(failed)) {
  say("")
  say("### Failures")
  say("")
  out <- c(out, table_md(data.frame(package = pkg[failed], status = status[failed],
    error = vapply(results[failed], function(r) gsub("[|\n]", " ", substr(r$error %||% "", 1, 200)), ""))))
}

# False positives: in a consistent library, imports must match the exports
check <- Filter(function(r) length(r$check) || num(r, "stale_classes") > 0, results[ok])
if (length(check)) {
  say("")
  say("### False positives")
  say("")
  out <- c(out, table_md(data.frame(package = vapply(check, `[[`, "", "package"),
    abi_check = vapply(check, function(r) paste(unlist(r$check), collapse = "; "), ""),
    stale_classes = vapply(check, num, 0L, "stale_classes"))))
}

# Registered C functions without a signature (these are not exported)
providers <- Filter(function(r) num(r, "registered") > 0, results[ok])
if (length(providers)) {
  say("")
  say("### C functions")
  say("")
  reg <- vapply(providers, num, 0L, "registered")
  sig <- vapply(providers, num, 0L, "with_signature")
  say("%d packages register %d C functions, of which %d (%.1f%%) have a signature.",
      length(providers), sum(reg), sum(sig), 100 * sum(sig) / sum(reg))
  i <- which(sig < reg)
  if (length(i)) {
    say("")
    out <- c(out, table_md(data.frame(package = vapply(providers[i], `[[`, "", "package"),
      registered = reg[i], without_signature = reg[i] - sig[i],
      examples = vapply(providers[i], function(r) paste(head(unlist(r$without_signature), 4), collapse = ", "), ""))))
  }
}

# Possible calls to C functions of packages that are not in LinkingTo
undeclared <- Filter(function(r) length(r$undeclared_c_api), results[ok])
if (length(undeclared)) {
  say("")
  say("### Possible C API use without LinkingTo")
  say("")
  say("The binary calls `R_GetCCallable()` and contains the name of a package that registers C functions, but does not link to it. Such imports are not detected.")
  say("")
  out <- c(out, table_md(data.frame(package = vapply(undeclared, `[[`, "", "package"),
    packages = vapply(undeclared, function(r) paste(unlist(r$undeclared_c_api), collapse = ", "), ""))))
}

# Warnings while inspecting
warned <- Filter(function(r) length(r$warnings), results)
if (length(warned)) {
  say("")
  say("### Warnings")
  say("")
  out <- c(out, table_md(data.frame(package = vapply(warned, `[[`, "", "package"),
    warnings = vapply(warned, function(r) gsub("[|\n]", " ", substr(paste(unlist(r$warnings), collapse = "; "), 1, 200)), ""))))
}

say("")
say("### Largest and slowest")
say("")
imports <- vapply(results, function(r) sum(unlist(r$imports)), 0)
json <- vapply(results, function(r) as.numeric(r$json_bytes %||% 0), 0)
top <- head(order(-seconds), 10)
out <- c(out, table_md(data.frame(package = pkg[top], seconds = seconds[top],
  imports = imports[top], json_kb = round(json[top] / 1000, 1))))
say("")
say("Median %.1f seconds; most imports: %s (%d); largest JSON: %s (%.1f KB).", median(seconds),
    pkg[which.max(imports)], max(imports), pkg[which.max(json)], max(json) / 1000)

summary <- Sys.getenv("GITHUB_STEP_SUMMARY")
if (nzchar(summary)) cat(out, file = summary, sep = "\n", append = TRUE) else cat(out, sep = "\n")
if (length(failed) || length(check))
  stop("The survey found failures or false positives, see the summary")
