#!/bin/bash
# SessionStart hook: ensure the `boru` CLI is available so the agent can run
# aless and its tests. aless tracks boru MAIN (the boru:tui stack it needs
# postdates any tagged build), so this builds boru from the latest main.
# (The language and its CLI were called `aql` until upstream's 2026-07-31
# rename; the binary is now `boru`, built from cmd/go → ./boru.)
#
# Synchronous and idempotent: skips the build if a binary already exists, and
# caches it into the container so later sessions are instant. Progress goes to
# stderr; stdout is left clean (SessionStart stdout is injected as context).
set -uo pipefail

# Web sessions are the target; locally a developer already has boru. No-op
# elsewhere. (Remove this guard to build everywhere.)
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log() { echo "[session-start] $*" >&2; }

BIN_DIR="$HOME/.local/bin"
BORU="$BIN_DIR/boru"

# Persist PATH for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$BIN_DIR:$PATH"

if [ -x "$BORU" ] || command -v boru >/dev/null 2>&1; then
  [ -x "$BORU" ] || BORU="$(command -v boru)"
  log "boru already present ($("$BORU" -version 2>/dev/null)); skipping build."
else
  if ! command -v go >/dev/null 2>&1; then
    log "WARNING: Go toolchain not found; cannot build boru. Install Go, then build boru from a boru-lang/boru checkout: cd cmd/go && go build -o \"$BORU\" ./boru"
    exit 0
  fi
  log "Building boru from boru-lang/boru main (one-time; cached afterwards)…"
  mkdir -p "$BIN_DIR"
  src="$(mktemp -d)"
  ref=""
  # The codeload tarball works where a raw `git clone` of boru-lang/boru is
  # egress-blocked behind the agent proxy; fall back to git clone otherwise.
  if curl -fsSL "https://codeload.github.com/boru-lang/boru/tar.gz/refs/heads/main" \
       | tar -xz -C "$src" --strip-components=1 2>/dev/null; then
    ref="main"
  else
    rm -rf "$src"; src="$(mktemp -d)"
    if git clone --quiet --depth 1 https://github.com/boru-lang/boru "$src"; then
      ref="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo main)"
    fi
  fi
  if [ -n "$ref" ]; then
    # GOWORK=off: the boru repo ships a go.work, so disable workspace mode;
    # GOFLAGS=-mod=mod then builds the standalone source tree.
    ( cd "$src/cmd/go" \
      && GOWORK=off GOFLAGS=-mod=mod go build \
           -ldflags "-X github.com/boru-lang/boru/cmd/go.Version=${ref}" \
           -o "$BORU" ./boru ) \
      && log "Built $("$BORU" -version 2>/dev/null)." \
      || log "WARNING: boru build failed; build manually from a boru checkout (cd cmd/go && go build -o \"$BORU\" ./boru)."
  else
    log "WARNING: could not fetch boru source (network?); build manually from a boru checkout."
  fi
  rm -rf "$src"
fi

# Fast confidence check: run the smoke suite if boru is usable. Never fail the
# session on a check error. Run from the repo root: the fixtures the suite
# reads (test/fixtures/…) resolve against the working directory.
if [ -x "$BORU" ] && [ -f "$CLAUDE_PROJECT_DIR/test/aless_smoke_test.aql" ]; then
  if ( cd "$CLAUDE_PROJECT_DIR" && "$BORU" test/aless_smoke_test.aql >/dev/null 2>&1 ); then
    log "Smoke check passed (boru test/aless_smoke_test.aql)."
  else
    log "NOTE: smoke check did not pass; the boru toolchain may be incomplete or main may have regressed."
  fi
fi

exit 0
