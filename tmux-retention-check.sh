#!/usr/bin/env bash
# Proves tmux actually RETAINS the flooded lines while staying at low RSS —
# using tmux's own authoritative #{history_size} counter, not a capture-pane
# line count. Run in WSL/Linux. Private socket, never touches your live tmux.
set -u
TMUX_BIN=${TMUX_BIN:-tmux}
COLS=${1:-500}
HISTORY=${2:-200000}
LINES=${3:-120000}
LINEWIDTH=${4:-150}

SOCK="ret-$$"; SESS="r"; WORK=$(mktemp -d); FLOOD="$WORK/flood.sh"; CONF="$WORK/tmux.conf"
# history-limit must be set at server start (read at pane creation); setting it
# after new-session does not apply to the existing pane. See tmux-oom-repro.sh.
echo "set -g history-limit $HISTORY" > "$CONF"
cat > "$FLOOD" <<EOF
exec awk 'BEGIN{ s=""; for(i=0;i<$LINEWIDTH;i++) s=s "x"; for(i=0;i<$LINES;i++) print i, s; print "PSMUX_REPRO_DONE" }'
EOF

echo "tmux $($TMUX_BIN -V) | geometry -x $COLS history-limit $HISTORY | flooding $LINES lines x $LINEWIDTH chars"
$TMUX_BIN -L "$SOCK" -f "$CONF" new-session -d -s "$SESS" -x "$COLS" -y 50
PID=$($TMUX_BIN -L "$SOCK" display-message -p '#{pid}')
$TMUX_BIN -L "$SOCK" send-keys -t "$SESS" "bash $FLOOD" Enter

# Wait until the sentinel lands (all lines ingested) or history stops growing.
peak=0; last=-1; stable=0
for i in $(seq 1 240); do
  sleep 0.5
  hs=$($TMUX_BIN -L "$SOCK" display-message -p -t "$SESS" '#{history_size}' 2>/dev/null)
  rss=$(awk '/^VmRSS/{printf "%d", $2/1024}' "/proc/$PID/status" 2>/dev/null)
  [ -n "$rss" ] && (( rss > peak )) && peak=$rss
  done=0
  $TMUX_BIN -L "$SOCK" capture-pane -p -t "$SESS" -S -5 2>/dev/null | grep -q PSMUX_REPRO_DONE && done=1
  if [ "$hs" = "$last" ]; then stable=$((stable+1)); else stable=0; fi
  last=$hs
  (( done )) && { echo "sentinel seen"; break; }
  (( stable >= 6 )) && { echo "history_size stable"; break; }
done

hs=$($TMUX_BIN -L "$SOCK" display-message -p -t "$SESS" '#{history_size}')
rss=$(awk '/^VmRSS/{printf "%d", $2/1024}' "/proc/$PID/status")
echo "RESULT: history_size=$hs lines retained | current RSS=${rss} MB | peak RSS=${peak} MB"
bytes_per_line=$(( hs > 0 ? (peak*1048576)/hs : 0 ))
echo "        ~${bytes_per_line} bytes/retained-line (psmux stores cols*44 = $((COLS*44)) bytes/line regardless of content)"
$TMUX_BIN -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"
