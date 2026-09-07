param([string]$Case = "altscreen")

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26

# Phase 0: let the outer client attach and settle.
W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5

switch ($Case) {
  "altscreen" {
    W "$e[?1049h"
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    W "$e[?1049l"
    Start-Sleep -Seconds 3
    W "$e[H$e[2J"
    W "MARKERAFTER"
  }
  "clear" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    W "$e[H$e[2J"
    W "MARKERAFTER"
  }
  "shrink" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$e[2Kzz" }
    W "$e[12;1HMARKERAFTER"
  }
}

Start-Sleep -Seconds 600
