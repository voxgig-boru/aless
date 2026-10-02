# AQL Proposal: Live IO Under Tui.run, and TUI Testability from AQL

**Status:** Draft.
**Status update (2026-10-01, boru main @ `64c5ab2`):** §1 **no longer
reproduces** — a PTY probe whose `Tui.run` init registers an
`IO.watch` saw the callback fire and its `send` reach `update` (see
dx-report §2); aless still polls. §2 is **still open**: `Tui.open` uses
the host-registered backend only, and the virtual backend remains
Go-side. §3 was not re-surveyed. (AQL is now boru: `aql:tui` →
`boru:tui`.)
**Target:** `aql-lang/aql` — `aql:tui` runtime + `aql:io` watch.
**Provenance:** surfaced while building the `aless`
TUI file viewer; recorded as **§2** and "worth keeping" notes in the
2026-07-21 round of [`dx-report.md`](../dx-report.md).
**Build referenced:** `aql @ c1d2a1a` (main, 2026-07-20).

## 1. `IO.watch` under `Tui.run` (the blocker)

A watch registered from a `Tui.run` update never delivers: the callback
body simply never runs while the TUI driver owns the runtime, though
the identical registration in a headless script fires within
milliseconds (repro pair in dx-report §2). Reacting to filesystem
changes while parked in the event loop is the entire point of watching
in a TUI, so today `aql:tui` and `IO.watch` cannot be combined; the
`av` viewer ships a spawned metronome process + mtime/size polling
instead (that path — `spawn`, `TimeUtil.sleep`, `send {…} "tui"` —
works flawlessly and is a fine pattern, but it costs latency and
loses fsnotify's precision).

**Ask:** run watch callbacks on a runtime fork that does not contend
with a parked `Tui.run` (or document `deliver-events`-style delivery of
watch events straight to a Pid mailbox: `IO.watch p {to: <Pid>}` would
sidestep body execution entirely and matches the tui event model).

## 2. An AQL-reachable virtual terminal backend

`tuikit.VirtualBackend` (inject events, snapshot the screen) exists for
Go tests, and the wasm playground registers a browser backend — but an
AQL program cannot reach either, so an aql:tui app's loop is untestable
from AQL itself. The `aless` viewer compensates by exporting its update
fold (`Aless.feed state ev → state'`) and driving it from a plain test
suite — that covers logic, command mode, tabs, search, and watch-reload
headlessly, but rendering and key decoding stay untested outside a
manual PTY session.

**Ask:** a host-registered virtual backend selectable from AQL —
`Tui.open {backend: virtual, cols: 80, rows: 24}` plus words to inject
an event and read the screen/frame — so the `Aless.feed` pattern can
extend to pixels. (Until then, the feed-word pattern is worth
documenting for app authors.)

## 3. Widget wishlist (conveniences, not blockers)

From building a jless-style tree view in app code:

- a **tree/outline widget** (rows with depth + fold markers + per-row
  style) — every structured-data TUI rebuilds this on `Tui.rows` of
  `Tui.text`;
- a **tab strip** widget;
- `Tui.list-view` accepts only plain strings and derives its scroll
  offset from the cursor — per-item styles and an app-owned offset
  would let it host panes like this one;
- multi-span styled lines (colour the key differently from the value
  without composing `Tui.cols`).
