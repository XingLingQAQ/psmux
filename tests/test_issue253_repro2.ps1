$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

# Build a real tech-pass.exe (simple .NET console exe) so we exactly mirror the issue
$bin = "$env:TEMP\psmux253_bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$marker = "$env:TEMP\psmux253_marker.txt"
$exePath = "$bin\tech-pass.exe"

if (-not (Test-Path $exePath)) {
    $cs = "$env:TEMP\techpass.cs"
    @"
using System;
using System.IO;
using System.Threading;
class P {
    static void Main(string[] args) {
        File.WriteAllText(@"$marker", "TECHPASS_EXE_RAN");
        Console.WriteLine("TECH-PASS EXE STARTED, args=" + string.Join(",", args));
        Thread.Sleep(60000);
    }
}
"@ | Set-Content $cs -Encoding UTF8
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /out:$exePath $cs 2>&1 | Out-Null
}
Write-Host "Built tech-pass.exe: $(Test-Path $exePath)"

# Add bin to PATH so 'tech-pass' resolves
$env:PATH = "$bin;$env:PATH"

function Test-Scenario {
    param([string]$Name, [string[]]$Args)
    $SESSION = "issue253_$Name"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item $marker -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800

    Write-Host ("`n=== SCENARIO: {0} ===" -f $Name) -ForegroundColor Cyan
    Write-Host ("CMD: psmux " + ($Args -join " ")) -ForegroundColor DarkGray
    & $PSMUX @Args
    Start-Sleep -Seconds 5

    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    Write-Host "PANE CAPTURE:" -ForegroundColor Yellow
    Write-Host $cap.TrimEnd()
    $markerExists = Test-Path $marker
    Write-Host "Marker present: $markerExists"
    $paneCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1) -join ''
    $startCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_start_command}' 2>&1) -join ''
    Write-Host "pane_current_command: $paneCmd"
    Write-Host "pane_start_command:   $startCmd"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    return @{ Marker=$markerExists; PaneCmd=$paneCmd; StartCmd=$startCmd; Cap=$cap }
}

# Exact issue scenarios
$r1 = Test-Scenario "issue_form1" @("new","-s","issue253_issue_form1","-d","--","cmd","pwsh","-Command","tech-pass.exe")
$r2 = Test-Scenario "issue_form2" @("new","-s","issue253_issue_form2","-d","--","cmd","pwsh","-Command","$bin\tech-pass.exe")
$r3 = Test-Scenario "issue_form3" @("new","-s","issue253_issue_form3","-d","--","cmd","$bin\tech-pass.exe")
# Sane forms
$r4 = Test-Scenario "direct_exe"  @("new","-s","issue253_direct_exe","-d","--","$bin\tech-pass.exe")
$r5 = Test-Scenario "cmd_slashc"  @("new","-s","issue253_cmd_slashc","-d","--","cmd","/c","$bin\tech-pass.exe")
$r6 = Test-Scenario "pwsh_command" @("new","-s","issue253_pwsh_command","-d","--","pwsh","-Command","tech-pass.exe")

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
$results = @{
    "issue_form1 (cmd pwsh -Command tech-pass.exe)" = $r1
    "issue_form2 (cmd pwsh -Command FULLPATH)"      = $r2
    "issue_form3 (cmd FULLPATH)"                     = $r3
    "direct_exe  (just the .exe)"                    = $r4
    "cmd_slashc  (cmd /c FULLPATH)"                  = $r5
    "pwsh_command (pwsh -Command tech-pass.exe)"     = $r6
}
foreach ($k in $results.Keys) {
    $v = $results[$k]
    "{0,-50} marker={1,-5} paneCmd={2}" -f $k, $v.Marker, $v.PaneCmd | Write-Host
}
