# psmux scrollback stores every line as a full-width row → multi-GB server memory

**Short version:** the psmux server holds each scrollback line as a *dense,
full-pane-width* `Vec<Cell>` (44 bytes/cell) regardless of how few characters
the line actually contains. Resident memory therefore grows by `cols × 44`
bytes for **every** line that scrolls into history, up to `history-limit`. With
a wide pane and a deep history limit this is a multi-gigabyte per-pane ceiling.
An output-heavy command (a build, a test run) emits enough lines to drive the
server there, and under memory pressure the server process dies — the pane
vanishes with it.

- **psmux version:** `tmux 3.3.7` / `psmux 3.3.7 (05cc5d4 2026-07-20)`
- **OS:** Windows 11, Windows PowerShell 5.1
- **Reproduction:** [`psmux-oom-repro.ps1`](./psmux-oom-repro.ps1) — psmux + built-in PowerShell only, no other dependencies

---

## Symptom

A long-running, output-heavy command inside a psmux pane (e.g. `cargo build` /
`cargo test`, or any program that prints tens of thousands of lines) causes the
backing `tmux.exe server` process's memory to climb without bound until it is
killed by the OS / allocator, at which point the pane disappears. A tool that
drives psmux programmatically and polls `capture-pane` sees the session simply
cease to exist mid-run, with no clean exit.

## Root cause

All references are to the vendored emulator crate `crates/vt100-psmux`.

**1. A cell is a fixed 44 bytes.** (`src/cell.rs`)

```rust
const CONTENT_BYTES: usize = 22;
pub struct Cell {
    contents: [u8; CONTENT_BYTES],
    len: u8,
    attrs: crate::attrs::Attrs,
}
const _: () = assert!(std::mem::size_of::<Cell>() == 44);
```

A `Cell` costs 44 bytes whether it holds a glyph or nothing.

**2. A row is always a dense, full-width vector of cells.** (`src/row.rs`)

```rust
pub struct Row { cells: Vec<crate::Cell>, wrapped: bool }
pub fn new(cols: u16) -> Self {
    Self { cells: vec![crate::Cell::new(); usize::from(cols)], wrapped: false }
}
```

The row width is not stored separately — it *is* `cells.len()`. Every row is
allocated at the full pane width even if only a few columns are ever written.

**3. Scrollback keeps those full-width rows, capped only at `history-limit`.**
(`src/grid.rs`)

```rust
pub struct Grid {
    rows: Vec<crate::row::Row>,                        // visible grid (~ pane height)
    scrollback: std::collections::VecDeque<crate::row::Row>,
    scrollback_len: usize,                             // = history-limit
    ...
}

// scroll_up(): a line that leaves the visible grid is pushed verbatim into scrollback
if self.scrollback_len > 0 && !self.scroll_region_active() {
    self.scrollback.push_back(removed);
    while self.scrollback.len() > self.scrollback_len {
        self.scrollback.pop_front();
    }
    ...
}
```

Rows enter scrollback verbatim — never trimmed to the width they actually use.

### The memory model

For a pane `cols` wide with a scrollback cap of `history_limit`, once more than
`history_limit` lines have been emitted the scrollback alone occupies:

```
bytes ≈ history_limit × cols × 44        (+ Vec/Row/VecDeque overhead)
```

A typical build/test line — say `test foo::bar ... ok`, ~40 characters — in a
500-column pane uses 40 cells and wastes 460 blank ones, each still 44 bytes.
**~90% of every stored row is padding.** The waste is entirely in the trailing
blank cells.

## Reproduction

```powershell
# Reproduce the runaway (wide pane, deep history — climbs into the gigabytes):
powershell -NoProfile -File .\psmux-oom-repro.ps1

# Control (tmux defaults — same workload, stays flat at ~16 MB):
powershell -NoProfile -File .\psmux-oom-repro.ps1 -Cols 80 -HistoryLimit 2000
```

The script starts a detached pane, floods `-Lines` plain lines into it, and
prints the psmux server's RSS as it grows. No child processes are spawned by
the workload, so the memory measured is purely scrollback.

### Measured results (psmux 3.3.7, Windows 11)

| Pane geometry | Lines emitted | Peak server RSS | Model `min(lines,hist)×cols×44` |
|---|---|---|---|
| `-x 80`  `history-limit 2000`   | 30,000  | **16 MB** (flat) | ~7 MB (trim caps it) |
| `-x 500` `history-limit 200000` | 60,000  | **1,158 MB** | ~1,259 MB |
| `-x 500` `history-limit 200000` | 120,000 | **2,304 MB** | ~2,516 MB |

Measured cost ≈ `cols × 44` bytes per emitted line (500 × 44 = 22,000 ≈ 20 KB),
matching the model within ~8%. At the full `history-limit 200000` × `cols 500`
the ceiling is **≈ 4.4 GB per pane**. The control case (narrow + shallow) stays
flat because the trim in `scroll_up` caps it at 2,000 short rows.

## Suggested fix

**Compact rows to their used width when they enter scrollback.** Scrollback
rows are write-once / read-only — nothing mutates a row after it is pushed —
so trimming the `cells` vector to the last non-blank column at the two eviction
points is safe:

- `Grid::scroll_up` — `self.scrollback.push_back(removed)` (`src/grid.rs`)
- `Grid::push_row_to_scrollback` — the alt-screen copy path, issue #88 (`src/grid.rs`)

The primitives already exist: `Row::is_blank`, `Row::truncate`, and
`Row::resize` (which already clears an orphaned wide-glyph flag when the
continuation cell is cut). For typical build output this shrinks a ~22 KB row
to ~1–2 KB — a **10–20× reduction** — dropping the per-pane ceiling from
gigabytes to the low hundreds of MB.

### What makes it non-trivial

Truncating means a scrollback row can have `cells.len() < pane_width`, and a few
read paths currently assume full width. They need to tolerate short rows (they
share the render path with the visible grid via `Grid::visible_rows`):

- `Row::write_contents_formatted` opens with `&self.cells[start]` and the
  wrap-transition branch touches `self.cells[self.cols() - 1]` — direct indexes
  that would panic on a fully-trimmed row. Route through `get()` (returns
  `Option`) or keep a minimum length. The main content loops are already safe
  (`.skip(start).take(width)`, stop at `has_contents()`).
- Pane **resize / reflow** reads scrollback rows back and re-wraps them to the
  new width; that path must re-pad a trimmed row rather than assume
  `row.cols() == pane_width`.
- **Copy-mode** selection reads by absolute column; selecting past a trimmed
  row's end must yield spaces, not panic.
- **Wide glyphs** (CJK / emoji continuations) must survive truncation — reuse
  the existing `truncate`/`resize` handling.

### Alternatives considered (and why compaction is preferred)

- **Sparse per-cell storage** (`Vec<(col, Cell)>` / RLE): touches every
  `get`/`get_mut`/index/`cols` caller, including the hot visible-grid mutation
  path that doesn't need it; high risk around wide glyphs and attribute runs.
- **Shrinking `Cell` below 44 bytes:** only a constant-factor win, breaks
  multi-codepoint grapheme clusters, and doesn't address the blank-cell waste.
- **Compressing evicted scrollback:** big memory win, but adds CPU on every
  scroll and, worse, on every `capture-pane` — a poll-heavy consumer would pay
  decompression constantly.

Compaction targets exactly the waste (trailing blank cells), leaves the
mutation-heavy visible grid untouched, and reuses primitives already in `Row`.

## Appendix: why a downstream tool hits this hard

The tool that surfaced this configures each pane with `new-session -x 500` and
`set-option history-limit 200000` (a wide pane, and 100× tmux's 2,000 default)
because it captures long agent/build transcripts. That combination sets a
~4.4 GB ceiling per pane, and a `cargo` build/test — tens of thousands of lines
over minutes — fills it. With many such panes running concurrently the machine
runs out of memory and psmux servers start dying mid-run. The narrow-and-shallow
control case never exhibits it, which is why it can look intermittent.
