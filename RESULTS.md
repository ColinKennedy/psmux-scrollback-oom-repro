# Raw measurements

Environment: Windows 11, Windows PowerShell 5.1, psmux `tmux 3.3.7` /
`psmux 3.3.7 (05cc5d4 2026-07-20)`. Each run via
[`psmux-oom-repro.ps1`](./psmux-oom-repro.ps1) in a private `PSMUX_DATA_DIR`.
The workload spawns no child processes, so RSS reflects scrollback only.

## Control — tmux defaults (narrow, shallow)

`-Cols 80 -HistoryLimit 2000 -Lines 30000`

```
geometry : -x 80 -y 50  history-limit 2000
workload : 30000 lines x 150 chars
  t=  6s  server_rss=    16 MB   peak=    16 MB
  t= 13s  server_rss=    16 MB   peak=    16 MB
  t= 18s  server_rss=    16 MB   peak=    16 MB
RESULT   : peak psmux server RSS = 16 MB   (30000 lines, cols=80, history-limit=2000)
```

Flat: the `scroll_up` trim caps scrollback at 2,000 short (80-col) rows.

## ralphus geometry (wide, deep) — 60k lines

`-Cols 500 -HistoryLimit 200000 -Lines 60000`

```
geometry : -x 500 -y 50  history-limit 200000
workload : 60000 lines x 150 chars
  t=  8s  server_rss=   212 MB   peak=   212 MB
  t= 18s  server_rss=   583 MB   peak=   583 MB
  t= 28s  server_rss=   945 MB   peak=   945 MB
  t= 34s  server_rss=  1158 MB   peak=  1158 MB
RESULT   : peak psmux server RSS = 1158 MB   (60000 lines, cols=500, history-limit=200000)
model    : min(lines, history_limit) * cols * 44 bytes = ~1259 MB
```

## ralphus geometry (wide, deep) — 120k lines

`-Cols 500 -HistoryLimit 200000 -Lines 120000`

```
  t=  8s  server_rss=   236 MB
  t= 20s  server_rss=   660 MB
  t= 33s  server_rss=  1071 MB
  t= 46s  server_rss=  1480 MB
  t= 58s  server_rss=  1882 MB
  t= 71s  server_rss=  2304 MB
RESULT   : peak psmux server RSS = 2304 MB   (120000 lines, cols=500, history-limit=200000)
```

A separate unbounded run reached **943 MB RSS / 5.1 GB virtual within 20
seconds** of flooding at this geometry.

## Summary

| Geometry | Lines | Peak RSS | Model | Per-line |
|---|---|---|---|---|
| `-x 80` hist 2000 | 30,000 | 16 MB | ~7 MB | (trimmed) |
| `-x 500` hist 200000 | 60,000 | 1,158 MB | ~1,259 MB | ~20 KB |
| `-x 500` hist 200000 | 120,000 | 2,304 MB | ~2,516 MB | ~20 KB |

Per-line cost ≈ `cols × 44` bytes (500 × 44 = 22,000 ≈ 20 KB), matching the
model within ~8%. Full-cap ceiling at `-x 500` × `history-limit 200000` ≈
**4.4 GB per pane**.
