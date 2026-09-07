# Drive one #639 candidate case end to end and DIFF the two layers:
#   GRID   = what psmux's emulator thinks the pane holds (capture-pane -p)
#   SCREEN = what the attached client actually painted, as interpreted by an
#            INDEPENDENT reference terminal (i639_replay.py)
# A ghost is: a CJK codepoint present in SCREEN but absent from GRID.
param(
  [string]$Exe,
  [string]$Case = "cufskip",
  [string]$Tag  = "base",
  [int]$Cols = 60,
  [int]$Rows = 20,
  [int]$Iterations = 1,
  [int]$DrainMs = 20000,
  [string]$Fixture = "i639_fixture3.ps1",
  [switch]$AttachLate    # draw first, attach after: probes the FULL repaint path
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot
$repoTests = Join-Path (Split-Path -Parent $root) "tests"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$capExe = Join-Path $root "i639_conptycap.exe"
if (-not (Test-Path $capExe)) {
  & $csc -nologo -optimize "-out:$capExe" (Join-Path $repoTests "conptycap.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $capExe)) { Write-Output "FATAL: conptycap build failed"; exit 2 }

$ns = "i639bn"
$fixture = Join-Path $root $Fixture
$ghosts = 0

for ($it = 1; $it -le $Iterations; $it++) {
  $sess = "i639_${Tag}_${Case}_$it"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x $Cols -y $Rows -- pwsh -NoProfile -NoLogo -File $fixture $Case 2>&1 | Out-Null

  if ($AttachLate) { Start-Sleep -Seconds 9 } else { Start-Sleep -Milliseconds 1200 }

  $launch = Join-Path $root "i639_attach_$Tag`_$Case`_$it.cmd"
  @"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set NO_COLOR=
"$Exe" -L $ns attach -t $sess
"@ | Set-Content -Path $launch -Encoding ASCII

  $outBin = Join-Path $root "i639_bytes_$Tag`_$Case`_$it.bin"
  Remove-Item $outBin -Force -EA SilentlyContinue
  $env:CONPTYCAP_DRAIN_MS = "$DrainMs"
  Start-Process -FilePath $capExe -ArgumentList @($outBin,"$Cols","$Rows","8",$launch) -Wait -WindowStyle Minimized

  # GRID: the emulator's own view, taken after the client is gone.
  $grid = (& $Exe -L $ns capture-pane -t $sess -p 2>&1 | Out-String)
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null

  Write-Output "======== CASE $Case  ITER $it  (${Cols}x${Rows}) ========"
  if (-not (Test-Path $outBin)) { Write-Output "NO CLIENT BYTES CAPTURED"; continue }

  $screen = (python (Join-Path $root "i639_replay.py") $outBin $Cols $Rows | Out-String)

  Write-Output "---- GRID (capture-pane) ----"
  Write-Output ($grid.TrimEnd())
  Write-Output "---- SCREEN (client bytes replayed) ----"
  Write-Output ($screen.TrimEnd())

  # Ghost detection: CJK on the painted SCREEN that the GRID does not have.
  $isCjk = { param($ch) $c = [int]$ch; ($c -ge 0x2E80 -and $c -le 0x9FFF) -or ($c -ge 0xAC00 -and $c -le 0xD7AF) -or ($c -ge 0xFF01 -and $c -le 0xFF60) }
  $gridCjk = 0; $screenCjk = 0
  foreach ($ch in $grid.ToCharArray())   { if (& $isCjk $ch) { $gridCjk++ } }
  foreach ($ch in $screen.ToCharArray()) { if (& $isCjk $ch) { $screenCjk++ } }
  Write-Output "---- CJK count: GRID=$gridCjk  SCREEN=$screenCjk ----"
  if ($screenCjk -gt $gridCjk) {
    Write-Output "*** GHOST: screen shows $($screenCjk - $gridCjk) CJK glyphs the grid does not have ***"
    $ghosts++
  } elseif ($screenCjk -lt $gridCjk) {
    Write-Output "*** MISSING: screen is short $($gridCjk - $screenCjk) CJK glyphs the grid has ***"
    $ghosts++
  } else {
    Write-Output "clean"
  }
}
Write-Output "==== CASE $Case : $ghosts / $Iterations iterations anomalous ===="
