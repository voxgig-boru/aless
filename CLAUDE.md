# CLAUDE.md

This repository is **`aless`** — a jless-style TUI file viewer for every
format boru can parse (tabs; watch-reload), written **in boru** (the
language formerly called AQL; source files keep the `.aql` extension) on
the `boru:tui` stack. Start with **[README.md](README.md)**: what it is,
how to launch it, the full keymap, the watch semantics, and the module
map.

## Working on this repository

- **Build boru from main.** aless tracks boru **main**, unpinned (last
  verified against boru main @ `64c5ab2`, 2026-10-01). The CLI binary is
  `boru`; build it from a boru-lang/boru source checkout:
  ```bash
  cd <boru-checkout>/cmd/go && go build -o ~/.local/bin/boru ./boru
  ```
  Inside a boru checkout that is all you need (the checkout carries a
  `go.work`, and `GOFLAGS=-mod=mod` *fails* there — "-mod may only be set
  to readonly or vendor when in workspace mode"). For a standalone build
  of an extracted tarball, use `GOWORK=off GOFLAGS=-mod=mod go build …`
  (what CI, the SessionStart hook and the gate do). A SessionStart hook
  (`.claude/hooks/session-start.sh`) builds boru from main in remote
  sessions so a fresh session can run the suites.
- **One execution path.** `boru X` runs a static pre-flight check, then
  compiles the program to bytecode and runs it on the VM — or fails with
  `[boru/compile_failed] … this is a compiler defect`. There is no
  interpreter fallback, and `--compile` / `--force-compile` /
  `--no-compile` are retired (usage errors). "A suite runs" therefore
  means "a suite fully compiles". Never use `-no-check` to get green.
- **Modules live at the repo root** (no subfolders): `aless.aql` is the
  entry launcher; `aless-app.aql` is the `Tui.run` shell (the only module
  that touches the terminal); `aless-{view,nav,tabs,doc,fmt}.aql` are the
  pure, terminal-free core.
- **Two path anchors.** `import "./x.aql"` resolves against the
  **importing file's own directory** (for `boru X` and `boru check X`
  alike), so the suites in `test/` import `"../aless-doc.aql"` and the
  launcher can be started from anywhere. **Data paths** read or written
  through IO words (`IO.read`, `IO.write`, `IO.stat` — the fixtures
  `test/fixtures/…`, a file passed to `:open`) resolve against the
  **process working directory**, so run the suites from the repo root.
- **Tests live in `test/`**, named `aless_<subject>_<unit|prop>_test.aql`
  plus `aless_smoke_test.aql`. Each assertion-bearing suite ends with
  `Assert.equal 0 (Test.fail-count)` and prints `all green` (write one
  `print (value)` per statement — postfix `print` chains reorder). The
  pure modules are unit/property tested directly; the shell is driven
  headlessly through the exported `Aless.feed` fold (the
  `test/aless_app*_unit_test.aql` suites) — there is no boru-reachable
  virtual terminal, so rendering and raw key decoding are covered only by
  the manual PTY smoke in the README.
- **Keep each suite under the compile pass's analysis budget.** The
  compile pass executes a program's top level under check-mode analysis
  with a fixed 500,000-step budget; a suite that drives the whole update
  loop many times exceeds it and fails with a misleading
  `[boru/compile_failed] … unmatched dispatch recovered at def`
  (dx-report "Migration to boru main"). That is why the headless app
  tests are three files and feed key sequences through one fold
  (`_keys`, `_line`). Put new app scenarios in the file with headroom, or
  a new one.
- **Before committing**, from the repo root, run the gate:
  ```bash
  BORU=$(command -v boru) test/divergence/run.sh
  ```
  It checks every module (launcher included) and every suite with
  `boru check` (0 errors) and runs every suite with `boru X` (exit 0 and
  `all green`). Without `BORU=…` it builds its own boru at main HEAD. CI
  (`.github/workflows/test.yml`) builds boru from main and runs the same
  script.
- **Known boru-runtime gotchas** observed while building aless — and the
  idioms that dodge them — are in [`dx-report.md`](dx-report.md). Read it
  before changing the state machinery. What still shapes the code is in
  its "Migration to boru main" section: the compile pass's analysis
  budget (item A — why the app tests are split), and the live-TUI
  callback defect (item D — `Aless.app` hands `Tui.run` *lambdas* over
  `aless-update` / `aless-render`; handing it `aless-update/v` directly
  crashes the live viewer, which no suite can see, so PTY-smoke any
  change to the app map). §1–§4 are fixed or no longer reproduce on main;
  their workarounds (folds, `is`-chains, def-then-return, the metronome
  poll) stay because they are harmless.
- **Upstream proposals** raised from this work live in
  [`proposals/`](proposals/) (RFCs against boru, not changes to aless);
  each carries a dated status line.
