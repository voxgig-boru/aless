# test/divergence — the aless test gate

`run.sh` is the single gate CI runs (`.github/workflows/test.yml`) and the
one to run locally before committing:

```bash
test/divergence/run.sh                               # builds its own boru at main HEAD
BORU=$HOME/.local/bin/boru test/divergence/run.sh    # reuse an existing binary
BORU_REF=<sha> test/divergence/run.sh                # pin a specific boru commit
```

## What it gates

| Surface | Command | Must |
|---------|---------|------|
| run | `boru test/<suite>.aql` | exit 0 **and** print `all green` (every aless suite prints it; the smoke suite has no assertions, so a clean run is its pass) |
| check | `boru check <file>` | report **0 errors**, on every suite **and** every module (`aless.aql` launcher included) |

The suites are an explicit list (`SUITES` in `run.sh`); a
`test/aless_*_test.aql` file missing from it fails the gate, so a new
suite cannot go ungated by accident.

The launcher is check-only: running it starts the TUI, which needs a
terminal — see the PTY smoke in the top-level `README.md`. The gate
cannot see the live `Tui.run` path, which compiles its callbacks lazily
and apart from the suites' whole-program compile (a defect only that
path hits once crashed the viewer with every suite green —
`dx-report.md`, "Migration to boru main @ 64c5ab2", item D), so
PTY-smoke any change to the app map or the update path.

Everything runs **from the repo root**: suites import the modules
file-relatively (`import "../aless-doc.aql"`), but the fixtures they read
through `IO.read` / `IO.write` (`test/fixtures/…`) resolve against the
working directory.

## When a suite fails to compile but checks clean

A `[boru/compile_failed]` on a suite whose `boru check` is clean —
`unmatched dispatch recovered at def`, `code-body word test-test (Stage
2)` or another reason that names no real problem in the code — is most
likely the compile pass's fixed 500,000-step analysis budget running out
(an open upstream defect: the truncation is reported as whichever
compile check trips first over the truncated analysis, not as
`step_budget_exceeded`). The headless app tests are split into three
suites for this reason — see `dx-report.md`, "Migration to boru main @
64c5ab2", item A. Move scenarios to a suite with headroom rather than
growing one past the budget.

## Why there is no interpreter-vs-bytecode column any more

Until boru main 2026-09-19 a program ran on the interpreter by default and
the old CI loop compared `aql X` against `aql --force-compile X` (bytecode
parity). boru now has **one execution path**: `boru X` runs a static
pre-flight check, compiles to bytecode and runs on the VM — or fails with
`[boru/compile_failed] … this is a compiler defect`. There is no
interpreter fallback, and `--compile` / `--force-compile` / `--no-compile`
(and the `BORU_COMPILE` / `BORU_FORCE_COMPILE` / `BORU_NO_COMPILE` env
vars) are retired — passing one is a usage error. "The suite runs" now
*means* "the suite fully compiles", so the parity column has nothing left
to compare. The harness never passes `-no-check`.

## Building boru

Without `BORU=…` the script resolves boru-lang/boru `main` HEAD
(`git ls-remote`, GitHub API fallback), fetches that commit as a codeload
tarball (`git clone` fallback), builds `cmd/go` → `./boru` with
`GOWORK=off GOFLAGS=-mod=mod`, and caches the binary by SHA under
`~/.cache/aless-divergence/`. It needs `go`, `curl` or `git`, and network
for the one-time build.
