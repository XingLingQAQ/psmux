# Regression: `new-session -d` must not return until its initial window is
# listable (tmux's "command finished server-side" semantics).
#
# ROOT CAUSE: the server writes its .port file and starts accepting connections
# BEFORE it creates the initial window. A readiness gate that waited only for the
# port file + a TCP connect could return exit 0 while list-windows was still
# empty: a window-less session that callers and scripts then trip over.
#
# DETERMINISTIC RED via fault injection: the server sleeps
# PSMUX_TEST_WINDOW_DELAY_MS right before create_window (after .port + accept
# thread are up). Set longer than the client RPC read timeout (2000ms) so an
# un-gated client loses. The fixed client polls until the window is listable.
# Removal recipe: delete this test if the PSMUX_TEST_WINDOW_DELAY_MS hook is
# removed from server/mod.rs.

$ErrorActionPreference = "Stop"
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) {
    Write-Host "FATAL: could not resolve psmux executable ($PSMUX)" -ForegroundColor Red
    exit 1
}

$tmpHome = Join-Path $env:TEMP ("psmux_rdy_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory $tmpHome -Force | Out-Null
$psmuxDir = Join-Path $tmpHome ".psmux"; New-Item -ItemType Directory $psmuxDir -Force | Out-Null
$env:USERPROFILE = $tmpHome; $env:HOME = $tmpHome
$ns = "rdy"; $session = "rdy"; $base = "${ns}__${session}"
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
Write-Host "=== new-session readiness gate (window listable before return) ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX" -ForegroundColor DarkGray

$env:PSMUX_TEST_WINDOW_DELAY_MS = "3000"
$env:PSMUX_NO_WARM = "1"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX -L $ns new-session -d -s $session 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    $elapsed = $sw.ElapsedMilliseconds

    Write-Result "new-session -d exited 0" ($code -eq 0) "exit=$code"
    Write-Host "  (new-session returned after ${elapsed}ms)" -ForegroundColor DarkGray
    # The fixed client must have waited the injected delay out; a release binary
    # without the hook returns fast and would pass the window check for free.
    Write-Result "latency injection active (waited out injected 3000ms delay)" `
        ($elapsed -ge 3000) "elapsed=${elapsed}ms < 3000ms - use a debug build"

    $windows = Get-ListWindows $base
    $hasWindow = ($null -ne $windows -and $windows.Length -gt 0)
    Write-Result "initial window listable immediately after new-session returns" `
        $hasWindow "list-windows empty/null right after return (got: '$windows')"
}
finally {
    Remove-Item Env:\PSMUX_TEST_WINDOW_DELAY_MS -EA SilentlyContinue
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
