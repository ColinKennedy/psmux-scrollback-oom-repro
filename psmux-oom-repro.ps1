# Minimal reproduction: the psmux server's memory grows ~linearly with the
# number of output lines a pane produces, at cols * 44 bytes per line, capped
# only at `history-limit`. With a wide pane and a deep history limit this is a
# multi-gigabyte per-pane ceiling, and an output-heavy command (a build, a test
# run) drives the server there until it is killed by memory pressure -- taking
# the pane with it.
#
# Dependencies: psmux (https://github.com/psmux/psmux) + Windows PowerShell 5.1
# (built in). Nothing else -- no build tools, no downstream project.
#
# The harness sets up a detached pane, floods plain lines into it, and prints
# the psmux server process's resident set size (RSS) as it climbs.
#
# Usage (from this folder):
#   powershell -NoProfile -File .\psmux-oom-repro.ps1                       # default: cols=500 hist=200000 lines=120000
#   powershell -NoProfile -File .\psmux-oom-repro.ps1 -Lines 60000          # ~1.2 GB
#   powershell -NoProfile -File .\psmux-oom-repro.ps1 -Cols 80 -HistoryLimit 2000   # tmux defaults -> stays ~16 MB
#   powershell -NoProfile -File .\psmux-oom-repro.ps1 -Tmux C:\path\to\tmux.exe
#
# The key comparison: run it once with the default (wide + deep) geometry and
# once with -Cols 80 -HistoryLimit 2000. Same number of lines; the first climbs
# into the gigabytes, the second stays flat. That contrast is the bug.

param(
    # psmux binary. psmux installs a `tmux` shim, so the PATH default usually
    # works; override if you want a specific build.
    [string]$Tmux = "tmux",
    [int]$Lines = 120000,          # lines to flood into the pane
    [int]$LineWidth = 150,         # chars per line (content length is NOT what drives cost)
    [int]$Cols = 500,              # pane width; the per-line cost is cols * 44 bytes
    [int]$Rows = 50,               # pane height
    [int]$HistoryLimit = 200000,   # scrollback cap; the per-pane ceiling is HistoryLimit * Cols * 44
    [int]$TimeoutSec = 600,
    [string]$WorkDir = "$env:TEMP\psmux-oom-repro"
)

$ErrorActionPreference = 'Continue'
$runId  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $WorkDir "run-$runId"
New-Item -ItemType Directory -Force $runDir | Out-Null

# Private data dir so this never touches any live psmux session you have open.
$env:PSMUX_DATA_DIR = Join-Path $runDir 'psmux-data'
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null

function Log([string]$m) { "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $m }

# Invoke tmux/psmux via cmd so native stderr doesn't wrap into PowerShell
# ErrorRecords (a Windows PowerShell 5.1 quirk). Sets $script:TmuxExit.
function TmuxCmd([string]$a) { $o = cmd /c "`"$Tmux`" $a 2>nul"; $script:TmuxExit = $LASTEXITCODE; return $o }

# Pane workload: emit $Lines plain lines, then a sentinel. No child processes,
# so the memory measured is purely scrollback -- not process overhead.
$workload = Join-Path $runDir 'flood.ps1'
@"
`$line = 'x' * $LineWidth
for (`$i = 0; `$i -lt $Lines; `$i++) { "`$i `$line" }
"PSMUX_REPRO_DONE"
"@ | Set-Content -Path $workload -Encoding ascii

$session = "oom-repro-$runId"
Log "psmux    : $Tmux"
Log ("version  : " + (TmuxCmd '-V'))
Log "geometry : -x $Cols -y $Rows  history-limit $HistoryLimit"
Log "workload : $Lines lines x $LineWidth chars"
Log "data dir : $env:PSMUX_DATA_DIR"

TmuxCmd "new-session -d -s $session -c `"$runDir`" -x $Cols -y $Rows" | Out-Null
if ($script:TmuxExit -ne 0) { Log "FATAL new-session exit=$script:TmuxExit"; exit 2 }
TmuxCmd "set-option -t $session remain-on-exit on" | Out-Null
TmuxCmd "set-option -t $session history-limit $HistoryLimit" | Out-Null

Start-Sleep -Milliseconds 500
$srvPid = $null
for ($t = 0; $t -lt 10 -and -not $srvPid; $t++) {
    $c = Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" |
         Where-Object { $_.CommandLine -match [regex]::Escape("-s $session") }
    if ($c) { $srvPid = $c.ProcessId } else { Start-Sleep -Milliseconds 300 }
}
Log "server   : pid=$srvPid"

TmuxCmd "send-keys -t $session `"powershell -NoProfile -ExecutionPolicy Bypass -File \`"$workload\`"`" Enter" | Out-Null
Log "workload sent -- watching psmux server RSS (Ctrl-C to stop early):"

$peak = 0; $start = Get-Date; $n = 0; $done = $false; $rss = 0
while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Milliseconds 500
    $n++
    $srv = if ($srvPid) { Get-Process -Id $srvPid -ErrorAction SilentlyContinue } else { $null }
    if ($srvPid -and -not $srv) { Log ("!! psmux server pid=$srvPid DIED (pane lost) after {0}s" -f [int]((Get-Date)-$start).TotalSeconds); break }
    if ($srv) { $rss = [int]($srv.WorkingSet64/1MB); if ($rss -gt $peak) { $peak = $rss } }
    $pane = TmuxCmd "capture-pane -p -t $session -S -10000"
    if ($script:TmuxExit -eq 0 -and $pane -match 'PSMUX_REPRO_DONE') { $done = $true }
    if ($n % 10 -eq 0 -or $done) { Log ("  t={0,3}s  server_rss={1,6} MB   peak={2,6} MB" -f [int]((Get-Date)-$start).TotalSeconds, $rss, $peak) }
    if ($done) { break }
}

$capBytes = [int64]([math]::Min($Lines, $HistoryLimit)) * $Cols * 44
Log "=============================================================="
Log ("RESULT   : peak psmux server RSS = $peak MB   ($Lines lines, cols=$Cols, history-limit=$HistoryLimit)")
Log ("model    : min(lines, history_limit) * cols * 44 bytes = ~{0} MB" -f [int]($capBytes / 1MB))

TmuxCmd "kill-session -t $session" | Out-Null
Start-Sleep -Milliseconds 300
if ($srvPid) { Stop-Process -Id $srvPid -Force -ErrorAction SilentlyContinue }
Log "cleaned up ($runDir)"
