#!/usr/bin/env bash
# WSL / Linux counterpart of psmux-oom-repro.ps1 — does regular tmux exhibit the
# same scrollback memory blow-up as psmux under the same aggressive geometry?
#
# It configures a tmux pane exactly like the psmux repro (wide + deep history),
# floods short lines into it, and prints the tmux *server* process's RSS as it
# grows. Uses a private socket (-L) so it never touches your live tmux sessions.
#
# Deps: tmux + awk (gawk/mawk) + /proc (any Linux / WSL2). No build tools.
#
# Usage:
#   ./tmux-oom-repro.sh                         # default: cols=500 history=200000 lines=120000
#   ./tmux-oom-repro.sh 500 200000 120000       # psmux-equivalent aggressive geometry
#   ./tmux-oom-repro.sh 80 2000 120000          # tmux defaults (control)
#   TMUX_BIN=/usr/bin/tmux ./tmux-oom-repro.sh
#
# Compare against the psmux numbers: at 500 / 200000, psmux climbs into the
# gigabytes; regular tmux should stay far smaller because it stores only the
# cells a line actually uses (trailing blanks are never materialized).

set -u
TMUX_BIN=${TMUX_BIN:-tmux}
COLS=${1:-500}
HISTORY=${2:-200000}
LINES=${3:-120000}
LINEWIDTH=${4:-150}
TIMEOUT=${5:-600}

SOCK="oomrepro-$$"
SESS="oomrepro"
WORK=$(mktemp -d)
FLOOD="$WORK/flood.sh"
CONF="$WORK/tmux.conf"

# IMPORTANT: history-limit must be set BEFORE the pane is created. tmux reads it
# at pane creation, so `set-option history-limit` AFTER new-session does NOT
# apply to the existing pane (it keeps the default ~2000 and silently trims the
# flood, making tmux look artificially tiny). A startup config read via -f is
# the correct way to make the pane retain the full flood.
echo "set -g history-limit $HISTORY" > "$CONF"

# Workload: emit $LINES plain lines then a sentinel. No child processes, so the
# measured server RSS is scrollback, not process overhead.
cat > "$FLOOD" <<EOF
exec awk 'BEGIN{ s=""; for(i=0;i<$LINEWIDTH;i++) s=s "x"; for(i=0;i<$LINES;i++) print i, s; print "PSMUX_REPRO_DONE" }'
EOF

echo "tmux     : $($TMUX_BIN -V)  ($TMUX_BIN)"
echo "geometry : -x $COLS -y 50  history-limit $HISTORY (set at server start via -f)"
echo "workload : $LINES lines x $LINEWIDTH chars"

$TMUX_BIN -L "$SOCK" -f "$CONF" new-session -d -s "$SESS" -x "$COLS" -y 50 || { echo "FATAL new-session"; exit 2; }
SRVPID=$($TMUX_BIN -L "$SOCK" display-message -p '#{pid}')
echo "server   : pid=$SRVPID"

rss_mb() { awk '/^VmRSS/{printf "%d", $2/1024}' "/proc/$1/status" 2>/dev/null; }

$TMUX_BIN -L "$SOCK" send-keys -t "$SESS" "bash $FLOOD" Enter
echo "workload sent -- watching tmux server RSS:"

peak=0; start=$SECONDS; n=0; rss=0
while (( SECONDS - start < TIMEOUT )); do
  sleep 0.5; n=$((n+1))
  if [ ! -d "/proc/$SRVPID" ]; then echo "  !! tmux server pid=$SRVPID DIED after $((SECONDS-start))s"; break; fi
  rss=$(rss_mb "$SRVPID"); [ -n "$rss" ] && (( rss > peak )) && peak=$rss
  done=0
  if $TMUX_BIN -L "$SOCK" capture-pane -p -t "$SESS" -S -10000 2>/dev/null | grep -q PSMUX_REPRO_DONE; then done=1; fi
  if (( n % 10 == 0 || done )); then printf '  t=%3ds  server_rss=%6s MB   peak=%6s MB\n' $((SECONDS-start)) "${rss:-0}" "$peak"; fi
  (( done )) && break
done

retained=$($TMUX_BIN -L "$SOCK" display-message -p -t "$SESS" '#{history_size}' 2>/dev/null)
model_mb=$(( ( (LINES<HISTORY?LINES:HISTORY) * COLS * 44 ) / 1048576 ))
echo "=============================================================="
echo "RESULT   : peak tmux server RSS = ${peak} MB   (retained ${retained} history lines, cols=$COLS, history-limit=$HISTORY)"
echo "psmux-model (full-width 44B cells) would be ~${model_mb} MB at this geometry regardless of line content"

$TMUX_BIN -L "$SOCK" kill-server 2>/dev/null
rm -rf "$WORK"
