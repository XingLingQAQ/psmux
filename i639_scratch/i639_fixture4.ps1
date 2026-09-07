param([string]$Case = "holdfull")
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }
$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26
W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5
switch ($Case) {
  "holdfull" {
    # 40 wide glyphs = 80 columns, exactly the terminal width
    $long = ""
    for ($k = 0; $k -lt 6; $k++) { $long += $cjk }              # 36 glyphs = 72 cols
    $long += [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5  # +8 = 80 cols
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$long" }
    W "$e[12;1HMARKERAFTER"
  }
  "holdodd" {
    # start at column 2 so every pair straddles an even boundary
    $long = ""
    for ($k = 0; $k -lt 6; $k++) { $long += $cjk }
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;2H$long" }
    W "$e[12;1HMARKERAFTER"
  }
}
Start-Sleep -Seconds 600
