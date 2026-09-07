param(
  [string]$Exe = "C:\Users\godwin\.cargo\bin\psmux.exe",
  [string]$Case = "known_good",
  [int]$Iterations = 1
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference = "Continue"
$fixture = Join-Path $PSScriptRoot "i639_fixture.ps1"
$ns = "i639ns"

function Cap($sess) {
  $raw = & $Exe -L $ns capture-pane -t $sess -p 2>&1 | Out-String
  return $raw
}

for ($it = 1; $it -le $Iterations; $it++) {
  $sess = "i639_${Case}_$it"
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
  & $Exe -L $ns new-session -d -s $sess -x 60 -y 20 -- pwsh -NoProfile -NoLogo -File $fixture $Case 2>&1 | Out-Null
  Start-Sleep -Milliseconds 2500
  $out = Cap $sess
  Write-Output "=== ITER $it CASE $Case ==="
  $lines = $out -split "`r?`n"
  for ($i = 0; $i -lt [Math]::Min(12, $lines.Count); $i++) {
    $l = $lines[$i]
    if ($l.Length -eq 0) { continue }
    $cps = ($l.ToCharArray() | ForEach-Object { "U+{0:X4}" -f [int]$_ }) -join " "
    Write-Output ("L{0}: [{1}]" -f $i, $l)
    Write-Output ("   cp: {0}" -f $cps)
  }
  & $Exe -L $ns kill-session -t $sess 2>$null | Out-Null
}
