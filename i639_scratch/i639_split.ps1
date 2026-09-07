# #639 probe: narrow a pane that is FULL of CJK by splitting it, with a client
# attached, then widen it again by killing the new pane. The outer terminal size
# never changes, so the replay width stays valid.
param(
  [string]$Exe,
  [string]$Tag = "sp",
  [int]$Cols = 80,
  [int]$Rows = 20,
  [int]$Iterations = 1,
  [string]$Fixture = "i639_fixture3.ps1",
  [string]$FixCase = "hold"
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot
$ns = "i639sp"
$capExe = Join-Path $root "i639_conptycap.exe"
$fixture = Join-Path $root $Fixture
$anom = 0

for ($it = 1; $it -le $Iterations; $it++) {
  $sess = "i639_${Tag}_$it"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x $Cols -y $Rows -- pwsh -NoProfile -NoLogo -File $fixture $FixCase 2>&1 | Out-Null
  Start-Sleep -Milliseconds 1200

  $launch = Join-Path $root "i639_attach_sp_$it.cmd"
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

  $outBin = Join-Path $root "i639_bytes_sp_$it.bin"
  Remove-Item $outBin -Force -EA SilentlyContinue
  $env:CONPTYCAP_DRAIN_MS = "18000"
  $p = Start-Process -FilePath $capExe -ArgumentList @($outBin,"$Cols","$Rows","8",$launch) -PassThru -WindowStyle Minimized

  Start-Sleep -Seconds 7          # CJK painted full width
  & $Exe -L $ns split-window -h -t $sess 2>&1 | Out-Null   # narrow it
  Start-Sleep -Seconds 4
  $gridNarrow = (& $Exe -L $ns capture-pane -t "$sess.0" -p 2>&1 | Out-String)
  $p.WaitForExit()
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null

  Write-Output "======== SPLIT ITER $it ========"
  Write-Output "---- GRID of pane 0 after narrowing ----"
  Write-Output ($gridNarrow.TrimEnd())
  if (Test-Path $outBin) {
    $screen = (python (Join-Path $root "i639_replay.py") $outBin $Cols $Rows | Out-String)
    Write-Output "---- SCREEN (client bytes replayed at ${Cols}x${Rows}) ----"
    Write-Output ($screen.TrimEnd())
    # count CJK on the LEFT half of the painted screen vs the pane grid
    $isCjk = { param($ch) $c = [int]$ch; ($c -ge 0x2E80 -and $c -le 0x9FFF) }
    $g = 0; $s = 0
    foreach ($ch in $gridNarrow.ToCharArray()) { if (& $isCjk $ch) { $g++ } }
    foreach ($ch in $screen.ToCharArray())     { if (& $isCjk $ch) { $s++ } }
    Write-Output "---- CJK: GRID(pane0)=$g  SCREEN(whole)=$s ----"
    if ($s -ne $g) { Write-Output "*** MISMATCH ***"; $anom++ } else { Write-Output "clean" }
  }
}
Write-Output "==== SPLIT: $anom / $Iterations anomalous ===="
