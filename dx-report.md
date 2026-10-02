# Developer-experience report: `aless` on AQL

> **Now verified against boru main @ `64c5ab2` (2026-10-01)** — see
> [Migration to boru main @ 64c5ab2](#migration-to-boru-main--64c5ab2-2026-10-01).
> Everything below that section is the original report, with dated
> status lines.

**AQL build under test:** `aql-lang/aql` @ `c1d2a1a` (main, 2026-07-20),
built from source in-workspace (`cd cmd/go && go build ./aql`; note
`GOFLAGS=-mod=mod` now *fails* inside the aql workspace — "-mod may only
be set to readonly or vendor when in workspace mode" — the flag is only
for standalone clones).

**Context:** `aless` is a jless-style TUI file viewer with tabs and
watch-reload, written in AQL on the freshly-landed `aql:tui` stack
(upstream 2026-07-17). It is the first real-world exercise of `aql:tui`,
`aql:io` watching, the actor words, and deep cross-module call chains.
Everything below was hit while making the viewer work; each verdict was
isolated with a minimal repro where one exists. The five module suites
plus the headless app-integration suite and the fixtures smoke are green
on this build.

Severity: **🔴 high** (silent wrong results / crash / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Migration to boru main @ 64c5ab2 (2026-10-01)

aless moved from `aql-lang/aql` @ `c1d2a1a` (2026-07-20) to
`boru-lang/boru` **main @ `64c5ab2`** (2026-09-30) — the language was
renamed AQL → boru on 2026-07-31, and ~1,600 upstream commits landed in
between. Result: all seven modules (launcher included) `boru check` with
**0 errors**; all **nine** suites (the headless app suite is now three
files, below) compile and run green under `boru X`; and the live viewer
works in PTY sessions (open, navigate, search, tabs, commands, a watched
file edited on disk) once item D's workaround is in. The
original catalogue below is kept as history, with a dated status line on
each item.

### Breaking changes hit

| Change (upstream) | Effect on aless | Migration |
|---|---|---|
| Rename AQL → boru: the CLI is `boru` (built from `cmd/go` → `./boru`), native modules are `boru:*`, the build-artifact dir is `.boru/` | every `import "aql:…"`; CI, hook and docs built and ran `./aql` | `boru:tui`, `boru:io`, `boru:time-util`, `boru:math-util`, `boru:string-util`, `boru:struct-util`, `boru:test`; tooling builds `cmd/go` → `./boru` (`GOWORK=off GOFLAGS=-mod=mod` for a standalone tarball; inside a checkout plain `go build`, since `-mod=mod` fails in workspace mode) |
| `/r` renamed `/v` (ADR-011, 2026-08-19) | every export map and the app map (`update: aless-update/r`) | `/v` throughout |
| Relative `import` resolves against the **importing file's own directory**, for `boru X` and `boru check X` | suites in `test/` imported `./aless-*.aql` (cwd-relative) | suites import `../aless-*.aql`; the launcher now runs from any directory |
| — but **IO data paths** (`IO.read` / `IO.write` / `IO.stat` / `IO.remove`) still resolve against the **process working directory** | fixtures `test/fixtures/…` | unchanged: run suites from the repo root (verified — the smoke run from `test/` loads every fixture with `rows=0`); documented in README / CLAUDE.md / the gate |
| **One execution path** (2026-09-19): `boru X` = pre-flight check + compile to bytecode + run on the VM, or `[boru/compile_failed]`; no interpreter fallback for a program (a runtime *callback* with no compiled unit still runs on one — item D); `--compile` / `--force-compile` / `--no-compile` retired (usage errors) | CI compared `aql X` against `aql --force-compile X` | `test/divergence/run.sh`: every suite runs green compiled, every module and suite checks with 0 errors; CI builds boru and calls it |
| Postfix `print` chains reorder (`"a" print` / `"b" print` prints b, a) | the suites' summaries | `print (value)`, one per statement; suites end `Assert.equal 0 (Test.fail-count)` then `print "all green"` |
| `Test.check-prop` returns a PropertyResult map | the prop suite's bare calls left four maps printed at exit | bound: `def _p1 (Test.check-prop …)` |
| Maps keep **insertion order**; `IO.read` keeps a file's key order (2026-07-29) | §8 | adapted in `36affe0` before this migration; README / module comments updated now |

### Open upstream defects worked around

**A. The compile pass's analysis budget, exhausted, surfaces as a
misattributed compiler defect.** (Recorded 2026-10-02 in boru's
`design/COMPILABLE-SUBSET.md` §5,
[boru-lang/boru#528](https://github.com/boru-lang/boru/pull/528).) `test/aless_app_unit_test.aql` (14
headless scenarios driving `Aless.feed` ~100 times) failed after ~60 s
with

```
error: [boru/compile_failed]: bytecode compilation FAILED: unmatched dispatch recovered at def — this is a compiler defect, not a policy: valid code must compile.
  --> source position unknown
```

while `boru check` on the same file was clean in 2 s. Root cause,
established with an instrumented build (counters in
`core/go/analysis_hooks.go` `analysisStepMeter` and the three
`MarkUncompilable("unmatched dispatch recovered at …")` sites in
`check/go/check_recovery.go`): the compile pass executes the program's
top level under check-mode analysis, metered by
`core.DefaultCheckStepBudget = 500_000`, and every `Aless.feed` call
costs a full analysis of the update loop (~9k steps at top level, about
twice that inside a `Test.test` body, whose stored body is analysed by a
probe pass and again by the real pass; measured, eight identical
`_key (a0) "j"` calls cost exactly as much as eight chained ones, so the
unit memo does not absorb it). The run reaches step 500,001, the
analysis is cut off (`step_budget_exceeded`, which the compile pass never reports), the
truncated carriers make the very next dispatches unmatchable — first
`def want (AlessDoc.path-key (p))` in `aless-tabs.aql` — and the latch
records the misleading reason. Evidence: with the constant raised to
5,000,000 the identical file compiles and runs all green (peak ~1.75M
steps; ~2.4M with item D's lambdas in the app map). Re-verified
2026-10-02 against the current modules: a clean 64c5ab2 build changed
only in that constant compiles the pre-split suite and prints `all
green`, though it takes ~12 minutes. Stock 64c5ab2 stops at "code-body
word test-test (Stage 2)". There is no CLI knob (`-options steps:N` is
the *run* budget).
The failure is a function of total size, not of any one scenario —
every scenario compiled alone, and a bisection found some five-scenario
subsets failing while others passed — and the reported reason is
whichever check first trips over the truncated analysis: with the
current modules the same pre-split file stops at "code-body word
test-test (Stage 2)" (latched just after "if: else-branch result of
unknown provenance"), again right after step 500,001. No NUR record
covers it.

*Workaround (semantics-preserving):* the headless app tests are three
suites by subject — `aless_app_unit_test.aql` (boot, command mode, quit,
help, render), `aless_app_browse_unit_test.aql` (navigation, tab
switching, search, yank) and `aless_app_watch_unit_test.aql` (watch
pipeline, manual reload) — with all 14 test names and all 56 assertion
lines unchanged; multi-event sequences go through one fold (`_keys st
["j" "J" "l"]`, `_line st ":" "open …"` — the same events as the nested
`_key`/`_type` calls, analysed once per call instead of once per event);
and the two common starting states (`_booted`, `_json`) are built once
at top level (app states are immutable maps). Measured peaks: 330k, 390k
and 370k steps (with item D's lambdas in the app map) — about a fifth
of the budget spare in the fullest suite. Remove the split when
upstream reports or lifts the budget. Repro: the pre-split suite
(`git show e218c33~1:test/aless_app_unit_test.aql`, saved under
`test/` and run from the repo root) under `boru`, against the same file under a build with
`DefaultCheckStepBudget = 5_000_000`.

**B. Checker false positive: `fold` over `(ev get "mods") otherwise []`.**
Once another *file* calls the update loop with a key event that has no
`mods` key, the analysis of `has-ctrl` (`aless-app.aql`, `aless-nav.aql`)
reports `no_signature: cannot call 'fold' … got (List, Disjunct, Word)`
— the None-dropping `otherwise []` is left a disjunct — and the
pre-flight check blocks the run. Whether it fires depended on the order
the caller's helpers were defined in. Minimal repro (two files; a single
file does not trigger it):

```boru
# m.boru
def has-ctrl fn [
  [ev:Map] [Boolean] [
    fold [ var [[m acc] (acc) or ((m) eq "ctrl") ]] ((ev get "mods") otherwise []) false
  ]
]
def feed fn [[st:Map ev:Map] [Map] [ if (has-ctrl ev) [ (st) set c true ] [ (st) ] ]]
export "M" { feed: feed/v }

# main.boru — boru check: 1 error (no_signature at m.boru 3:5)
import "./m.boru"
def press fn [[st:Map k:String] [Map] [ M.feed (st) {tag: "key", key: (k)} ]]
print (press {} "j")
```

*Workaround:* `has-ctrl` reads the list through the module's existing
typed coercion, `(as-list (ev get "mods"))` (a `[List]`-returning fn),
which the checker accepts — commented at both sites. Unrecorded upstream.

**C. `twin regime: a bind transition has no stream placement` — a
var-binding `each` nested in a top-level var-binding `each` body.** The
smoke suite's fixture walk refused compilation. Minimal repro:

```boru
print (each [ var [[n] (each [ var [[m] m ]] [1]) ]] [1])
```

The same nesting inside a fn body compiles (`def f fn [[xs:List] [List]
[ each [ var [[n] (each [ var [[m] m ]] [1]) ]] (xs) ]]` → `[[1]]`).
*Workaround:* the per-fixture work is a fn (`walk-one`), called from the
top-level `each` — commented in `test/aless_smoke_test.aql`. The refusal
string is the one NUR330 records for `Rand.map-from` bodies; this shape
is not listed there. Recorded 2026-10-02 in boru's `design/COMPILABLE-SUBSET.md` §5
([boru-lang/boru#528](https://github.com/boru-lang/boru/pull/528)).

**D. The live viewer crashed: Tui.run's update ran on the interpreter
fallback, whose loop bodies lose their scope.** The suites never see
this (they drive `Aless.feed` inside one whole-program compile); a PTY
session does. Launched as `boru aless.aql sample.json sample.csv` (or
from the welcome tab, then `:open`), the viewer died on the first
metronome tick, on `r`, or on a search with

```
error: each: element 0: fold: step 0: [boru/undefined_word]: undefined word: AlessDoc
```

from `AlessTabs.reanchor`'s fold body (variants seen while bisecting:
`undefined word: doc2` — the fn's own local — and `undefined word: v`
in `aless-doc` `kids-of`; and `stamp-of`'s `do [IO.stat (make Pathon
(path))]` silently trapping `undefined word: path`, so every first tick
reloaded). Traced with an instrumented build (stack at
`compiler.StampTokenBody`, the ref seen by `eng` `invokeCompiled`):

1. the compile pass stamps the app map's `update: aless-update/v` value
   (`-compile-report`: `stamped aless-update @ 434:35`), but the
   `CompiledFnRef` it leaves on the value has no program at run time;
2. `Tui.run` → `core.InvokeCallbackFn` finds the slot occupied, so the
   lazy stamp (`LazyStampFnSig`) never runs, `InvokeCompiled` finds no
   unit, and `invokeCallback` falls back to `CallBoru` — the
   interpreter;
3. on the interpreter every `each` / `fold` / `do` body is handed to
   `InvokeBody` → `vmContext.invokeTokenBody` → `StampTokenBody`, a
   detached unit "compiled against r's live bindings" — which hold
   neither the interpreter frame's fn-local defs and params nor (here)
   the defining module's imports.

Whether the compile pass leaves that stamp depends on incidental code
shape: an interim variant of `aless-tabs.aql` (module-local wrappers
for the `AlessDoc` calls in its fold bodies, and `as-list`-typed fold
operands) happened to avoid it for a one-file launch — that run showed
`stamped aless-update` with no position, i.e. the lazy stamp, and
worked — but not for two files or the welcome tab, so dodging shapes in
the loop bodies is no fix. No NUR record covers it; `invokeCallback`'s
own comment calls the interpreter fallback "slow, never wrong".

*Workaround:* the app map hands `Tui.run` lambdas over the module's
fns — `update: ([st:Map ev:Map] => [aless-update st ev])`, `view:
([st:Map] => [aless-render st])` — which are stamped lazily at their
first application and run compiled (`-compile-report`: `stamped
(anonymous fn)`, no `codebody` stamps at all). Verified in PTY
sessions: two files on the command line with ~40 keys across
navigation, search, yank, help, tab switching, `W`, `r`, `:tab`,
`:open`, `:watch off`, `:close` and quit; and the welcome tab →
`:open` → an on-disk edit reloaded in place → search → quit, launched
from another directory. Repro of the crash: run the two-file launch on
`b29662e`.

### Open upstream defect, not worked around (checked: nothing relies on it)

**E. `Assert.equal` passes zero values of different types as equal.**
`Assert.equal 0 false`, `Assert.equal "" false` and `Assert.equal 0 ""`
pass in either order, as do `Assert.equal false none`, `Assert.equal 0
none` and `Assert.equal "" none`. `Assert.equal none false`,
`Assert.equal [] none` and `Assert.equal true none` fail. Minimal repro:

```boru
import "boru:test"
Test.test "zero-cross-type" [ Assert.equal 0 false ]
Test.test "zero-vs-none" [ Assert.equal false none ]
print (Test.fail-count)    # prints 0: both pass
```

`Assert.equal` (`lang/go/modules/test.go`) calls `ValuesEqual`
(`core/go/equal.go`), whose own comment says it compares the payloads
of two values *with the same type*. Nothing checks the types first. No
NUR record covers it.

Every aless assertion uses the stack form `literal (computed)
Assert.equal end`. The top of the stack binds first, so the computed
value is the first parameter. That makes a computed `none` against a
literal `false`, `0` or `""` fail, as it should, but a computed `0`
against a literal `false` would still pass. To check that no assertion
depends on this, every suite was re-run (2026-10-02) with each
`Assert.equal end` replaced by a helper that first asserts
`(typeof x) eq (typeof y)`. All 253 assertions ran and passed. No
workaround was applied. A new assertion against a zero-valued literal
should keep this defect in mind.

### Property generators compiled (2026-10-02)

**F. `Test.check-prop` generator bodies ran on the interpreter.** Every
suite compiled as a program, but `boru -compile-report
test/aless_doc_prop_test.aql` listed **4** runtime callbacks that "did
not compile": the generator bodies `[r.list-of [r.int 0 999] n]` at
36:3, 53:3, 69:3 and 86:3, each with "closure storedfn$body: unapplied
fn-value in body residual (dynamic apply not lowered)" — the
property-generator shape recorded in boru's `design/COMPILABLE-SUBSET.md`
§5 ([boru-lang/boru#528](https://github.com/boru-lang/boru/pull/528)).
They answered correctly on the interpreter. *Rewrite:* the four
generators now call one named fn, `[ (_op-stream n r) ]`, defined as
`def _op-stream fn [[n:Integer r:Map] [List] [ (r.list-of [r.int 0 999] n) ]]`.
After the rewrite, **0** decline. Runs, seeds and max-shrinks are
unchanged. A scratch harness ran the old and new generators through the
suite's own four property bodies, printing every input and every
decision, for four seeds × 30 runs each (480 inputs, 16 result maps):
the outputs are byte-identical. So are the result maps of a
deliberately failing property over six seeds, with max-shrinks 0 and
with 50. Spellings that did not work: grouping inline,
`[(r.list-of [r.int 0 999] n)]`, compiles but the inner body loses `r`:
the generator raises `undefined word: r`, so the property reports
`ok: false` where the interpreter generates the lists (an answer
divergence; not recorded upstream either — neither boru's `NUR.md` nor
`COMPILABLE-SUBSET.md` lists it);
grouping only the inner call still declines; and
`[ [for 14 [(r.int 0 999)]] ]` declines ("body result of unknown
provenance"). **A second, silent
divergence, not yet recorded upstream:** inside a fn whose param is the
random source, `r.list-of` left ungrouped as the body's result compiles
and runs, but it draws once and repeats that value:

```boru
import "boru:rand"
def g fn [[r:Map] [List] [ r.list-of [r.int 0 999] 4 ]]
print (g (Rand.with-seed 7))   # interpreter [550, 417, 502, 54]; compiled [550, 550, 550, 550]
```

The same happens with `[r.float]`, with `r:Any` and with a trailing
`end`. Grouping the call, binding it first (`def xs (r.list-of …) xs`)
or reading a top-level `r` instead of a param all agree with the
interpreter. Under `check-prop` the repeated lists still pass every
property, so only a value-level diff shows the bug. That is why
`_op-stream` keeps its parens.

### Not changed, on purpose

- The welcome tab and the help overlay still say "an aql file viewer":
  user-visible product text, asserted by the app suite; renaming it is a
  product decision, not a migration step.
- The workarounds for §1, §3 and §4 stay: their upstream fixes are on
  main, but the fold / `is`-chain / def-then-return shapes are simple and
  correct either way.
- The watch stays poll-based although §2 no longer reproduces: the
  metronome is proven under `Tui.run`, and switching to `IO.watch` is a
  feature change, not a migration.

---

## Issues

### 1. 🔴 `def` from a call can silently fail to bind in deep call chains

In an update-loop chain (fn → `case` arm → fn → fn, as driven by
`Tui.run` or an equivalent fold), a `def` whose value is a call to a
**local alias fn** (a one-line wrapper around another module's export)
or to a **recursive fn** completes without binding — no error at the
def, then the *next* statement raises `undefined_word` for the name:

```aql
def with-active fn [[state:Map tab:Map] [Map] [ AlessTabs.put-active state (tab) ]]
# inside a case arm several frames deep:
def s3 (with-active (s2) (tabw))     # completes, binds NOTHING
def err ((AlessTabs.active (s3)) …)     # [aql/undefined_word]: s3
```

Replacing the alias with the direct module call (`def s3
(AlessTabs.put-active (s2) (tabw))`) binds correctly; converting recursive
helpers (`add-ancestors`, `surviving-anchor`) to `fold`s fixed the same
failure in `AlessTabs.reanchor`/`reveal`. Every module now avoids local
alias fns and recursion in state-machinery as a matter of policy.

**Root-caused & fixed** (on the tracked aql branch): reduced to a
standalone repro and isolated to **tail-call elimination**, so it is
**interpreter-only** — the default runtime compiles and the bytecode path
was always correct, which is why the same shape returns the right value
under `--force-compile` and only `--no-compile` errored. That masking is
also why it never showed up as a standalone repro before: `aql script.aql`
compiles, so the failure only surfaced in the composed program along a
path the compiler happened to refuse (falling back to the interpreter).
Minimal repro (`--no-compile`):

```aql
def f fn [[n:Integer] [Integer] [ if ((n) lte 0) [ 0 ] [ f ((n) sub 1) ] ]]
def x (f 3)          # binds nothing under the interpreter
def y ((x) add 1)    # [aql/undefined_word]: x
```

The trigger is precise: a fn body that ends in a **tail call** whose
**result is consumed as a forward paren-group argument** (`def x (f n)`,
`g (f n)`, `(f n) add …`). A forward paren group is evaluated eagerly by
the engine's `evalParenGroupAt`, which walks the group's tokens with a
local paren-depth counter to find its matching `)`. The tail call inside
the group fires TCO, which rewrites the enclosing frame region on the tape
(full-frame replacement / shell elision) out from under that counter — the
group's `)` is deleted or index-shifted before the loop decrements on it,
so the counter never reaches zero, the group never collapses, and the
bound result silently vanishes. Neither recursion nor an alias is required
in itself; both merely *produce* the shape — an alias `def s3
(Ns.put-active …)` is a one-call tail body bound through a forward paren.
The fix declines TCO while a paren group is being evaluated (the tail call
nests, which the depth counter tracks correctly) — a strict improvement,
since a declined tail call only nests and never changes a result. (One
narrow, interpreter-only caveat: a *very* deep — >~70k — tail recursion
consumed through a forward paren now nests rather than iterating, so
`--no-compile` can raise `tape_exhausted` where the default compiled path
stays O(1). The shape was fully broken before, so this is still strictly
better; the compiler covers it on every path but the diagnostic
interpreter.) The fold/direct-call workarounds above are retained because
this viewer also runs on stock aql main, where the fix has yet to merge —
they dispatch correctly either way. (Pre-fix shapes are in this repo's git history,
`aless-app.aql`/`aless-tabs.aql` before 7c6f739.)

> **Status on boru main @ `64c5ab2` (2026-10-01): fixed.** The minimal
> repro prints `1`; there is no interpreter path any more.


### 2. 🔴 `IO.watch` callbacks are never delivered while `Tui.run` runs

A watch registered from inside a `Tui.run` update never fires its body:
no callback, no `send`, nothing — while the *identical* registration in
a headless script delivers within milliseconds. Repro pair:

```aql
# headless: fires (op=write lands in /tmp/aless-fire.txt)
def fire fn [[ev:Map] [Integer] [ IO.write (make Pathon "/tmp/aless-fire.txt") "hit" end drop 0 ]]
IO.watch (make Pathon ".") [fire] {match: "w.json"}
IO.write (make Pathon "./w.json") "{}" end drop
TimeUtil.sleep 800
```

The same `IO.watch` call made during a `Tui.run` update (the handle is
live, `Watcher(W_…)`) never runs `[fire]` for external writes to the
watched directory. Presumably the callback's concurrent fork needs the
runtime that registered it, and the TUI driver owns it while parked on
the mailbox. Since the whole point of watching in a TUI is reacting
while the loop is parked, `aql:tui` + `IO.watch` currently cannot be
combined. **Workaround (shipped):** a spawned metronome process
(`spawn` + `TimeUtil.sleep` + `send {tag:"tick"} "tui"` — this path
works perfectly) with mtime+size polling in `update`.

> **Status on boru main @ `64c5ab2` (2026-10-01): no longer reproduces.**
> A PTY probe — a `Tui.run` app whose `init` arm registers
> `IO.watch (make Pathon ".") [fire] {match: "w.json"}`, with `fire`
> writing a marker file and `send {tag: "hit"} "tui"`, then quitting on
> `hit` — fired, delivered the message and quit on its own when
> `w.json` was written from outside. aless keeps the metronome + poll
> design (it works, and changing it is a feature change).


### 3. 🔴 User multi-signature fn dispatch loses a value's concrete type

A multi-sig fn (`[v:Map]…[v:List]…[v:Any]…` overloads) picks its `Any`
overload for a genuine Map when the value arrives through an Any param
inside a call chain that originates in an `each` body — and in some
cross-module chains (a value loaded in module A, dispatched by module
B's internal overloads). Native words (`is`, `get`, `keys`) see the
true type in the same positions. Minimal repro:

```aql
def nk fn [ [v:Map] [String] ["map"] [v:Any] [String] ["leaf"] ]
def hop fn [[cv:Any] [String] [ nk (cv) ]]
def doc {meta: {age: 36}}
print (hop ((doc) get "meta"))                                  # map ✓
print (each [ var [[k] (hop ((doc) get (k))) ] ] (keys (doc)))  # ["leaf"] ✗
```

**Workaround (shipped):** type dispatch in shared data-plumbing uses
single-sig fns with native `is`-chains (`aless-doc.aql`
`node-kind`/`get-seg`/`has-seg`); multi-sig overloads only where the
dispatch happens directly on an expression at the call site.

**Fixed** (on the aql branch this viewer tracks): the divergence was
**bytecode-only** — the interpreter re-dispatched on the true value
(`--no-compile` yields `["map"]`), but the default runtime compiles, and
the compiler baked the wrong arm (`["leaf"]`). Root cause: the value
reaches `nk` through `hop`'s `Any` param, whose generalised arg is a
*strict* `Any` carrier (`core_helpers.go`); a strict `Any` matched only
`nk`'s `Any` overload, so `matchSignature` committed that arm statically
instead of arming the runtime poly re-match. The each/fold body is only
what keeps the intermediate value gradual (a loop-variable key defeats the
constant-fold that would otherwise pin it to a concrete `Map`). The fix
treats a strict `Any` carrier as reaching every same-arity arm, so the
dispatch arms the existing user-poly re-match and the VM re-runs
`MatchSignature` on the real value — exactly like the interpreter, or it
refuses to the interpreter; never a wrong static commit. Pinned by
`lang/go/bytecode_userpoly_anywrapper_test.go` (a Map selects the Map arm,
a leaf the Any arm, on both surfaces). The `is`-chain workaround above is
retained because this viewer also runs on stock aql main, where the fix
has yet to merge — it dispatches correctly either way.

> **Status on boru main @ `64c5ab2` (2026-10-01): fixed.** The repro
> prints `map` and `["map"]`.


### 4. 🟡 A map literal returned from an fn body evaluates after teardown

`fn [[a:Integer b:Integer] [Map] [ {x: (b)} ]]` raises
`undefined_word: b` at call time: the returned map literal's `(…)`
values evaluate only after the call's params are gone (body-local defs
survive; params do not). **Workaround:** bind first — `def out {x:
(b)} out`. Used everywhere in the modules.

> **Status on boru main @ `64c5ab2` (2026-10-01): fixed.** The repro
> prints `{"x": 2}`.


### 5. 🟡 No script argv (and no env access)

`aql script.aql a b c` silently ignores `a b c` (the CLI reads only the
script path), and no word exposes environment variables. A CLI tool
written in AQL cannot receive "which file to open" from its command
line — so `aless`'s baseline launch story is `aql aless.aql` + `:open`,
or an `aql -e 'import … Aless.run {files:[…]}'` one-liner. RFC:
`proposals/script-argv-and-env.md` (an `IO.args` word + CLI plumbing;
the launcher already reads it behind a `do/error` feature-detect, so a
build that carries it accepts `aql aless.aql notes.json`).

> **Status on boru main @ `64c5ab2` (2026-10-01): implemented upstream.**
> `IO.args` (boru `16266c0a6`, 2026-07-21) and `IO.env` / `IO.env-all`
> (`5a2dd554a`, 2026-07-29). `boru aless.aql notes.json` opens the file.


### 6. 🟡 Checker friction: several false-error shapes gate execution

Plain `aql X` refuses to run on check *errors*, and these check-only
shapes all came up while building the viewer (workarounds in
parentheses; all shipped):

- `is`-guarded branches don't narrow: `get`/`has` on a checker-typed
  disjunct is an error even though the branch guards it (→ overloads or
  is-chains behind an `[Any]` fn).
- A fold's accumulator is typed as the *element* type, so map-shaped
  accumulators error (→ restructure; see also §7).
- An IO-word result binds as an unresolved partial when an arg type
  mismatches — `IO.read "s"` needs `(make Pathon s)`; the follow-on
  errors ("cannot call `x`") point at every *use* of the binding.
- `convert String x` needs a statically-Scalar `x`; an Any-typed name
  inside `${…}` is treated as a zero-arg call (→ tiny typed coercion
  helpers `as-str`/`as-int`, typed accessors like `row-at`).
- A top-level *script*'s relative imports are CWD-relative, while an
  *imported* module's imports resolve against its own directory. When
  the modules lived under `viewer/`, `aql check viewer/aless-nav.aql`
  from the repo root couldn't resolve the module's sibling
  `./aless-doc.aql`. Flattening every module to the repo root removed
  the mismatch — `aql check aless-nav.aql` now resolves its siblings —
  so the whole tree checks clean file-by-file from the root.

> **Status on boru main @ `64c5ab2` (2026-10-01):** an `is`-guarded `get`
> narrows (`if (v is Map) [ (v) get "a" ]` checks and runs); a Map-shaped
> fold accumulator checks; `convert String` of an `Any` and an `Any` name
> inside `${…}` both work; a String path to `IO.read` is now a plain
> `call to 'read' matched no signature` (still needs `make Pathon`).
> Imports resolve against the importing file for scripts too (migration
> section), so the CWD/sibling mismatch is gone. One new false positive
> is recorded in the migration section (B).


### 7. 🟡 `fold`'s var binding order contradicts its description

`describe fold` says "the accumulator is pushed first", and the older
idiom reads `var [[acc x]]` — but the element is on *top*, so
`var [[a b]]` binds `a` = element, `b` = accumulator:

```aql
print (fold [ var [[a b] (a) ]] ["elem"] "init")   # elem — a is the ELEMENT
```

Commutative folds (`add`) mask the swap; anything asymmetric silently
computes garbage. Every fold in this repo reads `var [[elem acc]]`.

> **Status on boru main @ `64c5ab2` (2026-10-01): documented.**
> `describe fold` now says the accumulator is pushed first and the
> ELEMENT sits on top, so `var [[a b]]` binds the element to `a` — what
> this repo assumed.


### 8. 🟢 Map key order is always sorted

`{b:1, a:2}` stores, prints, and iterates as `a, b` — source order is
unrecoverable, so a JSON viewer cannot show keys in file order (jless
does). Documented as a viewer deviation.

> **Status (2026-07-29, re-verified on boru main @ `64c5ab2`):
> resolved.** Maps keep insertion order and `IO.read` keeps a file's key
> order; aless shows fields in source order (adapted in `36affe0`).


### 9. 🟢 jsonic-family leniency swallows truncation

`{"a": 1, "b": ` parses without error to `{a:1, b:null}` on the
`json`/`jsonic` paths — a malformed file "loads fine" with partial
content. There is no strict mode on the `IO.read` formats. The viewer
surfaces only hard read/parse errors.

> **Status on boru main @ `64c5ab2` (2026-10-01): unchanged** — the
> truncated `{"a": 1, "b": ` still reads as `{"a": 1, "b": null}`.

## What worked well (worth keeping)

- **`IO.read` is a one-stop loader**: extension-inferred parsing over
  the whole tabnas family (plus `{fmt}` override, `{field:
  {separation:"\t"}}` for CSV variants — the "no tsv parse kind" gap in
  earlier planning was wrong at the IO.read level; only the `parse`
  word's kind set lacks it). `aless-fmt.aql` is ~40 lines because of
  this.
- **The `aql:tui` core held up**: alt-screen, diffed rendering, widget
  layout, key decoding, `Tui.quit`, and the "any mailbox message folds
  through update" contract all behaved exactly as specified —
  `send {…} "tui"` from a spawned process is a reliable event source.
- **`canon` is the right display serializer** (no HTML escaping, smart
  quote switching, `none`/numbers/bools render cleanly).
- **Headless TUI testing via an exported feed word**: exporting the
  update fold (`Aless.feed`) lets a plain test suite drive the real app —
  command mode, tabs, search, watch-reload against real disk writes —
  with no terminal. Pattern recommended for any aql:tui app (an
  AQL-reachable virtual backend would still be better — see
  `proposals/tui-live-io-and-testability.md`).

## Bytecode status

All seven suites — including the headless app-integration suite — run
**fully compiled** under `aql --force-compile`, byte-identical to the
interpreter, after one fix this surfaced: a `for`-loop body must leave
no residual value (`for` accumulates each iteration's results on the
stack, so the watch metronome's value-yielding body both grew the stack
by one entry per second and refused compilation with "result is a
variadic loop value"). The live TUI under `--force-compile
--compile-report` now stamps **all 110** of its runtime-constructed
callbacks to the VM — zero refusals — after isolating and designing out
the one refusing shape, since fully reduced to its law: a **Map-typed
local consumed by a user-fn call inside an `if` branch** loses its
operand provenance for any later user-fn call after the join — "fn call
operand of unknown provenance" — even with identical branches, and with
a single consuming branch. The boundary is sharp: a scalar local
survives the identical shape, the same map local survives without the
`if`, and it survives when nothing reuses it after the join.

**Fixed upstream** (on the aql branch this viewer tracks): the root
cause was a branch-join provenance bug — an enclosing local merely READ
inside both `if` arms is narrowed-through-use (identity-preserving), but
`InstallJoinedDefs` re-seated it as a fresh-ID `JoinCarriers` result,
stranding every later reference. `joinBranchDef` (eng/go/carrier.go) now
keeps the shared ID when both arm carriers are the same identity (an
identity no-op merge), so the binding's compile seat survives; a genuine
reassignment (differing IDs) keeps the fresh-ID join. With the fix the
`def midpane (if … [help-pane] [tree-pane …])` form compiles with zero
refusals; `aless-view.aql` branches on the whole widget list instead of
binding the pane so that it also compiles cleanly on stock aql main,
where the fix has yet to merge. Pinned upstream by
`lang/go/bytecode_ifbranch_operand_test.go` and the
`design/COMPILABLE-SUBSET.md` §2 branch-join narrow-preservation note.

> **Status on boru main @ `64c5ab2` (2026-10-01):** `--force-compile`
> and the interpreter are gone — every program is compiled or refused —
> so "byte-identical to the interpreter" is no longer a thing to check;
> the gate is that every suite compiles and runs green. Getting there
> needed the three workarounds in the migration section.

## Summary

(Status column as of the AQL build; the last column is boru main @ `64c5ab2`, 2026-10-01.)

| # | Severity | Issue | Status | main @ 64c5ab2 |
|---|----------|-------|--------|---|
| 1 | 🔴 | silent `def`-binding failure in deep call chains (alias fns, recursion) | **root-caused & fixed** on the tracked aql branch (TCO × forward-paren-group, interpreter-only); fold/direct workaround retained for stock main | fixed |
| 2 | 🔴 | `IO.watch` callbacks starved under `Tui.run` | open; metronome+poll workaround | no longer reproduces; poll kept |
| 3 | 🔴 | multi-sig dispatch degrades through Any params in each/cross-module chains | **fixed** on the tracked aql branch (bytecode strict-Any re-dispatch); is-chain workaround retained for stock main | fixed |
| 4 | 🟡 | returned map literal evaluates after param teardown | open; def-then-return | fixed |
| 5 | 🟡 | no script argv / env access | open; RFC filed, launcher feature-detects | `IO.args` / `IO.env` landed |
| 6 | 🟡 | checker false-error shapes gate `aql X` | open; typed-helper idioms | mostly fixed; new FP (migration B) |
| 7 | 🟡 | fold var order contradicts docs | open; element-first idiom | documented |
| 8 | 🟢 | map keys always sorted | by design; documented deviation | insertion order |
| 9 | 🟢 | lenient parsing swallows truncation | by design; documented | unchanged |
