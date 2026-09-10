# An idle attached client must not talk to its server in a loop.
#
# WHY THIS TEST EXISTS
# --------------------
# The event driven input path replaced several poll intervals with wakes. One of
# those wakes fired on every line the client read off its socket, including the
# server's "NC" reply, which means "nothing has changed". That is self
# sustaining: the NC wakes the client's input wait, the loop goes round and sends
# another dump-state, the server answers NC, and that NC wakes the loop again. A
# request/reply spin at TCP round-trip rate between two processes that both have
# nothing to do, costing up to 92% of a core across the pair.
#
# It shipped. Three separate CPU sampling runs failed to catch it, because this
# machine runs other work and the innocent build sampled as high as 13% of a
# core while the broken one sometimes sampled at 1%. The bug is bistable: it only
# latches when the client's refresh gate lets a request through immediately after
# an NC, so a handful of clean samples proves nothing.
#
# Counting events instead of sampling CPU makes it deterministic and immune to
# whatever else the machine is doing. Measured over a 10s idle window with a
# silent pane, client socket reads per second:
#
#   before the wake was added       0.1 to 192
#   with the wake firing on NC      3332 to 8660
#   with the NC gate               0.1 to 189
#
# The two populations are separated by more than an order of magnitude, so the
# threshold below is nowhere near either one.
#
# WHAT "IDLE" MEANS HERE
# ----------------------
# The pane runs tests/echo_load_child.cs with no filler output, so the pane
# produces nothing, and nothing is typed. Every line crossing the socket in the
# measurement window is therefore the client and server talking among
# themselves. A healthy session still polls at its refresh cadence, which is why
# the threshold is a few hundred per second and not zero.

param(
    [string]$Binary = "",
    [int]$Secs = 10,
    # Generous on purpose: a healthy client was measured up to 192 lines/sec and
    # the spin starts at 3332. Anything in between is already a bug worth
    # looking at, and this will not fire on cadence noise.
    [int]$MaxLinesPerSec = 600
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

if (-not $Binary) {
    $cmd = Get-Command psmux -EA SilentlyContinue
    if (-not $cmd) { Write-Fail "psmux not found on PATH and no -Binary given"; exit 1 }
    $Binary = $cmd.Source
}
if (-not (Test-Path $Binary)) { Write-Fail "binary not found: $Binary"; exit 1 }
Write-Info "binary under test: $Binary"

foreach ($v in @('PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_SOCKET','PSMUX_PANE_ID','PSMUX_PTY_TRACE','PSMUX_NO_FRAME_WAKE')) {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}

$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "target\release"
New-Item -ItemType Directory -Force -Path $build | Out-Null
$EchoChild = Join-Path $build "echo_load_child.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { Write-Fail "csc.exe not found at $csc"; exit 1 }
$src = Join-Path $PSScriptRoot "echo_load_child.cs"
if ((-not (Test-Path $EchoChild)) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $EchoChild).LastWriteTime)) {
    & $csc /nologo /optimize "/out:$EchoChild" $src | Out-Null
}
if (-not (Test-Path $EchoChild)) { Write-Fail "could not build echo_load_child.exe"; exit 1 }

$work = Join-Path $env:TEMP "psmux_idle_traffic"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$tracePrefix = Join-Path $work "trace_$PID"
Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue

$ns = "idletraf$PID"
$exeName = [IO.Path]::GetFileName($Binary)
function OwnPids { @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -EA SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $Binary } | Select-Object -ExpandProperty ProcessId) }
$before = OwnPids

# Launch through a .cmd so PSMUX_PTY_TRACE reaches both the client and the
# server it spawns, and so this shell's own session routing cannot leak in.
$launcher = Join-Path $work "launch_$PID.cmd"
Set-Content -Path $launcher -Encoding ASCII -Value @(
    "@echo off",
    "set PSMUX_SESSION=",
    "set PSMUX_SESSION_NAME=",
    "set PSMUX_PTY_TRACE=$tracePrefix",
    "`"$Binary`" -L $ns new-session -s idle `"$EchoChild`""
)
$client = Start-Process -FilePath $launcher -PassThru

$deadline = (Get-Date).AddSeconds(25)
$up = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if ((& $Binary -L $ns ls 2>&1 | Out-String) -match 'idle:') { $up = $true; break }
}

$lines = -1
if ($up) {
    Start-Sleep -Seconds 5    # let startup traffic finish before the window opens

    # Record each trace file's size so only the measurement window is counted.
    $sizes0 = @{}
    Get-ChildItem "$tracePrefix.*" -EA SilentlyContinue | ForEach-Object { $sizes0[$_.Name] = $_.Length }
    $w = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Secs
    $w.Stop()

    $c = 0
    Get-ChildItem "$tracePrefix.*" -EA SilentlyContinue | ForEach-Object {
        $start = if ($sizes0.ContainsKey($_.Name)) { $sizes0[$_.Name] } else { 0 }
        # Share write access: both psmux processes still hold these files open.
        $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($start, 'Begin') | Out-Null
            $sr = New-Object IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $ln = $sr.ReadLine()
                if (-not $ln -or $ln.StartsWith('#')) { continue }
                # Stage 'c' is "the client's socket reader read a whole line".
                if (($ln -split ' ')[1] -eq 'c') { $c++ }
            }
        } finally { $fs.Close() }
    }
    $lines = [math]::Round($c / $w.Elapsed.TotalSeconds, 1)
    Write-Info ("idle window {0:N1}s, {1} client socket reads, {2} per second" -f $w.Elapsed.TotalSeconds, $c, $lines)
} else {
    Write-Fail "the attached session never came up, so idle traffic was not measured"
}

# Teardown
& $Binary -L $ns kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
try { if (-not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue } } catch {}
foreach ($p in (OwnPids)) { if ($before -notcontains $p) { try { Stop-Process -Id $p -Force -EA SilentlyContinue } catch {} } }
Remove-Item $launcher -Force -EA SilentlyContinue
Remove-Item "$tracePrefix.*" -Force -EA SilentlyContinue

if ($lines -ge 0) {
    if ($lines -lt $MaxLinesPerSec) {
        Write-Pass ("an idle attached client reads {0} socket lines/sec, under the {1}/sec ceiling" -f $lines, $MaxLinesPerSec)
    } else {
        Write-Fail ("an idle attached client reads {0} socket lines/sec, over the {1}/sec ceiling - the client and server are in a request/reply loop with nothing to say; check what wakes the client's input wait" -f $lines, $MaxLinesPerSec)
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
