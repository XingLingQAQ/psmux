# #639 probe: RESIZE the window while CJK is on screen, with a client attached.
# Narrowing to an odd width splits a wide pair across the new right edge.
param(
  [string]$Exe,
  [string]$Tag = "rz",
  [int]$Cols = 60,
  [int]$Rows = 20,
  [int]$Iterations = 1
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot
$ns = "i639rz"
$capExe = Join-Path $root "i639_conptycap.exe"
$fixture = Join-Path $root "i639_fixture3.ps1"

for ($it = 1; $it -le $Iterations; $it++) {
  $sess = "i639_${Tag}_$it"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x $Cols -y $Rows -- pwsh -NoProfile -NoLogo -File $fixture hold 2>&1 | Out-Null
  Start-Sleep -Milliseconds 1200

  $launch = Join-Path $root "i639_attach_rz_$it.cmd"
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

  $outBin = Join-Path $root "i639_bytes_rz_$it.bin"
  Remove-Item $outBin -Force -EA SilentlyContinue
  $env:CONPTYCAP_DRAIN_MS = "16000"
  $p = Start-Process -FilePath $capExe -ArgumentList @($outBin,"$Cols","$Rows","8",$launch) -PassThru -WindowStyle Minimized

  # let the client paint the CJK, then narrow the window under it
  Start-Sleep -Seconds 7
  & $Exe -L $ns resize-window -t $sess -x 33 -y $Rows 2>&1 | Out-Null
  Start-Sleep -Seconds 3
  & $Exe -L $ns resize-window -t $sess -x 25 -y $Rows 2>&1 | Out-Null
  Start-Sleep -Seconds 3
  $grid = (& $Exe -L $ns capture-pane -t $sess -p 2>&1 | Out-String)
  $p.WaitForExit()
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null

  Write-Output "======== RESIZE ITER $it ========"
  Write-Output "---- GRID after narrowing to 25 ----"
  Write-Output ($grid.TrimEnd())
  if (Test-Path $outBin) {
    Write-Output "---- SCREEN (client bytes replayed at ${Cols}x${Rows}) ----"
    Write-Output ((python (Join-Path $root "i639_replay.py") $outBin $Cols $Rows | Out-String).TrimEnd())
  }
}
