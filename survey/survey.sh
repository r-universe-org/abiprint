#!/bin/sh
# Inspect all packages in the file $1 in parallel, each in its own process with
# a time limit, and write the results as JSON lines to $2
: > "$2"
xargs -P "$(nproc)" -I {} sh -c '
  out=$(timeout 900 Rscript survey/inspect.R {} 2>/dev/null | tail -1)
  case "$out" in
    "{"*) echo "$out" ;;
    *) echo "{\"package\":\"{}\",\"status\":\"crashed or timed out\"}" ;;
  esac' < "$1" >> "$2"
