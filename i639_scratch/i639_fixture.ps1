param([string]$Case = "known_good")

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
$W = { param($s) [Console]::Out.Write($s); [Console]::Out.Flush() }

# CJK text: 6 wide glyphs = 12 columns
$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26

switch ($Case) {
  "known_good" {
    & $W "$e[H$e[2J"
    & $W $cjk
  }
  "overwrite_short" {
    # print CJK on row 1, then home + short ASCII (2 cols) over the first wide glyph
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[H"
    & $W "ab"
  }
  "overwrite_odd" {
    # overwrite only the LEFT half of a wide glyph (1 ascii char)
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[H"
    & $W "X"
  }
  "erase_2j" {
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[2J$e[H"
    & $W "AFTER"
  }
  "erase_el" {
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[H$e[K"
    & $W "AFTER"
  }
  "erase_el_mid" {
    # move into the MIDDLE of a wide glyph then EL(0)
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[1;4H$e[K"
  }
  "altscreen" {
    & $W "$e[H$e[2J"
    & $W "BEFORE-ALT"
    Start-Sleep -Milliseconds 300
    & $W "$e[?1049h"
    & $W "$e[H$e[2J"
    for ($i = 1; $i -le 8; $i++) { & $W "$e[$i;1H$cjk$cjk" }
    Start-Sleep -Milliseconds 400
    & $W "$e[?1049l"
    Start-Sleep -Milliseconds 300
    & $W "`r`nline1 plain ascii`r`nline2 plain ascii`r`n"
  }
  "ed0" {
    & $W "$e[H$e[2J"
    for ($i = 1; $i -le 5; $i++) { & $W "$e[$i;1H$cjk" }
    Start-Sleep -Milliseconds 400
    & $W "$e[2;1H$e[J"
    & $W "AFTER"
  }
  "ech" {
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[1;1H$e[3X"
  }
  "dch" {
    & $W "$e[H$e[2J"
    & $W $cjk
    Start-Sleep -Milliseconds 400
    & $W "$e[1;1H$e[1P"
  }
}

Start-Sleep -Seconds 600
