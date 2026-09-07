# Debug: run the E2E payload's "shrink" case in a pane and dump capture-pane,
# without the client capture, to find out why the grid carried no CJK.
param([string]$Exe, [string]$Case = "shrink")
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$work = Join-Path $env:TEMP "psmux_i639dbg"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$payload = Join-Path $work "i639_payload.ps1"

@'
param([string]$Case)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }
$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26
W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5
switch ($Case) {
  "shrink" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1Hzz" }
    W "$e[12;1HMARKERAFTER"
  }
  "oddcol" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;2H$cjk$cjk" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$e[2Kz" }
    W "$e[12;1HMARKERAFTER"
  }
}
Start-Sleep -Seconds 600
'@ | Set-Content -Path $payload -Encoding UTF8

$sess = "i639dbg_$Case"
& $Exe -L i639dbg kill-session -t $sess 2>$null | Out-Null
& $Exe -L i639dbg new-session -d -s $sess -x 60 -y 20 -- pwsh -NoProfile -NoLogo -File $payload $Case 2>&1 | Out-Null
Start-Sleep -Seconds 12
$grid = (& $Exe -L i639dbg capture-pane -t $sess -p 2>&1 | Out-String)
Write-Output "---- GRID for $Case ----"
Write-Output $grid.TrimEnd()
& $Exe -L i639dbg kill-session -t $sess 2>$null | Out-Null
Remove-Item $work -Recurse -Force -EA SilentlyContinue
