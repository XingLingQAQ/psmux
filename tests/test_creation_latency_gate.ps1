# test_creation_latency_gate.ps1 - the regression gate on how long it takes to
# get a usable pane.
#
# WHAT THIS PINS
#
# Creating a window or a split used to be bimodal: about 15ms when a spare shell
# was claimed and 470 to 630ms when the spare pool had been drained and not yet
# refilled. Measured on master (8615957), ten back to back `new-window` calls
# came out
#
#   15, 470, 15, 476, 31, 488, 15, 520, 31, 504 ms
#
# which averages to a forgettable 257ms and feels like a stutter every other
# time you press the key. An average hides that completely, so this gate asserts
# the SHAPE of the distribution: p90 and max, not the centre.
#
# WHY IT IS MEASURED THIS WAY
#
#   - "Ready" means a PROMPT IS VISIBLE in the new pane, not that the command
#     returned. `new-window` returns in well under a millisecond while the pane
#     behind it can still be blank for half a second; timing the command would
#     score the defect as perfect.
#   - Readiness also requires THE ACTIVE PANE ID TO HAVE CHANGED. A split that
#     is refused for lack of room leaves the old pane active with its prompt
#     already on screen, so a prompt match on its own would record a refusal as
#     a 16ms creation. Every sample here is proof a pane was really created.
#   - Commands and polls go over one short lived TCP connection each (~1ms round
#     trip) rather than through the CLI (~30ms of process spawn per poll), so
#     the numbers are the server's behaviour and not the client's.
#   - Splits kill the pane they just created before the next one, because a
#     30 row window has room for only three vertical splits and every later one
#     would be refused.
#
# Runs in its own `-L` namespace and kills only that namespace, so it cannot
# disturb sessions the developer is using.
param(
    # Defaults to the installed psmux on PATH. Point it at a build to compare
    # two of them. The name must stay one the server recognises as its own image
    # (psmux / pmux / tmux): session.rs gates the warm server claim on it, so a
    # differently named copy silently loses the fast path and the run would be
    # measuring the rename.
    [string]$Binary = "",
    [int]$Count = 10,
    [int]$SettleMs = 2000,
    # p90 is the assertion that matters: it says MOST creations are instant.
    [int]$P90LimitMs = 150,
    # max only catches a blow-up. The floor for one creation in a run of ten is
    # a whole shell startup, because no pool can produce a booted shell faster
    # than a shell boots, and a pwsh cold start measures 600 to 900ms on this
    # machine. A budget at 800ms flaked on exactly that; 1500ms is above the
    # floor with headroom and still far below anything pathological.
    [int]$MaxLimitMs = 1500,
    [int]$PollMs = 10,
    [string]$MetricsDir = ""
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }
function Write-Perf { param($msg) Write-Host "[PERF] $msg" -ForegroundColor Magenta }

# ── binary ────────────────────────────────────────────────────────────────
if (-not $Binary) {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if ($cmd) { $Binary = $cmd.Source }
}
if (-not $Binary) {
    foreach ($n in @("psmux.exe", "pmux.exe", "tmux.exe")) {
        $c = Join-Path $PSScriptRoot "..\target\release\$n"
        if (Test-Path $c) { $Binary = $c; break }
    }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Fail "no psmux binary found (not on PATH, nothing in target\release)"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
$Binary = (Resolve-Path $Binary).Path
$imgName = [IO.Path]::GetFileNameWithoutExtension($Binary).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) {
    Write-Fail "'$imgName' is not a recognised server image name; the warm server claim would be off and every timing here would be wrong"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
Write-Info "Using: $Binary"

$DataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR.TrimEnd('\', '/') } else { "$env:USERPROFILE\.psmux" }
if (-not $MetricsDir) { $MetricsDir = "$env:USERPROFILE\.psmux-test-data\metrics" }
# Routing env vars would retarget every command at whatever session happens to
# host the shell this suite was started from.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION = $null

$Ns = "clg$PID"
$Sess = "gate"
$PromptRe = 'PS [A-Z]:\\'

function Remove-Namespace {
    try { & $Binary -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 400
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# One authenticated round trip. Returns @{ ok; lines }: a hashtable and never a
# bare collection, because PowerShell unrolls an empty collection to $null and
# `new-window` answers with no output at all.
function Invoke-Psmux {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 20000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $false
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $Key"); $wr.Flush()
        if ($rd.ReadLine() -ne "OK") { return @{ ok = $false; lines = @() } }
        $wr.WriteLine("TARGET $Sess")
        $wr.WriteLine($Cmd)
        $wr.Flush()
        $acc = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $l = $rd.ReadLine()
            if ($null -eq $l -or $l -eq "") { break }
            $acc.Add($l)
        }
        return @{ ok = $true; lines = $acc.ToArray() }
    } catch {
        return @{ ok = $false; lines = @() }
    } finally { $tcp.Close() }
}

function Get-Text { param($r) if ($null -eq $r -or -not $r.ok) { return "" } return ($r.lines -join "`n") }

function Wait-Registered {
    param([int]$TimeoutMs = 20000)
    $pf = "$DataDir\$($Ns)__$Sess.port"
    $kf = "$DataDir\$($Ns)__$Sess.key"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            try {
                $p = [int](Get-Content $pf -Raw).Trim()
                $k = (Get-Content $kf -Raw).Trim()
                if ($p -gt 0 -and $k.Length -gt 0) { return @{ Port = $p; Key = $k } }
            } catch {}
        }
        Start-Sleep -Milliseconds 10
    }
    return $null
}

function Get-ActivePaneId {
    param([int]$Port, [string]$Key)
    (Get-Text (Invoke-Psmux $Port $Key "display-message -p '#{pane_id}'")).Trim().Trim("'")
}

function Wait-FirstPrompt {
    param([int]$Port, [string]$Key, [int]$TimeoutMs = 25000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Get-Text (Invoke-Psmux $Port $Key "capture-pane -p")) -match $PromptRe) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# Issue one creation and return ms until the NEW pane shows a prompt, or -1.
function Measure-Creation {
    param([int]$Port, [string]$Key, [string]$Cmd, [string]$OldId, [int]$TimeoutMs = 25000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Psmux $Port $Key $Cmd
    if (-not $r.ok) { return -1 }
    $msg = ($r.lines -join " ")
    if ($msg -match 'too small|no space|error|unknown command') {
        Write-Info "  creation refused: $msg"
        return -1
    }
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $id = Get-ActivePaneId $Port $Key
        if ($id -and $id -ne $OldId) {
            if ((Get-Text (Invoke-Psmux $Port $Key "capture-pane -p -t $id")) -match $PromptRe) {
                return $sw.Elapsed.TotalMilliseconds
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return -1
}

# ── the gate ──────────────────────────────────────────────────────────────
$allSamples = [ordered]@{}

function Test-Cell {
    param([string]$Label, [string]$Cmd, [switch]$KillAfter)
    Write-Test "$Label x$Count back to back after a ${SettleMs}ms settle"
    Remove-Namespace
    Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-d", "-s", $Sess -WindowStyle Hidden | Out-Null
    $inf = Wait-Registered
    if ($null -eq $inf) {
        Write-Fail "$Label - the test session never registered"
        $allSamples[$Label] = @()
        return
    }
    if (-not (Wait-FirstPrompt $inf.Port $inf.Key)) {
        Write-Fail "$Label - the test session's first pane never reached a prompt"
        $allSamples[$Label] = @()
        Remove-Namespace
        return
    }
    # Settle: let the spare pool fill AND let those shells finish starting. A
    # spare is worth nothing until its prompt is up.
    Start-Sleep -Milliseconds $SettleMs

    $t = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $old = Get-ActivePaneId $inf.Port $inf.Key
        $ms = Measure-Creation $inf.Port $inf.Key $Cmd $old
        if ($ms -ge 0) { $t += $ms } else { Write-Info "  creation $($i + 1) produced no pane" }
        if ($KillAfter) {
            # Keep room in the window: a 30 row pane allows only three vertical
            # splits, and every later one would be refused rather than slow.
            Invoke-Psmux $inf.Port $inf.Key "kill-pane" | Out-Null
            Start-Sleep -Milliseconds 120
        }
    }
    $allSamples[$Label] = @($t | ForEach-Object { [math]::Round($_, 1) })
    Remove-Namespace

    if ($t.Count -lt $Count) {
        Write-Fail "$Label - only $($t.Count) of $Count creations produced a pane"
        return
    }
    $s = @($t | Sort-Object)
    $median = $s[[int][Math]::Floor(($s.Count - 1) / 2)]
    $p90 = $s[[Math]::Min($s.Count - 1, [int][Math]::Ceiling(0.9 * $s.Count) - 1)]
    $max = $s[-1]
    $list = (($t | ForEach-Object { [int]$_ }) -join ', ')
    Write-Perf ("{0,-18} med={1,6:N0} p90={2,6:N0} max={3,6:N0} ms  [{4}]" -f $Label, $median, $p90, $max, $list)

    if ($p90 -le $P90LimitMs) {
        Write-Pass ("$Label p90 {0:N0}ms is within {1}ms" -f $p90, $P90LimitMs)
    } else {
        Write-Fail ("$Label p90 {0:N0}ms exceeds {1}ms - most creations are waiting out a shell startup  [{2}]" -f $p90, $P90LimitMs, $list)
    }
    if ($max -le $MaxLimitMs) {
        Write-Pass ("$Label max {0:N0}ms is within {1}ms" -f $max, $MaxLimitMs)
    } else {
        Write-Fail ("$Label max {0:N0}ms exceeds {1}ms  [{2}]" -f $max, $MaxLimitMs, $list)
    }
}

Write-Host ""
Write-Host ("=" * 76)
Write-Host " Creation latency gate - time to a VISIBLE PROMPT, $Count back to back"
Write-Host (" p90 budget {0}ms, max budget {1}ms" -f $P90LimitMs, $MaxLimitMs)
Write-Host ("=" * 76)

Test-Cell -Label "new-window"      -Cmd "new-window"
Test-Cell -Label "split-window -v" -Cmd "split-window -v" -KillAfter
Test-Cell -Label "split-window -h" -Cmd "split-window -h" -KillAfter

# ── samples on disk, never in the repo ────────────────────────────────────
try {
    if (-not (Test-Path $MetricsDir)) { New-Item -ItemType Directory -Force -Path $MetricsDir | Out-Null }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outFile = Join-Path $MetricsDir "creation_latency_gate-$stamp.json"
    [ordered]@{
        suite = "test_creation_latency_gate"
        binary = $Binary
        when = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        count = $Count
        settle_ms = $SettleMs
        p90_limit_ms = $P90LimitMs
        max_limit_ms = $MaxLimitMs
        poll_ms = $PollMs
        samples_ms = $allSamples
        passed = $script:TestsPassed
        failed = $script:TestsFailed
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8
    Write-Info "samples written to $outFile"
} catch {
    Write-Info "could not write metrics: $_"
}

Remove-Namespace
Write-Host ""
Write-Host ("Tests passed: {0}, failed: {1}" -f $script:TestsPassed, $script:TestsFailed) -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
