# Does regular tmux have the same problem? Partly.

Question: is the scrollback memory blow-up specific to psmux, or does upstream
tmux do it too? Answer, measured on **tmux 3.4** (WSL2 / Ubuntu) against the same
geometry as the psmux repro: **tmux is much more efficient, but not immune.**

The scripts [`tmux-oom-repro.sh`](./tmux-oom-repro.sh) (RSS-over-time) and
[`tmux-retention-check.sh`](./tmux-retention-check.sh) (proves the lines are
actually retained, via tmux's own `#{history_size}`) are the tmux counterparts
of `psmux-oom-repro.ps1`.

> **Gotcha that matters for reproducing:** tmux reads `history-limit` when the
> pane is *created*. `set-option history-limit N` **after** `new-session` does
> not apply to the existing pane — it keeps the ~2000 default and silently trims
> the flood, making tmux look artificially tiny (~16–31 MB). You must set it at
> server start (`tmux -f conf` with `set -g history-limit N`) for the pane to
> retain the flood. Both scripts here do this; the numbers below use it.

## The key difference

- **psmux** stores every scrollback line as a dense full-pane-width `Vec<Cell>`
  at 44 bytes/cell → cost is `history_limit × cols × 44`, **independent of line
  content**. A 10-char line and a 500-char line cost the same.
- **tmux** stores scrollback proportional to the cells a line actually uses
  (trailing blanks are not materialized) → cost scales with **real content
  width**.

## Measured (cols=500, history-limit=200000, 120,000 lines, all fully retained)

| Line content width | tmux 3.4 peak RSS | psmux (fixed, any width) | tmux vs psmux |
|---|---|---|---|
| 10 chars | **126 MB** (1.1 KB/line) | 2,304 MB (20 KB/line) | ~18× less |
| 30 chars (typical `cargo test` line) | **179 MB** (1.6 KB/line) | 2,304 MB | ~13× less |
| 150 chars | **614 MB** (5.4 KB/line) | 2,304 MB | ~3.7× less |
| 500 chars (full width, wraps) | **1,433 MB** (7.5 KB/line) | 2,304 MB | ~1.6× less |

Control (tmux defaults `-x 80` `history-limit 2000`): **9 MB**.

## Interpretation

- **tmux scales with content; psmux does not.** As lines get shorter, tmux's
  advantage widens (18× at 10 chars) because psmux keeps paying for 460 blank
  cells while tmux does not. For *typical* build/test output (short-to-medium
  lines) tmux uses roughly **an order of magnitude less** memory.
- **But tmux is not immune to the same aggressive config.** At `history-limit
  200000` + a 500-wide pane, tmux still reaches **126 MB – 1.4 GB per pane**
  depending on line width, and it also carries a non-trivial fixed per-line
  overhead (~1 KB even for a 10-char line). At the ralphus default of 20
  concurrent panes, even the short-line case (≈126–179 MB × 20 ≈ 2.5–3.6 GB) or
  the long-line case (≈0.6–1.4 GB × 20 ≈ 12–28 GB) can exhaust memory. tmux
  raises the threshold; it does not remove it.

## Takeaways

1. The psmux fix (compact scrollback rows to used width) closes most of the gap
   — it's exactly the strategy tmux already uses, and would bring psmux's
   short-line cost down toward tmux's.
2. The **ralphus-side mitigation applies regardless of which multiplexer is
   used**: `history-limit 200000` × wide pane × high concurrency is a lot of
   memory even on upstream tmux. A saner `history-limit` and/or concurrency cap
   is warranted independent of the psmux bug.
3. For reproducing/benchmarking tmux, always set `history-limit` at server
   start, or the pane silently ignores it.

_All figures: tmux 3.4, WSL2 Ubuntu; psmux figures from `RESULTS.md` (psmux
3.3.7, Windows 11)._
