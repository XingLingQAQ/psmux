param([string]$Case = "cufskip")

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

# 6 wide glyphs = 12 columns
$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26
# 4 wide glyphs = 8 columns
$cjk4 = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5

# Phase 0: idle so the outer client attaches and settles on a known screen.
W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5

switch ($Case) {

  # --- Hypothesis 2: renderer must SKIP a span containing wide glyphs. ---
  "cufskip" {
    # row = AAAA + 4 wide glyphs (cols 5..12) + BBBB (cols 13..16)
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1HAAAA$cjk4`BBBB" }
    Start-Sleep -Seconds 3
    # change ONLY the trailing ASCII; the CJK span must be skipped over
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;13HCCCC" }
    W "$e[12;1HMARKERAFTER"
  }

  "headtail" {
    # change head AND tail, leaving the wide span in the middle unchanged
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1HAAAA$cjk4`BBBB" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1HXXXX"; W "$e[$i;13HCCCC" }
    W "$e[12;1HMARKERAFTER"
  }

  # --- Hypothesis 1: alt screen exit restoring a NON-BLANK primary screen. ---
  "primary_content" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 15; $i++) { W "$e[$i;1Hprimary row $i some ascii text here" }
    Start-Sleep -Seconds 2
    W "$e[?1049h"
    W "$e[H$e[2J"
    for ($i = 1; $i -le 15; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    W "$e[?1049l"
    Start-Sleep -Seconds 2
    W "$e[17;1HMARKERAFTER"
  }

  # tig-like: primary has content, alt screen has MIXED ascii+CJK
  "tigsim" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 15; $i++) { W "$e[$i;1HPS C:\work> git log --oneline $i" }
    Start-Sleep -Seconds 2
    W "$e[?1049h"
    W "$e[H$e[2J"
    for ($i = 1; $i -le 15; $i++) {
      W "$e[$i;1H"
      W ("{0:0000000} " -f (1234567 + $i))
      W "$cjk4 "
      W "commit message $i "
      W $cjk
    }
    Start-Sleep -Seconds 3
    W "$e[?1049l"
    Start-Sleep -Seconds 2
    W "$e[17;1HMARKERAFTER"
  }

  # --- Hypothesis 3: scrolling region (tig uses one) ---
  "scrollregion" {
    W "$e[H$e[2J"
    W "$e[3;15r"          # scroll region rows 3..15
    for ($i = 3; $i -le 15; $i++) { W "$e[$i;1H$cjk$cjk" }
    Start-Sleep -Seconds 2
    W "$e[15;1H"
    for ($k = 1; $k -le 5; $k++) { W "`n" }   # scroll the region up 5
    Start-Sleep -Seconds 2
    W "$e[r"              # reset scroll region
    W "$e[H$e[2J"
    W "MARKERAFTER"
  }

  # --- Hypothesis 4: wide glyph straddling the RIGHT EDGE ---
  "rightedge" {
    W "$e[H$e[2J"
    # pane is 61 cols; 30 wide glyphs = 60 cols, then one more must wrap
    $long = ""
    for ($k = 0; $k -lt 6; $k++) { $long += $cjk }   # 36 glyphs = 72 cols
    for ($i = 1; $i -le 8; $i += 2) { W "$e[$i;1H$long" }
    Start-Sleep -Seconds 3
    W "$e[H$e[2J"
    W "MARKERAFTER"
  }

  # CJK at an ODD starting column so every pair straddles even boundaries
  "oddcol" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;2H$cjk$cjk" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$e[2Kz" }
    W "$e[12;1HMARKERAFTER"
  }

  # --- shrink: long CJK row replaced by a SHORT ascii row ---
  "shrink" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1H$cjk$cjk$cjk" }
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1Hzz" }   # NO erase, just shorter text
    W "$e[12;1HMARKERAFTER"
  }

  # --- hold CJK on screen and do nothing (for the attach/full-repaint probe) ---
  "hold" {
    W "$e[H$e[2J"
    for ($i = 1; $i -le 10; $i++) { W "$e[$i;1HAAAA$cjk4`BBBB $cjk" }
    W "$e[12;1HMARKERAFTER"
  }
}

Start-Sleep -Seconds 600
