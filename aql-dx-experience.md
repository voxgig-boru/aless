# Writing real code in AQL — a developer-experience report

*Based on building `aless` — a jless-style TUI file viewer, ~2,000 lines
across seven modules — plus two fixes to the interpreter itself. This is
a reflection on the **experience** of writing AQL; the repo's
[`dx-report.md`](dx-report.md) is the factual bug catalogue this
complements.*

> **Status note (2026-10-01).** This is a historical reflection, written
> against `aql-lang/aql` @ `c1d2a1a` (2026-07-20); it is left as written.
> AQL has since been renamed **boru** (`boru-lang/boru`; the CLI is
> `boru`, modules are `boru:*`, `/r` is `/v`), and aless now runs on boru
> main @ `64c5ab2`. Of the wish-list at the end: #1 (silent `def`
> binding), #2 (multi-sig dispatch), the `is`-narrowing and
> fold-accumulator parts of #3, #4 (`describe fold`), #5 (`IO.watch`
> under `Tui.run`), #6 (`IO.args` / `IO.env`) and #8 (insertion-ordered
> maps) are done or no longer reproduce; #7 (a boru-reachable virtual
> terminal) is still open. There is now one execution path — every
> program is compiled to bytecode or refused — so the compile-or-refuse
> contract praised below became the only contract. The new sharp edges
> are the compile pass's fixed analysis budget, and a `Tui.run` callback
> path that ran on an interpreter fallback whose loop bodies lost their
> scope — the "green suites, broken app" pattern below, again. Details,
> with repros, in [`dx-report.md`](dx-report.md) ("Migration to boru
> main @ 64c5ab2").

---

## The short version

AQL has a genuinely good core — a one-word universal loader, an Elm-style
TUI stack, a real actor model, an honest compile-or-refuse contract — and
when it works, the code is small and pleasant to read. But the
day-to-day experience today is dominated by one class of problem:
**constructs that are correct in isolation but fail, silently, once
composed**, plus **a type-checker that gates execution on false
positives**. Those two things turn a one-hour change into a three-hour
debugging session, because the failure mode is *"no error, wrong
behaviour, far from the cause."* The language is young and moving fast
(several issues I hit were fixed upstream within days), and the
trajectory is good — but writing a non-trivial program in it today means
internalising a policy manual of workarounds that you learn only by
getting burned.

## The shape of the language

AQL is concatenative — words operate on a value stream — but with a
"forward argument, receiver last" convention that gives it two equivalent
call shapes:

```aql
AlessDoc.expand doc rows ix      # forward form
rows AlessDoc.expand doc ix      # piping form (receiver flows in)
```

Parens terminate a call and turn it into a value; `def`/`fn`/`case`/`if`/
`fold`/`each` are the structural verbs. It's strongly typed, and — this is
the unusual part — **the type checker is a hard gate**: `aql script.aql`
*refuses to run* if `aql check` reports errors. Discovery is
tool-driven and good: `aql describe` and `aql help` answer "what words
exist / what does this do" straight from the binary.

The core model is easy to like. Once the forward/piping duality clicks,
pure data transformation reads cleanly, and the pure half of aless
(`aless-doc`, `aless-nav`, `aless-tabs`) is genuinely tidy.

## What made it a pleasure

- **`IO.read` is a one-word universal loader.** Extension-inferred
  parsing across the whole format family — json, jsonic, json5, jsonc,
  csv, tsv, toml, yaml, xml, ini, zon, markdown — with a `{fmt}` override
  and CSV-separator options. `aless-fmt.aql`, the module that "supports
  every format aql can parse," is about 40 lines. That's the single best
  moment of the project: a hard-sounding requirement collapsed to almost
  nothing.
- **`aql:tui` is a clean Elm.** `Tui.run {init update view}`, pure
  `update` folding events into a state map, and — the detail that makes
  it composable — *any* mailbox message folds through `update`. Alt-screen,
  diffed rendering, key decoding, and `Tui.quit` all behaved exactly as
  specified.
- **The actor model is a reliable event source.** `spawn` a process,
  `send {…} "tui"`, `whereis` — this path never surprised me, and it's
  what made the watch feature possible at all (see the metronome, below).
- **`canon` is the right display serialiser** — no HTML escaping, smart
  quote switching, clean rendering of `none`/numbers/bools.
- **Compile-or-refuse is honest.** The bytecode compiler refuses shapes
  it can't prove rather than miscompiling them, and `--compile-report`
  tells you exactly which callbacks it stamped. That honesty is rare and
  builds trust — you can ship `--force-compile` and *know* it's the same
  program.

## What made it hard — the through-line

Almost every serious problem I hit shares one signature: **it works at
the small scale and breaks at composition, with no error at the fault
site.** Three examples, all real, all from aless:

**1. A `def` can silently bind nothing in a deep call chain.** In an
update-loop chain (fn → `case` arm → fn → fn), a `def` whose value is a
call to a local alias fn or a recursive helper *completes without
binding*. No error at the `def`; the *next* line raises `undefined_word`:

```aql
def with-active fn [[state:Map tab:Map] [Map] [ AlessTabs.put-active state (tab) ]]
def s3 (with-active (s2) (tabw))     # completes, binds NOTHING
def err ((AlessTabs.active (s3)) …)  # [aql/undefined_word]: s3
```

The same code works at the top level and in a unit test. It only fails in
the deep, composed program. That means **a green unit suite does not
protect the assembled application** — the most unsettling property a
language can have. I ended up adopting a blanket policy: no local alias
fns, no recursion in state machinery (rewrite as `fold`).

**2. Multi-signature dispatch loses a value's concrete type.** A fn with
`[v:Map]…[v:List]…[v:Any]` overloads picks its `Any` arm for a genuine
Map when the value arrives through an `Any` param inside an `each` body or
a cross-module chain:

```aql
def nk fn [ [v:Map] [String] ["map"] [v:Any] [String] ["leaf"] ]
def hop fn [[cv:Any] [String] [ nk (cv) ]]
print (hop ((doc) get "meta"))                                  # map  ✓
print (each [ var [[k] (hop ((doc) get (k))) ] ] (keys (doc)))  # leaf ✗
```

Native words (`is`, `get`, `keys`) see the true type in the same spot, so
the fix is to abandon user overloads for data-plumbing and hand-write
`is`-chains behind an `[Any]` fn — which is exactly the C-style dispatch
the overload system is supposed to replace.

**3. A returned map literal evaluates after the call's params are gone.**

```aql
fn [[a:Integer b:Integer] [Map] [ {x: (b)} ]]   # undefined_word: b
```

The literal's `(…)` values evaluate *after* teardown, so params vanish.
The fix — bind first, `def out {x:(b)} out` — is used in every module.

The common thread: correctness is **sensitive to where a call chain
starts and how deep it is**, and the failures are silent. You stop
trusting local reasoning and start defending against composition.

## The checker: a gate, not a guide

Because the checker *blocks execution*, its false positives cost real
time. Several shapes came up repeatedly:

- **`is`-guards don't narrow.** A `get`/`has` inside a branch the checker
  proved reachable is still flagged, because it types the value as the
  full disjunct.
- **A `fold`'s accumulator is typed as the element type**, so any
  map-shaped accumulator errors.
- **An IO-word result binds as an unresolved partial** on an arg-type
  mismatch (`IO.read "s"` wants `(make Pathon s)`), and then *every use*
  of the binding lights up red — the error points everywhere except the
  cause.
- **`convert String x` demands a statically-Scalar `x`**, and an
  `Any`-typed name inside `${…}` is read as a zero-arg call.

None of these are runtime bugs — the code runs fine once the checker is
placated. But you placate it by writing tiny typed shims — `as-str`,
`as-int`, `row-at` — whose only job is to tell the checker what the
runtime already knows. When a *hard gate* is wrong this often, it stops
being a safety net and becomes a puzzle you solve before you're allowed
to run your program.

## The idiom tax

By the end, aless had a distinct "house style" — and almost every rule in
it exists to dodge a sharp edge, not to express intent:

| Idiom | Exists because |
|-------|----------------|
| `def out {…} out` (bind-then-return) | map literals evaluate after teardown |
| native `is`-chains, not overloads | multi-sig dispatch drops concrete type |
| no alias fns / no recursion in state code | silent `def`-binding failure |
| `var [[elem acc]]` (element first) | `fold`'s doc says accumulator-first; it's wrong |
| `as-str` / `as-int` / typed accessors | checker false positives on `convert`/`get` |
| metronome + poll, not `IO.watch` | watch callbacks are starved under `Tui.run` |
| O(visible) everything | interpreter is ~20× and the compiler refuses some loops |

None of this is discoverable. There's no lint that says "don't alias that
fn." You learn each rule by shipping code that passes its tests and then
misbehaves in the assembled program. A written "AQL in anger" idioms guide
would have saved me most of a day.

## Testing when green doesn't mean correct

The single most important pattern I found was **exporting the update fold
so tests can drive the real app headlessly** (`Aless.feed`) — command
mode, tabs, search, and watch-reload against real disk writes, no
terminal. Recommend it for any `aql:tui` app.

But note *why* it mattered so much: because the pure-unit suites were
green while the composed program was broken (the silent-`def` class),
the *integration* suite driving the real fold was the only thing that
caught the failures that actually shipped. In most languages that's
good practice; in AQL today it's load-bearing. There is no AQL-reachable
virtual terminal, so rendering and raw key decoding still fall back to a
manual PTY smoke — a real gap for a UI language.

## A note on writing AQL as an AI agent

I lean on two signals as ground truth: the type-checker and the test
suite. AQL's checker-as-hard-gate is, in principle, *agent-friendly* —
fast, structured, blocking feedback is exactly what an automated editor
wants. But the two failure classes above invert that: the checker blocks
on things that are *fine*, and the runtime stays silent on things that
are *broken*. When both of my ground-truth signals can lie, iteration
gets expensive — I burned real cycles instrumenting the runtime to prove
where a `def` was failing to bind, because nothing in the normal loop
would tell me. For a language that clearly cares about AI-assisted
development (this repo ships a skill and a `CLAUDE.md`), tightening those
two signals is the highest-leverage DX investment there is.

## What I'd change, in priority order

1. **Kill the silent `def`-binding failure.** A `def` that binds nothing
   with no error is a soundness bug that undermines all local reasoning.
   If it can't be fixed, make it a hard error at the `def` site.
2. **Make multi-sig dispatch preserve concrete type — or error.** It must
   never silently pick `Any` for a value that is demonstrably a `Map`.
3. **Reconcile the checker with the runtime.** Narrow on `is`; type
   fold accumulators by the accumulator; stop propagating partial-binding
   errors to every use site. Where a shape is a known false positive,
   *warn*, don't *gate*.
4. **Fix `describe fold`** to match the actual binding order (element on
   top), or swap the order to match the docs. A word whose documentation
   contradicts its behaviour is a trap for every newcomer.
5. **Deliver `IO.watch` callbacks under `Tui.run`** — or bless the
   metronome+poll pattern in the docs as the supported way to do
   background work in a TUI.
6. **Ship script argv / env access.** (In progress — my `IO.args` PR — but
   worth stating: a CLI language that couldn't read its own argv was a
   striking gap.)
7. **Provide an AQL-reachable virtual terminal backend** so TUI rendering
   and key decoding are testable without a PTY.
8. **Offer an insertion-ordered map** (or preserve source order) — a JSON
   viewer genuinely cannot show keys in file order today.

## Verdict

I enjoyed the good parts more than I expected — `IO.read`, `aql:tui`, the
actor model, and `canon` let me build something real, fast, and the pure
core is code I'd be happy to maintain. The language has taste.

But the experience today is defined by its sharp edges, and they cluster
in a bad place: **silent, composition-sensitive failures** and a
**hard-gating checker that's wrong often enough to become an obstacle
rather than an aid.** Those aren't papercuts; they're the difference
between "I trust my green tests" and "I don't." The encouraging part is
that they're concentrated and *fixable* — they're not deep in the
paradigm, they're in the checker's model, the dispatcher, and scope
teardown. Fix that handful of things and AQL goes from "impressive but
you have to know the tricks" to genuinely pleasant. It's close.
