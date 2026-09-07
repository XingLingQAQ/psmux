# #639 probe: a tig-like screen mixing East Asian AMBIGUOUS width characters
# (the commit graph: bullets, box drawing, arrows) with wide CJK text, then a
# redraw. psmux sizes ambiguous characters as ONE column (unicode-width). A
# terminal running in a CJK locale draws them as TWO.
param([string]$Case = "graph")

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

# East Asian Ambiguous: these are what tig's graph column is made of.
$amb = @([char]0x25CF, [char]0x25CB, [char]0x2502, [char]0x2500, [char]0x251C,
         [char]0x2514, [char]0x00B1, [char]0x00A7, [char]0x2018, [char]0x2019)
$cjk = [char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5 + [char]0x5B57 + [char]0x7B26

W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5

switch ($Case) {
  "graph" {
    # tig-like: graph glyphs, then hash, then a Chinese commit subject
    W "$e[H$e[2J"
    for ($i = 1; $i -le 12; $i++) {
      $g = ($amb[($i - 1) % $amb.Length].ToString()) * 3
      W "$e[$i;1H$g $("{0:x7}" -f (0x1234567 + $i)) $cjk$cjk"
    }
    Start-Sleep -Seconds 3
    # now redraw each row SHORTER (this is where an offset makes glyphs survive)
    for ($i = 1; $i -le 12; $i++) { W "$e[$i;1Hshort $i" }
    W "$e[14;1HMARKERAFTER"
  }
  "altgraph" {
    W "$e[H$e[2J"
    W "primary shell text"
    Start-Sleep -Seconds 2
    W "$e[?1049h$e[H$e[2J"
    for ($i = 1; $i -le 12; $i++) {
      $g = ($amb[($i - 1) % $amb.Length].ToString()) * 3
      W "$e[$i;1H$g $("{0:x7}" -f (0x1234567 + $i)) $cjk$cjk"
    }
    Start-Sleep -Seconds 3
    W "$e[?1049l"
    Start-Sleep -Seconds 2
    W "$e[3;1HMARKERAFTER"
  }
}
Start-Sleep -Seconds 600
