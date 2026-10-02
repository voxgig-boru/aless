# aless — a boru file viewer

A full-screen terminal viewer for every file format
[boru](https://github.com/boru-lang/boru) (formerly AQL) can parse,
written **in boru** on the `boru:tui` stack, modeled on
[jless](https://jless.io)'s interface — extended with **tabs** for
multiple open files and a **watch** mode that reloads changed files
while keeping your place. (Source files keep the historical `.aql`
extension.)

```bash
boru aless.aql                 # welcome tab; open files with :open
boru aless.aql notes.json      # open a file straight away
```

Verified against `boru-lang/boru` **main @ `64c5ab2`** (2026-10-01).
aless tracks boru **main**, unpinned — the `boru:tui` stack it rides on
landed upstream on 2026-07-17, and the app follows it forward. A "last
verified" commit is recorded here instead of a pin; CI builds boru from
main on every run.

## Install boru

There is no tagged release; build the CLI from a boru-lang/boru
checkout (it needs Go):

```bash
cd <boru-checkout>/cmd/go && go build -o ~/.local/bin/boru ./boru
```

The checkout carries a `go.work`, so build it as-is (`GOFLAGS=-mod=mod`
fails in workspace mode). For an extracted source tarball without the
workspace, use `GOWORK=off GOFLAGS=-mod=mod go build -o ~/.local/bin/boru
./boru`.

## Launch

```bash
boru aless.aql                       # welcome tab; open files with :open
boru aless.aql notes.json data.csv   # one tab per file (IO.args)
boru path/to/aless/aless.aql x.json  # from any directory
```

The launcher's own imports resolve against its directory, so it runs
from anywhere; file arguments (and `:open` paths) resolve against the
**working directory**, like any CLI. The library entry point works from
a one-liner too (run it from the repo root so `./aless-app.aql`
resolves):

```bash
boru -e 'import "./aless-app.aql"  Aless.run {files: ["test/fixtures/sample.json"]}'
boru -e 'import "./aless-app.aql"  Aless.run {files: ["a.json", "b.csv"], watch: false}'
```

The first frame appears once boru has compiled the app (a few seconds
to tens of seconds — every boru program is compiled to bytecode before
it runs). Remote viewing works for free, because the same app map
serves both runtimes: `Aless.serve {tcp: 9700, token: "s3cret"} …` then
`boru attach`.

## Formats

Parsing is boru's own `IO.read`, which infers the format from the file
extension: `json jsonic json5 jsonc csv tsv toml yaml xml ini/cfg/conf
zon md/markdown rss/atom`. Anything else (or `:open <path> text`) is
shown as plain-text lines, so every file is viewable. CSV/TSV render as
a list of header-keyed records. An explicit kind overrides the
extension: `:open data.log json`.

## Keys

| Keys | Action |
|------|--------|
| `j` `k` / arrows | move focus down / up |
| `l` / right | expand a container, or step to its first child |
| `h` / left | collapse an open container, or go to the parent |
| `H` | go to the parent without collapsing |
| `J` `K` | next / previous sibling |
| `w` `b` | next / previous change of depth |
| `space` | toggle fold |
| `c` | collapse (from a leaf: collapse at the parent) |
| `e` / `E` | expand / deep-expand the focused subtree (row-capped) |
| `g` `G` | first / last row |
| `0` `^` / `$` | first / last sibling |
| `C-f` `C-b` / `pgdn` `pgup` | page down / up |
| `C-d` `C-u` | half page down / up |
| `C-e` `C-y` | scroll without moving focus |
| `z` then `z`/`t`/`b` | focused row to center / top / bottom |
| `.` `,` | scroll long values right / left |
| `/text` | search keys and values (smart case), `n` / `N` cycle |
| `*` | search for the focused key |
| `y` | print focused path + value to the status line |
| `tab` / `backtab` | next / previous tab |
| `W` | toggle watch on the active tab |
| `r` | reload the active tab now |
| `?` | help overlay (any key returns) |
| `q` | close the tab (last tab closed quits) |
| `C-c` / `C-\` | quit (boru:tui built-ins) |

Commands (`:`): `:open <path> [kind]` · `:close` · `:tab <n>` ·
`:next` · `:prev` · `:watch on|off` · `:help` · `:quit`.

## Watch

Watching is ON by default for every opened tab (`Aless.run {watch:
false}`, `:watch off`, or `W` to opt out; the status bar shows
`watching`). A spawned metronome process ticks the app once a second;
each watched tab's mtime+size stamp is compared and, on change, the
file is reloaded and the view **re-anchored**:

1. the focused row's path is the anchor; its screen line is noted;
2. expansions whose paths survive in the new document are kept;
3. if the anchor's node was deleted, focus falls to its nearest
   surviving ancestor;
4. rows are rebuilt and scrolled so the anchor sits on the same screen
   line.

A reload that fails to parse keeps the old view and shows the error; a
deleted file keeps its buffer and marks the tab `✗` (gone) — and comes
back when the file does. Edits within the same second that also keep
the byte size identical are invisible to the stamp (accepted
limitation). Polling is used instead of fsnotify because `IO.watch`
callbacks are never delivered while `Tui.run` owns the runtime — see
dx-report §2.

## Deviations from jless (v1)

- Strings render boru-style (`'single-quoted'`, via `canon`), not JSON
  double-quoted.
- No line mode (`m`/`%`), no clipboard yank (boru has no subprocess or
  clipboard access — `y` prints to the status line instead), no digit
  counts, no regex search (literal smart-case; `boru:minilang`'s `re` is
  the upgrade path), no `<`/`>` indent control, no mouse.
- XML files parse to an element node and currently display as a single
  leaf.

Map keys display in **source order**, as jless does: boru maps keep
insertion order and `IO.read` preserves a file's key order (they were
sorted on the AQL builds aless started on — dx-report §8).

## Architecture

```
aless.aql        entry launcher: reads IO.args, runs Aless.run
aless-app.aql    shell: Tui.run app map, mode routing, watch metronome
aless-view.aql   pure widget builders (tab strip, tree pane, bars, help)
aless-nav.aql    pure jless keymap fold over a tab's view state
aless-tabs.aql   pure tab set + reload re-anchor + reveal
aless-doc.aql    pure document → row model (splices, search, display)
aless-fmt.aql    format detection + IO.read loading
```

Everything except `aless-app.aql` is terminal-free and unit-tested
(`test/aless_*`). The shell itself is exercised headlessly through
`Aless.feed`, which folds synthetic events through the real update loop —
including the watch pipeline against real on-disk writes
(`test/aless_app*_unit_test.aql`). Rendering and raw key decoding are
covered by a manual PTY smoke:

```bash
(sleep 30; printf 'jl'; sleep 2; printf 'qq') \
  | script -qec "stty cols 130 rows 32; boru aless.aql test/fixtures/sample.json" /dev/null
```

(a real terminal is nicer; the sleep covers boru's compile before the
first frame). The boru-runtime pitfalls this codebase had to design
around — and the idioms that dodge them — are catalogued in
[`dx-report.md`](dx-report.md), with upstream RFCs in
[`proposals/`](proposals/).

## Tests & CI

Nine suites under `test/`. Run them **from the repo root** — the suites
import the modules file-relatively (`../aless-doc.aql`), but the fixtures
they read and write through IO words (`test/fixtures/…`) resolve against
the working directory:

```bash
boru test/aless_fmt_unit_test.aql         # format detection + load
boru test/aless_doc_unit_test.aql         # document → row model
boru test/aless_doc_prop_test.aql         # property-based row-model invariants
boru test/aless_nav_unit_test.aql         # the jless keymap fold
boru test/aless_tabs_unit_test.aql        # tab set + reload re-anchor
boru test/aless_app_unit_test.aql         # headless app: boot, commands, quit, help, render
boru test/aless_app_browse_unit_test.aql  # headless app: navigation, tabs, search, yank
boru test/aless_app_watch_unit_test.aql   # headless app: the watch-reload pipeline
boru test/aless_smoke_test.aql            # every fixture format loads
```

Each assertion suite ends by asserting `Test.fail-count` is `0` and
printing `all green`. boru has **one execution path** — `boru X` checks,
compiles to bytecode and runs on the VM, or fails with `compile_failed`
(the old interpreter and its `--force-compile`/`--no-compile` flags are
gone) — so every suite passing means every suite fully compiles. The
headless app tests are split three ways, and feed key sequences through
one fold, to stay under the compile pass's fixed analysis budget
(dx-report, "Migration to boru main").

The gate is [`test/divergence/run.sh`](test/divergence/run.sh): every
module and suite `boru check`s with 0 errors, and every suite runs green.

```bash
BORU=$(command -v boru) test/divergence/run.sh   # reuse your boru
test/divergence/run.sh                          # build boru @ main HEAD first
```

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) builds
boru from **main** on every push and pull request (and nightly) and runs
that gate. Because it tracks main rather than a pin, an upstream
regression can break CI independently of any change here — the accepted
trade-off for riding the latest `boru:tui`.

## License

See [LICENSE](LICENSE).
