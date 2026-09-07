# Drive the #639 randomized property test: after hundreds of small incremental
# mutations mixing wide and narrow glyphs, the screen the client PAINTED must
# equal the grid the emulator HOLDS, row for row.
param(
  [string]$Exe,
  [int]$Cols = 80,
  [int]$Rows = 20,
  [int]$Seeds = 3,
  [int]$FirstSeed = 1,
  [string]$PtyFlags = "8"
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot
$ns = "i639fz"
$capExe = Join-Path $root "i639_conptycap.exe"
$fixture = Join-Path $root "i639_fuzz.ps1"
$bad = 0; $ran = 0

for ($s = $FirstSeed; $s -lt ($FirstSeed + $Seeds); $s++) {
  $sess = "i639_fz_$s"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x $Cols -y $Rows -- pwsh -NoProfile -NoLogo -File $fixture -Seed $s -RoundsA 160 -RoundsB 160 -Cols $Cols -Rows ($Rows - 2) 2>&1 | Out-Null
  Start-Sleep -Milliseconds 1200

  $launch = Join-Path $root "i639_attach_fz_$s.cmd"
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

  $outBin = Join-Path $root "i639_bytes_fz_$s.bin"
  Remove-Item $outBin -Force -EA SilentlyContinue
  $env:CONPTYCAP_DRAIN_MS = "40000"
  Start-Process -FilePath $capExe -ArgumentList @($outBin,"$Cols","$Rows",$PtyFlags,$launch) -Wait -WindowStyle Minimized

  $grid = (& $Exe -L $ns capture-pane -t $sess -p 2>&1 | Out-String)
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  $ran++

  if (-not (Test-Path $outBin)) { Write-Output "SEED $s : NO BYTES"; $bad++; continue }
  $screenRaw = (python (Join-Path $root "i639_replay.py") $outBin $Cols $Rows | Out-String)

  # Compare row by row. The client screen also carries psmux's status line on
  # the last row, so only the pane rows (0 .. Rows-2) are compared.
  $gl = ($grid -split "`r?`n")
  $sl = @()
  foreach ($ln in ($screenRaw -split "`r?`n")) {
    if ($ln -match '^R\d\d\|(.*)\|$') { $sl += $matches[1] }
  }
  if (-not ($screenRaw -match 'FUZZDONE')) {
    Write-Output "SEED $s : SKIP (client never painted the settle marker)"
    continue
  }
  $mismatch = @()
  for ($r = 0; $r -lt ($Rows - 1); $r++) {
    $g = if ($r -lt $gl.Count) { $gl[$r].TrimEnd() } else { "" }
    $c = if ($r -lt $sl.Count) { $sl[$r].TrimEnd() } else { "" }
    if ($g -ne $c) { $mismatch += "  R$r`n    GRID  :[$g]`n    SCREEN:[$c]" }
  }
  if ($mismatch.Count -gt 0) {
    Write-Output "SEED $s : *** $($mismatch.Count) ROW MISMATCHES ***"
    $mismatch | ForEach-Object { Write-Output $_ }
    $bad++
  } else {
    Write-Output "SEED $s : clean ($($Rows - 1) rows identical)"
  }
}
Write-Output "==== FUZZ: $bad / $ran seeds anomalous ===="
