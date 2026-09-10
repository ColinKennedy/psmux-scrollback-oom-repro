# Scrollback stores every line as a full-width row → psmux server memory grows to gigabytes and the pane dies

## Summary

The psmux server keeps each scrollback line as a **dense, full-pane-width**
`Vec<Cell>` (44 bytes per cell) regardless of how few characters the line
actually contains. Resident memory therefore grows by `cols × 44` bytes for
**every line that scrolls into history**, capped only at `history-limit`. With a
wide pane and a deep history limit this is a multi-gigabyte per-pane ceiling. An
output-heavy command (a build, a test run, anything that prints tens of
thousands of lines) drives the server there until it is killed under memory
pressure — and the pane vanishes with it.

Trailing blank cells are the entire waste: a 40-character line in a 500-column
pane stores 40 used cells and 460 empty ones, each still 44 bytes (~90% padding).

## Environment

- **psmux:** `tmux 3.3.7` / `psmux 3.3.7 (05cc5d4 2026-07-20)`
- **OS:** Windows 11
- **Shell driving it:** Windows PowerShell 5.1

## Steps to reproduce

A self-contained reproduction script (psmux + built-in PowerShell only, no other
dependencies) is included as [`psmux-oom-repro.ps1`](./psmux-oom-repro.ps1). It
opens a detached pane, floods plain lines into it, and prints the psmux server
process's resident memory (RSS) as it grows. The workload spawns no child
processes, so the memory measured is purely scrollback.

```powershell
# 1) Reproduce: wide pane + deep history (climbs into the gigabytes)
powershell -NoProfile -File .\psmux-oom-repro.ps1 -Cols 500 -HistoryLimit 200000 -Lines 120000

# 2) Control: tmux defaults, same workload (stays flat at ~16 MB)
powershell -NoProfile -File .\psmux-oom-repro.ps1 -Cols 80 -HistoryLimit 2000 -Lines 30000
```

If you'd rather do it by hand, the essential recipe is:

```powershell
$env:PSMUX_DATA_DIR = "$env:TEMP\psmux-repro"        # keep it off your live sessions
tmux new-session -d -s repro -c $env:TEMP -x 500 -y 50
tmux set-option -t repro history-limit 200000
# now send a command that prints ~100k+ lines into the pane, e.g. a big build,
# or:  tmux send-keys -t repro "for (`$i=0;`$i -lt 120000;`$i++){ `"`$i `" + ('x'*150) }" Enter
# watch the `tmux.exe server -s repro ...` process's memory in Task Manager
```

## Expected vs. actual

- **Expected:** scrollback memory proportional to the actual text retained;
  bounded and modest for a `history-limit` of a few thousand lines.
- **Actual:** memory ≈ `history_limit × cols × 44` bytes regardless of line
  content — e.g. **~4.4 GB** at `-x 500` + `history-limit 200000`. The server
  eventually dies under memory pressure and the pane disappears mid-command.

## Evidence (measured with the script above)

| Pane geometry | Lines emitted | Peak server RSS | Model `min(lines,hist)×cols×44` |
|---|---|---|---|
| `-x 80`  `history-limit 2000`   | 30,000  | **16 MB** (flat) | ~7 MB (trim caps it) |
| `-x 500` `history-limit 200000` | 60,000  | **1,158 MB** | ~1,259 MB |
| `-x 500` `history-limit 200000` | 120,000 | **2,304 MB** | ~2,516 MB |

Measured cost ≈ `cols × 44` bytes per emitted line (500 × 44 = 22,000 ≈ 20 KB),
matching the model within ~8%. A separate unbounded run reached **943 MB RSS /
5.1 GB virtual within 20 seconds** at the wide+deep geometry. The narrow+shallow
control stays flat because the scrollback trim caps it at 2,000 short rows.

## Root cause

References are to the vendored emulator crate `crates/vt100-psmux`.

**1. A cell is a fixed 44 bytes** (`src/cell.rs`):

```rust
const CONTENT_BYTES: usize = 22;
pub struct Cell {
    contents: [u8; CONTENT_BYTES],
    len: u8,
    attrs: crate::attrs::Attrs,
}
const _: () = assert!(std::mem::size_of::<Cell>() == 44);
```

**2. A row is always a dense, full-width vector of cells** (`src/row.rs`) — the
width is not stored separately, it *is* `cells.len()`:

```rust
pub struct Row { cells: Vec<crate::Cell>, wrapped: bool }
pub fn new(cols: u16) -> Self {
    Self { cells: vec![crate::Cell::new(); usize::from(cols)], wrapped: false }
}
```

**3. Scrollback keeps those full-width rows verbatim, capped only at
`history-limit`** (`src/grid.rs`):

```rust
pub struct Grid {
    rows: Vec<crate::row::Row>,                        // visible grid (~ pane height)
    scrollback: std::collections::VecDeque<crate::row::Row>,
    scrollback_len: usize,                             // = history-limit
    ...
}

// scroll_up(): a line leaving the visible grid is pushed verbatim into scrollback
if self.scrollback_len > 0 && !self.scroll_region_active() {
    self.scrollback.push_back(removed);               // <- full-width row, never trimmed
    while self.scrollback.len() > self.scrollback_len {
        self.scrollback.pop_front();
    }
    ...
}
```

So the scrollback footprint is `history_limit × cols × 44` bytes (plus Vec/Row/
VecDeque overhead), independent of how much text the lines actually hold.

## Suggested fix: compact rows to used width on eviction into scrollback

Scrollback rows are write-once / read-only — nothing mutates a row after it is
pushed — so trimming the `cells` vector to the last non-blank column at the two
eviction points is safe:

- `Grid::scroll_up` — `self.scrollback.push_back(removed)` (`src/grid.rs`)
- `Grid::push_row_to_scrollback` — the alt-screen copy path, issue #88 (`src/grid.rs`)

The primitives already exist: `Row::is_blank`, `Row::truncate`, and
`Row::resize` (which already clears an orphaned wide-glyph flag when a
continuation cell is cut). For typical build/test output this shrinks a ~22 KB
row to ~1–2 KB — a **10–20× reduction**.

### What makes it non-trivial

Truncating means a scrollback row can have `cells.len() < pane_width`, and a few
read paths currently assume full width (they share the render path with the
visible grid via `Grid::visible_rows`):

- `Row::write_contents_formatted` opens with `&self.cells[start]` and its
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

### Alternatives considered

- **Sparse per-cell storage** (`Vec<(col, Cell)>` / RLE): touches every
  `get`/`get_mut`/index/`cols` caller including the hot visible-grid mutation
  path that doesn't need it; high risk around wide glyphs and attribute runs.
- **Shrinking `Cell` below 44 bytes:** only a constant-factor win, breaks
  multi-codepoint grapheme clusters, doesn't address the blank-cell waste.
- **Compressing evicted scrollback:** big memory win but adds CPU on every
  scroll and on every `capture-pane` — costly for poll-heavy automated consumers.

Compaction targets exactly the waste (trailing blank cells), leaves the
mutation-heavy visible grid untouched, and reuses primitives already in `Row`.

## Why this matters in practice

We hit this driving psmux programmatically with `new-session -x 500` and
`set-option history-limit 200000` (a wide pane and a deep transcript, to capture
long build/agent output). A `cargo` build/test — tens of thousands of lines over
minutes — fills the scrollback and the server's memory approaches the ~4.4 GB
ceiling; with several such panes running concurrently the machine runs out of
memory and psmux servers start dying mid-run. It looks intermittent because it
only bites output-heavy, long-running panes or when there are a few dozen panes.
