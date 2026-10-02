# AQL Proposal: Script Arguments (argv) and Environment Access

**Status:** Draft (an upstream implementation of the argv half is being
attempted on `aql-lang/aql` branch `claude/aql-file-viewer-tui-4mf69t`).
**Status update (2026-10-01, boru main @ `64c5ab2`): implemented
upstream.** AQL is now boru; `IO.args` landed in boru `16266c0a6`
(2026-07-21, with the CLI plumbing) and `IO.env` / `IO.env-all` in
`5a2dd554a` (2026-07-29). `boru aless.aql notes.json` opens the file.
**Target:** `aql-lang/aql` CLI (`cmd/go`) + `aql:io` module.
**Provenance:** surfaced while building the `aless`
TUI file viewer; recorded as **§5** of of
[`dx-report.md`](../dx-report.md).
**Build referenced:** `aql @ c1d2a1a` (main, 2026-07-20).

## 1. Problem

An AQL script cannot find out how it was invoked:

```bash
aql aless.aql notes.json          # notes.json is silently ignored
```

The CLI's run path consumes only the script path (`fs.Arg(0)`); extra
positionals vanish without a diagnostic. There is also no word exposing
environment variables. Together this means a command-line *tool*
written in AQL — exactly what `aql:tui` now invites — has no channel to
receive a file name, a flag, or `$HOME` from its caller. The `aless`
viewer ships with this launch story instead:

```bash
aql -e 'import "./aless-app.aql"  Aless.run {files: ["notes.json"]}'
```

which works but is nobody's idea of a CLI. (The `args` word is
unrelated: it returns the current *fn call's* arguments.)

## 2. Proposal

1. **`IO.args → List`** — the script's positional arguments (everything
   after the script path), as Strings. Empty list under the REPL, `-e`,
   and embedded hosts that set none. The CLI forwards
   `fs.Args()[1:]` through the run configuration; hosts get a setter on
   the build config (mirroring how the tui backend is injected).
2. **`IO.env <name> → String|None`** and **`IO.env → Map`** — read one
   or all environment variables. Gated behind the same capability
   surface as the rest of `aql:io` so hermetic/embedded registries can
   deny or fake it (the in-memory FileOps precedent).
3. At minimum, the CLI should **warn** when positionals beyond the
   script are dropped, so today's silent-ignore becomes visible.

## 3. Non-goals

Flag parsing, `--`-conventions, and argument typing stay in user code —
a `List` of raw strings is enough; `aql:string-util` covers the rest.

## 4. Compatibility

Purely additive. No existing program can observe `IO.args` today; the
only behavioural change is the (new) warning for dropped positionals.
