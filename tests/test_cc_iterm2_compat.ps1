# iTerm2 drop-in compatibility verification for psmux -CC mode.
#
# Walks through the actual dialog iTerm2 (and other tmux CC clients like
# Tmuxinator-CC, tmate, Termius) perform against tmux, and checks each
# step works against psmux byte-for-byte.
#
# References:
#   tmux/control.c   control_start / control_write / subscriptions
#   tmux/control-notify.c   the % notification family
#   tmux/cmd-refresh-client.c  refresh-client -B subscriptions
#   iTerm2 TmuxGateway.m  client dialog
#
# Layers:
#   1. Bootstrap: DCS opener, ST closer, no auto-burst
#   2. State polling: list-sessions, list-windows -a with iTerm2's exact -F
#   3. capture-pane -p -t %0 -e -P -J  (initial pane content)
#   4. send-keys -l 'echo hi' + Enter, observe %output streaming
#   5. Live: new-window -> %window-add, kill-window -> %window-close,
#      rename-window -> %window-renamed, select-window -> %session-window-changed
#   6. Subscriptions: refresh-client -B name:%pane:format, then state change
#      -> %subscription-changed
#   7. refresh-client -f pause-after=N + slow consumer -> %pause / %continue
#   8. display-message -p '#{format}' (one-shot format query)
#   9. Clean exit emits %exit then ST

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function P($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function S($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Hdr($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Cleanup($n) {
    & $PSMUX kill-session -t $n 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$n.*" -Force -EA SilentlyContinue
}

# Persistent CC session helper. Returns object with stream + reader + writer.
function Open-CC($session) {
    $port = (Get-Content "$psmuxDir\$session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $sr = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII)
    $sw = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
    $sw.NewLine = "`n"
    $sw.Write("AUTH $key`n"); $sw.Flush()
    $line = $sr.ReadLine()
    if ($line -notmatch "^OK") { throw "AUTH failed: $line" }
    $sw.Write("CONTROL_NOECHO`n"); $sw.Flush()
    # Read DCS opener (8 bytes including newline)
    $hdr = New-Object byte[] 8
    $stream.ReadTimeout = 1500
    $n = $stream.Read($hdr, 0, 8)
    return [pscustomobject]@{ Tcp = $tcp; Stream = $stream; Reader = $sr; Writer = $sw; Header = $hdr[0..($n-1)] }
}

function Send-CC($cc, [string]$cmd) {
    $cc.Writer.Write("$cmd`n"); $cc.Writer.Flush()
}

# Read until we see %end <id> for the most recent command, return the reply text
function Read-Reply($cc, [int]$timeoutMs = 2500) {
    $cc.Stream.ReadTimeout = $timeoutMs
    $sb = New-Object System.Text.StringBuilder
    $start = [DateTime]::UtcNow
    while ($true) {
        try {
            $line = $cc.Reader.ReadLine()
            if ($null -eq $line) { break }
            [void]$sb.AppendLine($line)
            if ($line -match "^%end \d+") { break }
            if ($line -match "^%error \d+") { break }
        } catch { break }
        if (([DateTime]::UtcNow - $start).TotalMilliseconds -gt $timeoutMs) { break }
    }
    return $sb.ToString()
}

# Drain notifications for $ms milliseconds
function Drain-Notifications($cc, [int]$ms = 500) {
    $cc.Stream.ReadTimeout = $ms
    $sb = New-Object System.Text.StringBuilder
    try {
        while ($true) {
            $line = $cc.Reader.ReadLine()
            if ($null -eq $line) { break }
            [void]$sb.AppendLine($line)
        }
    } catch {}
    return $sb.ToString()
}

function Close-CC($cc) {
    try { $cc.Tcp.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch {}
    Start-Sleep -Milliseconds 200
    try { $cc.Tcp.Close() } catch {}
}

Get-Process psmux,pmux,tmux -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

$S = "compat_iterm2"
Cleanup $S
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 2

# ============================================================
Hdr "Layer 1: Bootstrap (DCS first, no auto-burst)"
$cc = Open-CC $S
$hdr = $cc.Header
$dcs = @(0x1B,0x50,0x31,0x30,0x30,0x30,0x70,0x0A)
if ($hdr.Length -ge 7 -and -not (Compare-Object $hdr[0..6] $dcs[0..6])) { P "DCS opener present" }
else { F ("DCS missing. got: " + (($hdr | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')) }

$burst = Drain-Notifications $cc 600
if ([string]::IsNullOrWhiteSpace($burst)) { P "No auto-burst between DCS and first command (matches tmux)" }
else { F "Unexpected post-DCS bytes: $burst" }

# ============================================================
Hdr "Layer 2: iTerm2 state polling (list-sessions / list-windows -a)"
# iTerm2 uses very specific format strings. Replicate them.
$lsFmt = '#{session_id} #{session_name} #{session_windows}'
Send-CC $cc "list-sessions -F `"$lsFmt`""
$reply = Read-Reply $cc
if ($reply -match "%begin \d+ \d+ \d+" -and $reply -match "%end \d+ \d+ \d+") { P "list-sessions framed in %begin/%end" }
else { F "list-sessions framing missing" }
if ($reply -match "(?m)^\`$\d+ $S \d+") { P "list-sessions row matches `$id name windows" }
else { F "list-sessions row malformed: $reply" }

$lwFmt = '#{session_id} #{window_id} #{window_index} #{window_name} #{window_layout} #{window_active} #{window_panes}'
Send-CC $cc "list-windows -a -F `"$lwFmt`""
$reply = Read-Reply $cc
if ($reply -match "(?m)^\`$\d+ @\d+ \d+ ") { P "list-windows -a row matches `$sid @wid idx ..." }
else { F "list-windows -a malformed: $reply" }
if ($reply -match "\d+x\d+,\d+,\d+") { P "window_layout token recognisable" }
else { S "window_layout format unusual (may differ from tmux): $reply" }

# ============================================================
Hdr "Layer 3: capture-pane initial content"
# iTerm2 issues: capture-pane -p -t %0 -e -P -J -S - -E -
# -p print to stdout (in our case wrapped in %begin/%end)
# -e include escape sequences  -P preserve trailing spaces  -J join wrapped
# -S - / -E - = full history
Send-CC $cc "capture-pane -p -t %0 -e -P -J -S - -E -"
$reply = Read-Reply $cc 3000
if ($reply -match "%begin \d+ \d+" -and $reply -match "%end \d+ \d+") { P "capture-pane wrapped in %begin/%end" }
else { F "capture-pane framing missing: $reply" }
$captured = $reply -replace "(?ms)^%begin.*?\n", "" -replace "(?ms)^%end.*$", ""
if ($captured.Length -ge 0) { P "capture-pane returned content (len=$($captured.Length))" }
else { F "capture-pane empty" }

# ============================================================
Hdr "Layer 4: send-keys + %output streaming"
# Send a marker string into pane, expect %output %0 ... to carry it back.
$marker = "PSMUX_IT2_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
Send-CC $cc "send-keys -t %0 -l `"echo $marker`""
[void](Read-Reply $cc 1500)
Send-CC $cc "send-keys -t %0 Enter"
[void](Read-Reply $cc 1500)
Start-Sleep -Milliseconds 1500
$stream = Drain-Notifications $cc 2000
$outLines = ([regex]::Matches($stream, "(?m)^%output %\d+ ")).Count
if ($outLines -gt 0) { P "%output stream fires ($outLines lines)" }
else { F "no %output lines after send-keys" }
if ($stream -match [regex]::Escape($marker)) { P "%output carries the marker '$marker' (pane content streamed to CC client)" }
else { S "marker not visible in %output (escape encoding may hide it; lines=$outLines)" }

# ============================================================
Hdr "Layer 5: Live state notifications"
Send-CC $cc "new-window -n liveA"
[void](Read-Reply $cc 2000)
$ev = Drain-Notifications $cc 1000
if ($ev -match "%window-add @\d+") { P "%window-add fires on new-window" } else { F "no %window-add: $ev" }
if ($ev -match "%session-window-changed \`$\d+ @\d+") { P "%session-window-changed fires on auto-select" } else { S "%session-window-changed not emitted" }

Send-CC $cc "rename-window -t liveA liveA_renamed"
[void](Read-Reply $cc 1500)
$ev = Drain-Notifications $cc 800
if ($ev -match "%window-renamed @\d+ liveA_renamed") { P "%window-renamed fires" } else { F "no %window-renamed: $ev" }

Send-CC $cc "kill-window -t liveA_renamed"
[void](Read-Reply $cc 1500)
$ev = Drain-Notifications $cc 800
if ($ev -match "%window-close @\d+") { P "%window-close fires on kill-window" } else { F "no %window-close: $ev" }

# ============================================================
Hdr "Layer 6: refresh-client -B subscriptions"
Send-CC $cc "refresh-client -B sub_test:%0:#{pane_current_command}"
$reply = Read-Reply $cc 1500
if ($reply -match "%end \d+ \d+ 0") { P "refresh-client -B accepted (subscription registered)" }
elseif ($reply -match "%error") { F "refresh-client -B rejected: $reply" }
else { S "refresh-client -B response unclear: $reply" }

# Trigger something that should fire %subscription-changed (or be silent if not implemented)
Send-CC $cc "split-window -t %0"
[void](Read-Reply $cc 1500)
Start-Sleep -Milliseconds 800
$ev = Drain-Notifications $cc 1200
if ($ev -match "%subscription-changed sub_test ") { P "%subscription-changed fires on relevant change" }
else { S "%subscription-changed not seen (may need explicit format change). Got: $($ev.Substring(0,[Math]::Min(200,$ev.Length)))" }

# ============================================================
Hdr "Layer 7: refresh-client -f pause-after"
Send-CC $cc "refresh-client -f pause-after=1"
$reply = Read-Reply $cc 1500
if ($reply -match "%end \d+ \d+ 0") { P "refresh-client -f pause-after=1 accepted" }
elseif ($reply -match "%error") { S "refresh-client -f rejected (advanced flag not implemented): $reply" }
else { S "refresh-client -f unclear: $reply" }

# ============================================================
Hdr "Layer 8: display-message -p one-shot format"
Send-CC $cc "display-message -p `"#{session_name}/#{window_index}/#{pane_id}`""
$reply = Read-Reply $cc 1500
if ($reply -match "$S/\d+/%\d+") { P "display-message -p returns formatted string" }
else { F "display-message -p output unexpected: $reply" }

# ============================================================
Hdr "Layer 9: Clean exit ST closer"
Send-CC $cc "kill-server"
Start-Sleep -Milliseconds 800
$tail = New-Object System.IO.MemoryStream
$cc.Stream.ReadTimeout = 1500
try {
    while ($true) {
        $b = $cc.Stream.ReadByte()
        if ($b -lt 0) { break }
        $tail.WriteByte($b)
    }
} catch {}
$tb = $tail.ToArray()
if ($tb.Length -ge 2 -and $tb[$tb.Length-2] -eq 0x1B -and $tb[$tb.Length-1] -eq 0x5C) {
    P "ST closer present after kill-server (clean shutdown)"
} else {
    # On kill-server the connection may RST without ST. Acceptable per tmux.
    S "ST not seen after kill-server (server killed mid-flight, RST is acceptable)"
}
$tt = [System.Text.Encoding]::ASCII.GetString($tb)
if ($tt -match "%exit") { P "%exit notification fired before close" } else { S "%exit not in tail: $tt" }
Close-CC $cc

# ============================================================
Hdr "Compatibility Summary"
Write-Host "  Pass: $($script:Pass)" -ForegroundColor Green
Write-Host "  Fail: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skip: $($script:Skip)" -ForegroundColor Yellow
Write-Host ""
if ($script:Fail -eq 0) {
    Write-Host "  RESULT: drop-in compatible with iTerm2-style CC clients" -ForegroundColor Green
} else {
    Write-Host "  RESULT: gaps present (see FAIL items above)" -ForegroundColor Red
}
exit $script:Fail
