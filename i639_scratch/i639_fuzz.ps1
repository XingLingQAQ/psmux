# #639 randomized property fixture: run INSIDE a pane.
#
# Mutate the screen in many SMALL incremental steps mixing wide CJK and narrow
# ASCII, with erases, insert/delete cells and alt-screen trips, so the attached
# client's diff renderer has to emit hundreds of small PARTIAL ROW updates.
# Small steps are the point: a ghost is what a partial-row diff leaves behind.
#
# Phase A exercises the destructive ops (ED, full clear, alt screen).
# Phase B then rebuilds a DENSE screen and mutates it with non-destructive ops
# only, so the FINAL screen is rich and was reached incrementally. Comparing a
# blank final screen would be a vacuous pass.
param([int]$Seed = 1, [int]$RoundsA = 160, [int]$RoundsB = 160, [int]$Cols = 80, [int]$Rows = 18)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
function W($s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

$rand = New-Object System.Random($Seed)
$wide = @(0x4E2D,0x6587,0x6D4B,0x8BD5,0x5B57,0x7B26,0x4F60,0x597D,0x4E16,0x754C,
          0x30A2,0x30A4,0xAC00,0xAC01,0xFF21,0xFF22)
$narrow = [char[]]"abcdefghijklmnopqrstuvwxyz0123456789 .,-_/"

function RandText([int]$maxCols) {
  $s = ""; $used = 0
  while ($used -lt $maxCols) {
    if ($rand.Next(100) -lt 45) {
      if ($used + 2 -gt $maxCols) { break }
      $s += [char]$wide[$rand.Next($wide.Length)]; $used += 2
    } else {
      $s += $narrow[$rand.Next($narrow.Length)]; $used += 1
    }
  }
  return $s
}

W "$e[H$e[2J"
W "PHASE0-IDLE"
Start-Sleep -Seconds 5
W "$e[H$e[2J"

# ---------------- Phase A: everything, including destructive ops ------------
for ($n = 1; $n -le $RoundsA; $n++) {
  $r = $rand.Next(1, $Rows + 1)
  $c = $rand.Next(1, $Cols - 4)
  $op = $rand.Next(100)
  if ($op -lt 45)     { W ("$e[$r;${c}H" + (RandText ($rand.Next(2, [Math]::Min(30, $Cols - $c + 1))))) }
  elseif ($op -lt 58) { W "$e[$r;${c}H$e[K" }
  elseif ($op -lt 66) { W "$e[$r;${c}H$e[$($rand.Next(1,12))X" }
  elseif ($op -lt 73) { W "$e[$r;${c}H$e[$($rand.Next(1,6))P" }
  elseif ($op -lt 80) { W "$e[$r;${c}H$e[$($rand.Next(1,6))@" }
  elseif ($op -lt 86) { W ("$e[$r;1H$e[2K" + (RandText ($rand.Next(1, $Cols)))) }
  elseif ($op -lt 91) { W "$e[$r;${c}H$e[J" }
  elseif ($op -lt 96) {
    W "$e[?1049h$e[H$e[2J"
    for ($i = 1; $i -le 6; $i++) { W ("$e[$i;1H" + (RandText 40)) }
    Start-Sleep -Milliseconds 60
    W "$e[?1049l"
  }
  else { W "$e[H$e[2J" }
  Start-Sleep -Milliseconds 20
}

# ---------------- Phase B: dense base, then non-destructive mutation --------
W "$e[H$e[2J"
for ($i = 1; $i -le $Rows; $i++) { W ("$e[$i;1H" + (RandText ($Cols - 1))) }
Start-Sleep -Milliseconds 200

for ($n = 1; $n -le $RoundsB; $n++) {
  $r = $rand.Next(1, $Rows + 1)
  $c = $rand.Next(1, $Cols - 4)
  $op = $rand.Next(100)
  if ($op -lt 55)     { W ("$e[$r;${c}H" + (RandText ($rand.Next(2, [Math]::Min(24, $Cols - $c + 1))))) }
  elseif ($op -lt 70) { W "$e[$r;${c}H$e[$($rand.Next(1,10))X" }
  elseif ($op -lt 82) { W "$e[$r;${c}H$e[$($rand.Next(1,6))P" }
  elseif ($op -lt 94) { W "$e[$r;${c}H$e[$($rand.Next(1,6))@" }
  else                { W ("$e[$r;${c}H$e[K" + (RandText ($rand.Next(1, 20)))) }
  Start-Sleep -Milliseconds 20
}

# settle on a final, stable, DENSE screen
Start-Sleep -Seconds 2
W "$e[$Rows;1H$e[2KFUZZDONE"
Start-Sleep -Seconds 600
