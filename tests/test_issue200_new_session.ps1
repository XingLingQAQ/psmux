# Issue #200 E2E Test: new-session command via prefix+: must create a session
# This test proves the fix ACTUALLY WORKS by:
# 1. Starting a psmux session
# 2. Sending "new-session -s <name>" via the server TCP control protocol
# 3. Verifying the new session's port file appears (proving it was created)
# 4. Verifying the new session is reachable via TCP
# 5. Cleaning up both sessions

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$homeDir = $env:USERPROFILE
$psmuxDir = "$homeDir\.psmux"
$testSession = "e2e_issue200_main"
$newSession = "e2e_issue200_created"
$passed = 0
$failed = 0

function Write-TestResult($name, $ok, $msg) {
    if ($ok) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $name : $msg" -ForegroundColor Red
        $script:failed++
    }
}

function Send-PsmuxCommand($session, $command) {
    $portFile = "$psmuxDir\$session.port"
    $keyFile = "$psmuxDir\$session.key"
    if (-not (Test-Path $portFile)) { return $null }
    if (-not (Test-Path $keyFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.Connect("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        
        # Auth
        $writer.WriteLine("AUTH $key")
        $writer.Flush()
        $auth_resp = $reader.ReadLine()
        
        # Send command
        $writer.WriteLine($command)
        $writer.Flush()
        
        # Read response
        $stream.ReadTimeout = 2000
        try {
            $resp = $reader.ReadLine()
        } catch {
            $resp = ""
        }
        
        $tcp.Close()
        return $resp
    } catch {
        if ($Verbose) { Write-Host "    TCP error: $_" -ForegroundColor Yellow }
        return $null
    }
}

function Test-SessionAlive($session) {
    $portFile = "$psmuxDir\$session.port"
    if (-not (Test-Path $portFile)) { return $false }
    $port = (Get-Content $portFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.Connect("127.0.0.1", [int]$port)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

function Cleanup-Session($session) {
    $portFile = "$psmuxDir\$session.port"
    $keyFile = "$psmuxDir\$session.key"
    if (Test-Path $portFile) {
        # Try to send kill-server
        Send-PsmuxCommand $session "kill-server" | Out-Null
        Start-Sleep -Milliseconds 500
        # Remove port/key files
        Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $keyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Issue #200 E2E Test: new-session from command prompt ===" -ForegroundColor Cyan
Write-Host ""

# Cleanup any prior test state
Cleanup-Session $testSession
Cleanup-Session $newSession
Start-Sleep -Milliseconds 300

# ── Step 1: Create the main session ───────────────────────────────────────
Write-Host "Step 1: Creating main session '$testSession'..." -ForegroundColor Yellow
psmux new-session -d -s $testSession
Start-Sleep -Milliseconds 2000

$mainAlive = Test-SessionAlive $testSession
Write-TestResult "Main session created and alive" $mainAlive "Port file not found or server not reachable"

if (-not $mainAlive) {
    Write-Host "FATAL: Cannot proceed without main session" -ForegroundColor Red
    exit 1
}

# ── Step 2: Verify new session does NOT exist yet ─────────────────────────
Write-Host "Step 2: Verifying '$newSession' does not exist yet..." -ForegroundColor Yellow
$newPortFile = "$psmuxDir\$newSession.port"
$preExists = Test-Path $newPortFile
Write-TestResult "New session does not pre-exist" (-not $preExists) "Port file already exists before test"

# ── Step 3: Send new-session command via TCP (simulating command prompt) ──
Write-Host "Step 3: Sending 'new-session -d -s $newSession' to main session..." -ForegroundColor Yellow
$resp = Send-PsmuxCommand $testSession "new-session -d -s $newSession"
if ($Verbose) { Write-Host "    Response: $resp" -ForegroundColor Gray }

# Wait for the new session to spin up
Start-Sleep -Milliseconds 3000

# ── Step 4: Verify new session was created ────────────────────────────────
Write-Host "Step 4: Verifying new session was created..." -ForegroundColor Yellow
$newPortExists = Test-Path $newPortFile
Write-TestResult "New session port file exists" $newPortExists "Port file $newPortFile not found"

$newAlive = Test-SessionAlive $newSession
Write-TestResult "New session is alive and reachable" $newAlive "TCP connection to new session failed"

# ── Step 5: Verify new session responds to commands ───────────────────────
Write-Host "Step 5: Verifying new session responds to commands..." -ForegroundColor Yellow
if ($newAlive) {
    $infoResp = Send-PsmuxCommand $newSession "display-message -p '#{session_name}'"
    $gotResponse = ($null -ne $infoResp -and $infoResp.Length -gt 0)
    Write-TestResult "New session responds to display-message" $gotResponse "No response from new session"
    if ($Verbose -and $gotResponse) { Write-Host "    Session name: $infoResp" -ForegroundColor Gray }
} else {
    Write-TestResult "New session responds to display-message" $false "Skipped - session not alive"
}

# ── Step 6: Verify both sessions appear in session list ───────────────────
Write-Host "Step 6: Verifying both sessions appear in session list..." -ForegroundColor Yellow
$allSessions = Get-ChildItem "$psmuxDir\*.port" | ForEach-Object { $_.BaseName }
$mainInList = $allSessions -contains $testSession
$newInList = $allSessions -contains $newSession
Write-TestResult "Main session in port file list" $mainInList "Main session not found in .psmux directory"
Write-TestResult "New session in port file list" $newInList "New session not found in .psmux directory"

# ── Step 7: Test new-session with auto-generated name ─────────────────────
Write-Host "Step 7: Testing new-session without explicit name..." -ForegroundColor Yellow
$beforeSessions = (Get-ChildItem "$psmuxDir\*.port" -ErrorAction SilentlyContinue).Count
$resp2 = Send-PsmuxCommand $testSession "new-session -d"
Start-Sleep -Milliseconds 3000
$afterSessions = (Get-ChildItem "$psmuxDir\*.port" -ErrorAction SilentlyContinue).Count
$autoCreated = $afterSessions -gt $beforeSessions
Write-TestResult "new-session without -s creates auto-named session" $autoCreated "Session count did not increase (before: $beforeSessions, after: $afterSessions)"

# ── Cleanup ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Cleaning up..." -ForegroundColor Yellow

# Kill all test sessions
Cleanup-Session $testSession
Cleanup-Session $newSession

# Find and kill auto-generated sessions
$autoSessions = Get-ChildItem "$psmuxDir\*.port" -ErrorAction SilentlyContinue | Where-Object {
    $_.BaseName -match '^\d+$'
} | ForEach-Object { $_.BaseName }
foreach ($s in $autoSessions) {
    # Only kill if it was created during our test (within last 30 seconds)
    if ((Get-Item "$psmuxDir\$s.port").CreationTime -gt (Get-Date).AddSeconds(-30)) {
        Cleanup-Session $s
    }
}
Start-Sleep -Milliseconds 500

# ── Summary ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "ISSUE #200 FIX NOT VERIFIED - $failed test(s) failed!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ISSUE #200 FIX VERIFIED - new-session works from inside a session!" -ForegroundColor Green
    exit 0
}
