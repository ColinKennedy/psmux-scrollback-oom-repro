# ralphus mitigation plan: psmux scrollback OOM

This is the ralphus-side companion to [`README.md`](./README.md) (the upstream
psmux bug report). It records what bit us, the analysis, and how ralphus should
respond independent of whether/when psmux ships a fix.

## What happened

`squad-000000000002` / task `ral395-schema-config` failed. The task's `work`
cell finished its edits, but the attached `clippy-and-tests` proof step — which
runs `cargo clippy` + 4× `cargo nextest` — died mid-run. Cartographer showed the
psmux pane going unreachable, the runner's auto-reattach firing twice and giving
up (`session lost after 2 reattach attempt(s)`), and the daemon logging
`tmux server process exit code: unknown ()`. That failure cascaded the whole
squad (the other three tasks were stacked behind it).

It was not a bug in the RAL-395 code. The psmux **server process ran out of
memory** because the proof's cargo output filled the pane's scrollback, and each
scrollback line costs `cols × 44` bytes fully materialized (see the upstream
report for the vt100-psmux root cause).

## The memory model

Per pane, once output exceeds the history cap:

```
bytes ≈ history_limit × cols × 44
```

ralphus configures each cell's pane in `daemon/src/tmux.rs`:

- `new-session ... -x 500` (line ~829) — wide, to stop long Bash/agent lines
  double-wrapping.
- `set-option history-limit 200000` (line ~850) — 100× tmux's 2,000 default,
  added so `ralphus history --live` doesn't lose older output.

That is `200000 × 500 × 44 ≈ **4.4 GB** ceiling per pane`, and a cargo build/test
is exactly the workload that approaches it.

## Three levers (and why no single one is sufficient)

### 1. `history-limit` — per-pane ceiling (ours today)

The deepest window ralphus ever actually reads back:

| Consumer | Depth | Source |
|---|---|---|
| Runner poll loop + reattach capture | **10,000** | `runner.rs` `capture_pane(session, 10_000)` |
| Durable terminal log (per attempt) | 4,000 | `max_lines_per_attempt()` default |
| Pane snapshot | 4,000 | `PANE_SNAPSHOT_MAX_LINES` |
| Board live-view / history endpoint | 2,000 (user-overridable) | `server.rs` capture_pane_reply |

Nothing reads deeper than 10,000, yet the cap is 200,000 — over-provisioned 20×.

**Recommendation: drop `history-limit` to `15000`** (just above the 10k hard
floor, with headroom). Per-pane ceiling falls from ~4.4 GB to **~330 MB** (~13×)
with zero functional loss. Do **not** go below 10,000 without also lowering the
runner's `capture_pane(session, 10_000)` calls, or the done-sentinel poll and
terminal-log capture silently truncate. Leave `-x 500` — width and history are
independent, and the width is deliberate.

Formula to pick another point (at `-x 500`): `history_limit ≈ target_MB × 1024 / 22`.

### 2. `max_concurrent` — the multiplier

Per-pane limits do **not** bound total memory. `DEFAULT_MAX_CONCURRENT = 20`
(`daemon/src/lib.rs`), so up to 20 panes can run at once:

| history-limit | Per-pane ceiling | × 20 concurrent |
|---|---|---|
| 200000 (today) | 4.4 GB | 88 GB |
| 20000 | 440 MB | 8.8 GB |
| 10000 | 220 MB | **4.4 GB** |

Note the trap: **20 concurrent panes at `history-limit 10000` re-reach the
original single-pane 4.4 GB figure.** Lowering the per-pane knob buys ~20× more
headroom before the cliff, but it does not *bound* the aggregate. If we want a
guarantee under concurrency we must also cap the multiplier (lower
`max_concurrent`, or specifically cap concurrent output-heavy panes) or bound
total scrollback memory globally.

Mitigating factors that keep this from being as bad as the table's ceiling:
- Those are ceilings, reached only by panes that emit ≥ history-limit lines;
  most cells (edits, short commands) never approach it.
- Panes are freed the moment a cell finishes (`kill_session`, `runner.rs`).
- Dependency-stacked tasks serialize — the RAL-395 squad was a linear stack, so
  ~1 heavy pane ran at a time, not 20.

### 3. Compaction (upstream psmux) — removes the ceiling's relevance

The real fix. If psmux trims scrollback rows to used width (see the upstream
report's "Suggested fix"), each pane costs its *actual* content instead of its
ceiling — which is self-bounding, because output is finite per unit time and
finished panes are freed. This is the only lever that bounds the aggregate
without an explicit global cap. Out of our direct control; track it upstream.

## Recommended plan

1. **Now (ralphus, low risk):** set `history-limit` to `15000` in
   `daemon/src/tmux.rs`. ~13× per-pane reduction, no functional loss. This is
   the one-line change that would have prevented the observed failure at the
   observed concurrency.
2. **Now (ralphus, config decision):** decide whether to lower the default
   `max_concurrent`, or leave it and document that heavy squads should set a
   lower per-project concurrency. Needed because lever 1 alone doesn't bound the
   aggregate at concurrency 20.
3. **Consider (ralphus, medium):** a global or output-heavy-pane concurrency /
   scrollback-memory budget, if 1+2 prove insufficient in practice. Only worth
   it if we keep hitting it.
4. **Track (upstream):** the psmux compaction fix. Once it lands and the bundled
   `tmux.exe` is rebuilt, the per-line cost drops ~10× on top of everything
   above, and `history-limit` can be relaxed again if `ralphus history --live`
   depth ever wants it.

## Code touch-points

- `daemon/src/tmux.rs` — `history-limit 200000` → `15000`; the `-x 500` line is
  intentionally left as-is.
- `daemon/src/lib.rs` — `DEFAULT_MAX_CONCURRENT` (if we change the multiplier).
- `daemon/src/runner.rs` — the two `capture_pane(session, 10_000)` calls set the
  hard floor for `history-limit`; keep them and the cap in sync.

## Open decisions

- Final `history-limit` value (15000 proposed; 20000 if we want more live-view
  scrollback headroom, ~440 MB per-pane ceiling).
- Whether to lower `max_concurrent` from 20, or push that to per-project config.
- Whether an aggregate scrollback budget is worth building, or whether
  history-limit + concurrency + upstream compaction is enough.
