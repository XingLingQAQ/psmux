# test_startup_ready_poll.ps1 — the `new-session` readiness contract.
#
# `psmux new-session` returns only once the session is genuinely usable, and it
# discovers that by polling. The poll interval used to be a flat 20ms; it now
# ramps 1ms -> 20ms (see next_ready_poll_step_ms in src/main.rs and the unit
# tests in tests-rs/test_ready_poll_backoff.rs) so a warm claim is noticed
# promptly instead of sleeping through most of the remaining wait.
#
# Polling FASTER is only safe if the predicate is unchanged, so what this suite
# pins is the contract, not a stopwatch: when `new-session -d` exits 0, the
# session must ALREADY be fully usable with no settling delay whatsoever — a
# window listed, a pane capturable, the server answering commands. It checks
# that on the warm-claim path and on the cold path, and it checks that a failed
# creation is still reported rather than raced past.
#
#   pwsh -NoProfile -File tests\test_startup_ready_poll.ps1

param([string]$Psmux = "", [int]$Iterations = 6)
$ErrorActionPreference = "Continue"
$script:Passed = 0
$script:Failed = 0
function Ok   { param($m) Write-Host "[PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Bad  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red;   $script:Failed++ }
function Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }

if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
if (-not (Test-Path $Psmux)) { Write-Host "psmux release binary not found; run cargo build --release" -ForegroundColor Red; exit 1 }
$Psmux = (Resolve-Path $Psmux).Path
# session.rs gates the server image name; a differently named copy silently
# loses the warm-claim fast path and this suite would be testing the rename.
$imgName = [IO.Path]::GetFileNameWithoutExtension($Psmux).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) { Write-Host "REFUSING: '$imgName' is not a recognised server image name" -ForegroundColor Red; exit 1 }

$NS = "rdypoll$PID"
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $NS kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 250
    Get-ChildItem "$DataDir\$($NS)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("=" * 72)
Write-Host "  NEW-SESSION READINESS CONTRACT (ramped poll)"
Write-Host ("=" * 72)
Info "binary: $Psmux"
Info "namespace: $NS"

# ---------------------------------------------------------------------------
# 1 + 2: when new-session -d returns 0, the session is usable RIGHT NOW.
# No Start-Sleep anywhere after the call: any settling the CLI still owed would
# show up immediately as an empty window list or an unusable pane.
# ---------------------------------------------------------------------------
foreach ($mode in @("warm", "cold")) {
    Cleanup
    if ($mode -eq "warm") {
        # prime the namespace's warm spare the way a real machine has it primed
        & $Psmux -L $NS new-session -d -s primer 2>&1 | Out-Null
        & $Psmux -L $NS kill-session -t primer 2>&1 | Out-Null
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.ElapsedMilliseconds -lt 10000 -and -not (Test-Path "$DataDir\$($NS)____warm__.port")) { Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 800
        $env:PSMUX_NO_WARM = $null
    } else {
        $env:PSMUX_NO_WARM = "1"
    }

    $usable = 0; $created = 0; $badRc = 0
    for ($i = 0; $i -lt $Iterations; $i++) {
        $sess = "rp$i"
        & $Psmux -L $NS new-session -d -s $sess 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $badRc++; continue }
        $created++
        # NO sleep here on purpose.
        $wins = & $Psmux -L $NS list-windows -t $sess 2>&1
        $rcW = $LASTEXITCODE
        $cap = & $Psmux -L $NS capture-pane -p -t "$($sess):0.0" 2>&1
        $rcC = $LASTEXITCODE
        if ($rcW -eq 0 -and $rcC -eq 0 -and "$wins".Trim() -and "$wins" -notmatch '^ERROR') { $usable++ }
        else { Write-Host "       iter $i unusable: list rc=$rcW cap rc=$rcC wins='$("$wins".Trim())'" -ForegroundColor DarkYellow }
        & $Psmux -L $NS kill-session -t $sess 2>&1 | Out-Null
    }
    $env:PSMUX_NO_WARM = $null

    Write-Host ""
    Write-Host "[TEST] ${mode} path: new-session -d exits 0 only when the session is already usable"
    if ($badRc -gt 0) { Bad "${mode}: $badRc/$Iterations new-session calls exited non-zero" }
    else { Ok "${mode}: all $Iterations new-session calls exited 0" }
    if ($usable -eq $created -and $created -eq $Iterations) {
        Ok "${mode}: all $created sessions listed a window and captured a pane with no settling delay"
    } else {
        Bad "${mode}: only $usable/$created sessions were usable the instant new-session returned"
    }
}

# ---------------------------------------------------------------------------
# 3: a faster poll must not turn a genuine failure into a false success. A
# session name that already exists must still be refused, not raced past.
# ---------------------------------------------------------------------------
Cleanup
& $Psmux -L $NS new-session -d -s dup 2>&1 | Out-Null
$firstRc = $LASTEXITCODE
$out = & $Psmux -L $NS new-session -d -s dup 2>&1
$dupRc = $LASTEXITCODE
Write-Host ""
Write-Host "[TEST] duplicate session name is still refused"
if ($firstRc -eq 0 -and $dupRc -ne 0) { Ok "second new-session -s dup exited $dupRc (refused)" }
else { Bad "first rc=$firstRc second rc=$dupRc out='$("$out".Trim())'" }

# ---------------------------------------------------------------------------
# 4: the readiness wait still bounds a server that never becomes usable. Point
# the client at a namespace whose session cannot start (an unspawnable shell)
# and require a non-zero exit in reasonable time rather than a hang.
# ---------------------------------------------------------------------------
Cleanup
$sw = [Diagnostics.Stopwatch]::StartNew()
$env:PSMUX_NO_WARM = "1"
& $Psmux -L $NS new-session -d -s deadshell "C:\definitely\not\a\real\shell_$PID.exe" 2>&1 | Out-Null
$deadRc = $LASTEXITCODE
$sw.Stop()
$env:PSMUX_NO_WARM = $null
Write-Host ""
Write-Host "[TEST] an unspawnable pane command still fails, and is still bounded"
if ($deadRc -ne 0) { Ok "exited $deadRc after $([math]::Round($sw.Elapsed.TotalSeconds,1))s" }
else { Bad "exited 0 for a shell that cannot exist (after $([math]::Round($sw.Elapsed.TotalSeconds,1))s)" }
if ($sw.Elapsed.TotalSeconds -lt 20) { Ok "bounded: returned in $([math]::Round($sw.Elapsed.TotalSeconds,1))s, under the 15s readiness deadline plus slack" }
else { Bad "took $([math]::Round($sw.Elapsed.TotalSeconds,1))s, past the readiness deadline" }

Cleanup
Write-Host ""
Write-Host ("=" * 72)
Write-Host ("  PASSED: {0}   FAILED: {1}" -f $script:Passed, $script:Failed)
Write-Host ("=" * 72)
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
