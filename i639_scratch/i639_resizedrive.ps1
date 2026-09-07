# #639 final gap: resize the OUTER terminal (the ssh window) while wide CJK
# glyphs are on screen, then compare what the client paints at the NEW size
# against the pane grid at the new size.
param(
  [string]$Exe,
  [int]$Cols = 80,
  [int]$Rows = 20,
  [int]$NewCols = 41,      # ODD on purpose: splits a wide pair at the new edge
  [int]$Iterations = 1,
  [string]$Fixture = "i639_fixture4.ps1",
  [string]$FixCase = "holdfull"
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot
$ns = "i639rs"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$capExe = Join-Path $root "i639_conptyresize.exe"
if (-not (Test-Path $capExe)) {
  & $csc -nologo -optimize "-out:$capExe" (Join-Path $root "i639_conptyresize.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $capExe)) { Write-Output "FATAL: resize host build failed"; exit 2 }
$fixture = Join-Path $root $Fixture
$bad = 0

for ($it = 1; $it -le $Iterations; $it++) {
  $sess = "i639_rs_$it"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x $Cols -y $Rows -- pwsh -NoProfile -NoLogo -File $fixture $FixCase 2>&1 | Out-Null
  Start-Sleep -Milliseconds 1200

  $launch = Join-Path $root "i639_attach_rs_$it.cmd"
  @"
@echo off
set PSMUX_SESSION=
set PSMUX_SESSION_NAME=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set NO_COLOR=
"$Exe" -L $ns attach -t $sess
"@ | Set-Content -Path $launch -Encoding ASCII

  $outBin = Join-Path $root "i639_bytes_rs_$it.bin"
  Remove-Item $outBin -Force -EA SilentlyContinue
  Remove-Item "$outBin.log" -Force -EA SilentlyContinue
  $env:CONPTYCAP_DRAIN_MS = "26000"
  $env:I639_RESIZE_AFTER_MS = "9000"     # after the CJK is painted
  $env:I639_RESIZE_COLS = "$NewCols"
  $env:I639_RESIZE_ROWS = "$Rows"
  Start-Process -FilePath $capExe -ArgumentList @($outBin,"$Cols","$Rows","8",$launch) -Wait -WindowStyle Minimized

  $grid = (& $Exe -L $ns capture-pane -t $sess -p 2>&1 | Out-String)
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null

  Write-Output "======== RESIZE ITER $it : ${Cols}x$Rows -> ${NewCols}x$Rows ========"
  if (-not (Test-Path $outBin)) { Write-Output "NO BYTES"; $bad++; continue }

  $log = Get-Content "$outBin.log" -Raw -EA SilentlyContinue
  $off = 0
  if ($log -match 'RESIZE_AT_BYTES=(\d+)') { $off = [int]$matches[1] }
  Write-Output "resize happened at byte offset $off"

  # Replay only the tail, at the NEW width: everything before the resize was
  # painted at the old width and would be misread here.
  $tail = Join-Path $root "i639_bytes_rs_$it.tail.bin"
  $all = [System.IO.File]::ReadAllBytes($outBin)
  if ($off -ge $all.Length) { Write-Output "resize offset past EOF, skipping"; continue }
  [System.IO.File]::WriteAllBytes($tail, $all[$off..($all.Length - 1)])

  $screen = (python (Join-Path $root "i639_replay.py") $tail $NewCols $Rows | Out-String)
  Write-Output "---- GRID after resize ----"
  Write-Output ($grid.TrimEnd())
  Write-Output "---- SCREEN (client tail replayed at ${NewCols}x$Rows) ----"
  Write-Output ($screen.TrimEnd())

  $isCjk = { param($ch) $c = [int]$ch; ($c -ge 0x2E80 -and $c -le 0x9FFF) }
  $g = 0; $s = 0
  foreach ($ch in $grid.ToCharArray())   { if (& $isCjk $ch) { $g++ } }
  foreach ($ch in $screen.ToCharArray()) { if (& $isCjk $ch) { $s++ } }
  Write-Output "---- CJK: GRID=$g  SCREEN=$s ----"
  if ($s -ne $g) { Write-Output "*** MISMATCH ***"; $bad++ } else { Write-Output "clean" }
}
Write-Output "==== RESIZE: $bad / $Iterations anomalous ===="
