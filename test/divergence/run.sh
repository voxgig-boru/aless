#!/usr/bin/env bash
# The aless test gate: run every suite, and statically check every module
# and suite, through the two boru surfaces that exist on boru main — and
# fail on any error:
#
#   run     boru X          compile to bytecode and run on the VM — the ONLY
#                           execution path (see below); must exit 0, and an
#                           assertion-bearing suite must print `all green`
#   check   boru check X    static type-check; must report 0 errors
#
# Single-path model. Since boru main 2026-09-19 a program compiles to
# bytecode and runs on the VM, or it fails with `[boru/compile_failed] …
# this is a compiler defect`. There is no interpreter fallback any more, and
# the flags the old CI loop compared (`aql X` vs `aql --force-compile X`;
# also `--compile` / `--no-compile` and the BORU_COMPILE /
# BORU_FORCE_COMPILE / BORU_NO_COMPILE env vars) are RETIRED — passing one
# is a usage error. The interpreter-vs-bytecode parity column therefore has
# nothing left to compare: "the suite runs" now *means* "the suite fully
# compiles". What remains to gate is that every suite runs green compiled
# and every file checks clean.
#
# `boru X` also runs the static pre-flight check by default (a check error
# blocks the run); this harness never passes `-no-check`.
#
# Paths: suites import the modules file-relatively (`../aless-doc.aql`), but
# the fixtures they read through IO words (`test/fixtures/…`) resolve
# against the WORKING DIRECTORY, so everything runs from the repo root.
#
# The launcher `aless.aql` is check-only here: running it starts the TUI,
# which needs a terminal (see the PTY smoke in README.md).
#
# The harness builds its OWN boru at boru-lang/boru main HEAD (resolved at
# run time, cached by SHA under ~/.cache/aless-divergence), so it never
# depends on whatever boru is on PATH. The source is fetched as a codeload
# tarball (curl) with a `git clone` fallback, so it builds even where one of
# the two is blocked; needs `go` + network for the one-time build.
# Overrides:
#
#   BORU=/path/to/boru      use an existing binary; skip the fetch + build
#   BORU_REF=<sha>          build this boru commit instead of main HEAD
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

MODULES="
aless.aql
aless-app.aql
aless-fmt.aql
aless-doc.aql
aless-nav.aql
aless-tabs.aql
aless-view.aql
"

SUITES="
test/aless_fmt_unit_test.aql
test/aless_doc_unit_test.aql
test/aless_doc_prop_test.aql
test/aless_nav_unit_test.aql
test/aless_tabs_unit_test.aql
test/aless_app_unit_test.aql
test/aless_smoke_test.aql
"

log() { echo "[divergence] $*"; }

# --- locate or build boru -------------------------------------------------
if [ -n "${BORU:-}" ]; then
  [ -x "$BORU" ] || { echo "error: BORU=$BORU is not an executable." >&2; exit 1; }
else
  BORU_REF="${BORU_REF:-$(git ls-remote https://github.com/boru-lang/boru.git main 2>/dev/null | cut -f1)}"
  [ -n "$BORU_REF" ] || BORU_REF="$(curl -fsSL https://api.github.com/repos/boru-lang/boru/commits/main 2>/dev/null \
                                      | grep -m1 '"sha"' | grep -oE '[0-9a-f]{40}')"
  [ -n "$BORU_REF" ] || { echo "error: could not resolve boru main HEAD (network?); set BORU=/path/to/boru." >&2; exit 1; }
  CACHE="$HOME/.cache/aless-divergence"
  BORU="$CACHE/boru-$BORU_REF"
  if [ ! -x "$BORU" ]; then
    command -v go >/dev/null 2>&1 || { echo "error: Go toolchain not found." >&2; exit 1; }
    log "building boru @ $BORU_REF (one-time; cached) …"
    src="$(mktemp -d)"
    if ! curl -fsSL "https://codeload.github.com/boru-lang/boru/tar.gz/$BORU_REF" \
         | tar -xz -C "$src" --strip-components=1 2>/dev/null; then
      log "codeload fetch failed; falling back to git clone …"
      rm -rf "$src"; src="$(mktemp -d)"
      { git clone --quiet https://github.com/boru-lang/boru "$src" \
          && git -C "$src" checkout --quiet "$BORU_REF"; } \
        || { echo "error: could not fetch boru source (network?); set BORU=/path/to/boru." >&2; exit 1; }
    fi
    mkdir -p "$CACHE"
    # The CLI's main package is cmd/go/boru (the binary is `boru`, not `aql`).
    # GOWORK=off: the boru repo ships a go.work; GOFLAGS=-mod=mod then builds
    # the standalone source tree.
    ( cd "$src/cmd/go" && GOWORK=off GOFLAGS=-mod=mod go build \
        -ldflags "-X github.com/boru-lang/boru/cmd/go.Version=$BORU_REF" \
        -o "$BORU" ./boru ) || { echo "error: build failed." >&2; rm -rf "$src"; exit 1; }
    rm -rf "$src"
  fi
fi
log "boru: $("$BORU" -version)"
echo

cd "$REPO"
fail=0

# check_errors FILE -> prints the error count from `boru check` (or `?`).
check_errors() {
  local n
  n="$("$BORU" check "$1" 2>&1 | grep -oE '[0-9]+ error\(s\)' | grep -oE '[0-9]+' | tail -1)"
  echo "${n:-?}"
}

# --- modules: check only ----------------------------------------------------
log "modules — boru check must report 0 errors:"
printf '  %-28s  %s\n' MODULE CHECK
for m in $MODULES; do
  errs="$(check_errors "$m")"
  if [ "$errs" = 0 ]; then c_col="ok"; else c_col="FAIL($errs err)"; fail=1; fi
  printf '  %-28s  %s\n' "$m" "$c_col"
done
echo

# --- suites: run (compiled) + check -----------------------------------------
log "suites — boru X must exit 0 (and print \`all green\` where asserted); boru check X must report 0 errors:"
printf '  %-28s  %-22s  %-12s  %s\n' SUITE RUN CHECK SECS
for s in $SUITES; do
  name="$(basename "$s")"

  t0=$(date +%s)
  out="$("$BORU" "$s" 2>&1)"; rc=$?
  secs=$(( $(date +%s) - t0 ))
  if [ $rc -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q 'compile_failed'; then r_col="COMPILE_FAILED"; else r_col="FAIL(exit $rc)"; fi
    fail=1
  elif ! printf '%s\n' "$out" | grep -qx 'all green'; then
    # every aless suite (the assertion-free smoke included) ends by
    # printing `all green`
    r_col="FAIL(no all green)"; fail=1
  else
    r_col="ok"
  fi

  errs="$(check_errors "$s")"
  if [ "$errs" = 0 ]; then c_col="ok"; else c_col="FAIL($errs err)"; fail=1; fi

  printf '  %-28s  %-22s  %-12s  %s\n' "$name" "$r_col" "$c_col" "$secs"
  if [ "$r_col" != ok ]; then
    printf '%s\n' "$out" | grep -E 'error|FAIL|compile_failed' | head -5 | sed 's/^/      /'
  fi
done

echo
if [ "$fail" = 0 ]; then
  log "PASS — every suite runs green compiled and every file checks with 0 errors."
else
  log "FAIL — a suite failed to compile/run, or a file has check errors."
fi
exit $fail
