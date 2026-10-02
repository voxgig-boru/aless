# proposals/

Upstream **boru-language** (formerly AQL) design proposals (RFCs)
surfaced while building `aless` — changes to boru itself, not to this
app. They live here so the idea is captured next to the code that
motivated it. Each carries a dated status line.

- One proposal per file, kebab-case.
- Each is cross-referenced from the gotcha that motivated it in
  [`dx-report.md`](../dx-report.md).

Current proposals:

- [`script-argv-and-env.md`](script-argv-and-env.md) — script argv
  (`IO.args`) and environment access, so an AQL CLI program can receive
  its arguments (dx-report §5). *Implemented upstream (status
  2026-10-01).*
- [`tui-live-io-and-testability.md`](tui-live-io-and-testability.md) —
  deliver `IO.watch` callbacks under `Tui.run`, and expose an
  AQL-reachable virtual terminal backend for headless testing (dx-report
  §2). *§1 no longer reproduces; §2 still open (status 2026-10-01).*
- [`update-loop-def-binding-soundness.md`](update-loop-def-binding-soundness.md)
  — the silent `def`-binding failure in deep update-loop call chains
  (dx-report §1). *Fixed upstream (status 2026-10-01).*
