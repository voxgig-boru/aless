# AQL Proposal: Def-Binding and Dispatch Soundness in Deep Call Chains

**Status:** Draft — this is primarily a bug report with repros; the
"proposal" is that these become pinned negative tests upstream.
**Status update (2026-10-01, boru main @ `64c5ab2`): all three fixed
upstream.** §1's repro binds (`1`), §2's prints `["map"]`, §3's prints
`{"x": 2}` (dx-report §1, §3, §4). AQL is now boru, with a single
compiled execution path.
**Target:** `aql-lang/aql` engine (dispatch, scope cleanup).
**Provenance:** surfaced while building the `aless`
TUI file viewer; recorded as **§1, §3, §4** of of
[`dx-report.md`](../dx-report.md).
**Build referenced:** `aql @ c1d2a1a` (main, 2026-07-20).

Three related failures, all *silent* (no error at the faulty site, or
no error at all), all sensitive to **where a call chain starts** rather
than what the code says. Each has a shipped workaround in the modules,
but they are the kind of bug that unit tests miss and composed programs
hit: the same shapes pass when called directly and fail three frames
deep.

## 1. `def` from a call silently binds nothing (🔴)

Inside an update-loop chain (fn → `case` arm → fn → fn, e.g. under
`Tui.run`'s fold), a `def` whose value comes from a **local alias fn**
(one-line wrapper delegating to another module's export) or from a
**recursive fn** completes without installing the binding; the next
statement raises `undefined_word`:

```aql
def with-active fn [[state:Map tab:Map] [Map] [ AlessTabs.put-active state (tab) ]]
…                                     # several frames deep, in a case arm:
def s3 (with-active (s2) (tabw))      # no error here — and no binding
def err ((AlessTabs.active (s3)) …)      # [aql/undefined_word]: s3
```

Calling the module export directly binds fine; converting the recursive
helpers to folds fixed identical failures in `AlessTabs.reanchor`/`reveal`
(`aless-tabs.aql`, history before commit 7c6f739 has the failing
shapes). Suspect: a frame-cleanup snapshot that restores def-depth
past the just-installed binding when the callee's own frame machinery
(delegation or recursion) unwinds — same family as the historical
`comp/r` frame over-pop.

## 2. Multi-sig dispatch degrades through Any params (🔴)

A user multi-signature fn picks its `Any` overload for a genuine Map
when the value is forwarded out of an Any param inside a chain
originating in an `each` body (and in some cross-module chains), while
native words in the same position see the true type:

```aql
def nk fn [ [v:Map] [String] ["map"] [v:Any] [String] ["leaf"] ]
def hop fn [[cv:Any] [String] [ nk (cv) ]]
def doc {meta: {age: 36}}
print (hop ((doc) get "meta"))                                  # map ✓
print (each [ var [[k] (hop ((doc) get (k))) ] ] (keys (doc)))  # ["leaf"] ✗
```

Silent wrong result, no error. Workaround: native `is`-chains for type
dispatch in shared plumbing (`aless-doc.aql`).

## 3. Returned map literals evaluate after param teardown (🟡)

```aql
def f fn [[a:Integer b:Integer] [Map] [ {x: (b)} ]]
f 1 2        # [aql/undefined_word]: b
```

The literal's ParenExprs run only when the returned map is consumed —
after the call's params are torn down (body-local defs survive; params
don't). Workaround: `def out {x: (b)} out`. Either evaluate the
literal's exprs before return, or keep params alive until the return
value is materialised.

## 4. Ask

Reduce and fix #1 (the repo's git history is a reproducer even if a
minimal case is elusive), then pin all three as negative tests — they
are exactly the "assert what must be rejected" cases the lang guide
calls for, except here the rejection needed is of *silent* success.
