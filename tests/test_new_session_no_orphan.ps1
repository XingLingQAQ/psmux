# Regression: `new-session -d` must WAIT for a slow-but-healthy server instead of
# giving up (and orphaning it) on a tight fixed timeout.
#
# ROOT CAUSE: under load a healthy server can be slow to write its .port file.
# The pre-fix client allowed only a 5s .port poll then a single 100ms connect,
# mistook anything slower for death, exited rc=1, and even deleted the .port
# file -- orphaning a live server. (38/6000 under load, every one an orphan.)
#
# DETERMINISTIC RED via fault injection: PSMUX_TEST_PORTFILE_DELAY_MS makes the
# server sleep before writing .port while otherwise healthy (its listener is
# already bound). Set LONGER than the old 5s poll, so the pre-fix client gives
# up while the server is alive and about to be ready. The fixed client keeps
# waiting (bounded), the server comes up, and new-session returns rc=0 with a
# listable window -- and crucially leaves NO orphan.
# Removal recipe: delete this test if the PSMUX_TEST_PORTFILE_DELAY_MS hook is
# removed from server/mod.rs.

$ErrorActionPreference = "Stop"
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) {
    Write-Host "FATAL: could not resolve psmux executable ($PSMUX)" -ForegroundColor Red
    exit 1
}

$tmpHome = Join-Path $env:TEMP ("psmux_noorphan_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory $tmpHome -Force | Out-Null
$psmuxDir = Join-Path $tmpHome ".psmux"; New-Item -ItemType Directory $psmuxDir -Force | Out-Null
$env:USERPROFILE = $tmpHome; $env:HOME = $tmpHome
$ns = "noorphan"; $session = "noorphan"; $base = "${ns}__${session}"
$pass = 0; $fail = 0
function Write-Result($name, $ok, $msg) {
    if ($ok) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  [FAIL] $name : $msg" -ForegroundColor Red; $script:fail++ }
}

function Get-ListWindows($portBase) {
    $portFile = Join-Path $psmuxDir "$portBase.port"
    $keyFile  = Join-Path $psmuxDir "$portBase.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = if (Test-Path $keyFile) { (Get-Content $keyFile -Raw).Trim() } else { "" }
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.Connect("127.0.0.1", [int]$port); $tcp.NoDelay = $true
        $stream = $tcp.GetStream(); $stream.ReadTimeout = 2000
        $w = [System.IO.StreamWriter]::new($stream); $w.AutoFlush = $true
        $r = [System.IO.StreamReader]::new($stream)
        $w.WriteLine("AUTH $key"); $r.ReadLine() | Out-Null
        $w.WriteLine("list-windows")
        $sb = [System.Text.StringBuilder]::new()
        try { while ($null -ne ($l = $r.ReadLine())) { [void]$sb.AppendLine($l) } } catch {}
        $tcp.Close(); return $sb.ToString().Trim()
    } catch { return $null }
}

Write-Host ""
Write-Host "=== new-session waits for a slow server (no early give-up / orphan) ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX" -ForegroundColor DarkGray

$env:PSMUX_TEST_PORTFILE_DELAY_MS = "7000"
$env:PSMUX_NO_WARM = "1"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX -L $ns new-session -d -s $session 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  (new-session returned after ${elapsed}ms, rc=$code)" -ForegroundColor DarkGray

    Write-Result "fault injection active (waited out injected 7000ms .port delay)" `
        ($elapsed -ge 7000) "elapsed=${elapsed}ms < 7000ms - use a debug build"

    Write-Result "new-session -d waited for the slow server (rc=0)" ($code -eq 0) `
        "rc=$code - client gave up on a slow-but-healthy server"

    $windows = Get-ListWindows $base
    $hasWindow = ($null -ne $windows -and $windows.Length -gt 0)
    Write-Result "initial window listable after new-session returns" $hasWindow `
        "list-windows empty/null (got: '$windows')"
}
finally {
    Remove-Item Env:\PSMUX_TEST_PORTFILE_DELAY_MS -EA SilentlyContinue
    Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue
    & $PSMUX -L $ns kill-server 2>&1 | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
      Where-Object { $_.CommandLine -match [regex]::Escape($ns) } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $tmpHome -EA SilentlyContinue
}

Write-Host ""
Write-Host "=== Results: $pass passed, $fail failed ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
