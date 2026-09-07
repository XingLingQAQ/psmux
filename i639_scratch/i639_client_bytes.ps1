param(
  [string]$Exe = "C:\Users\godwin\.cargo\bin\psmux.exe",
  [string]$Case = "altscreen",
  [string]$Tag  = "base"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$scratch  = $PSScriptRoot
$repoTests = "C:\Users\godwin\Documents\workspace\psmux\.claude\worktrees\agent-a6b74dd9d56cbb991\tests"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$capExe = Join-Path $scratch "i639_conptycap.exe"
if (-not (Test-Path $capExe)) {
  & $csc -nologo -optimize "-out:$capExe" (Join-Path $repoTests "conptycap.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $capExe)) { Write-Output "FATAL: could not build conptycap"; exit 2 }

$ns   = "i639bn"
$sess = "i639_${Tag}_${Case}"
$fixture = Join-Path $scratch "i639_fixture2.ps1"

& $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
& $Exe -L $ns new-session -d -s $sess -x 60 -y 20 -- pwsh -NoProfile -NoLogo -File $fixture $Case 2>&1 | Out-Null
Start-Sleep -Milliseconds 1200

$launch = Join-Path $scratch "i639_attach_$Tag.cmd"
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

$outBin = Join-Path $scratch "i639_client_$Tag`_$Case.bin"
Remove-Item $outBin -Force -EA SilentlyContinue
$env:CONPTYCAP_DRAIN_MS = "20000"
Start-Process -FilePath $capExe -ArgumentList @($outBin,"60","20","8",$launch) -Wait -WindowStyle Minimized

& $Exe -L $ns kill-session -t $sess 2>$null | Out-Null

if (Test-Path $outBin) {
  $bytes = [System.IO.File]::ReadAllBytes($outBin)
  Write-Output "WROTE $outBin  ($($bytes.Length) bytes)"
} else {
  Write-Output "NO OUTPUT"
}
