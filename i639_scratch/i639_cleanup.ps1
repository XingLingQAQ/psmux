# Cleanup for the #639 investigation. Scoped on purpose:
#   * kill-server only in the -L namespaces this investigation created
#   * Stop-Process only for PIDs whose ExecutablePath is inside THIS worktree
#   * never by process name, never touching claude.exe
param([string]$Exe)

$ErrorActionPreference = "Continue"
$worktree = "C:\Users\godwin\Documents\workspace\psmux\.claude\worktrees\agent-a6b74dd9d56cbb991"

foreach ($ns in @("i639ns", "i639bn", "i639sp", "i639rz", "i639fz", "i639dbg", "i639")) {
    & $Exe -L $ns kill-server 2>&1 | Out-Null
    Write-Output "kill-server -L $ns"
}

Start-Sleep -Seconds 1

$live = Get-CimInstance Win32_Process -Filter "Name='psmux.exe' OR Name='pmux.exe' OR Name='tmux.exe'" -EA SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($worktree, [StringComparison]::OrdinalIgnoreCase) }
if ($live) {
    foreach ($p in $live) {
        Write-Output "worktree-scoped process still live: PID $($p.ProcessId) $($p.ExecutablePath)"
    }
} else {
    Write-Output "no worktree-scoped psmux/pmux/tmux processes remain"
}

Remove-Item "$env:USERPROFILE\.psmux\i639*" -Force -Recurse -EA SilentlyContinue
Remove-Item "$env:TEMP\psmux_i639*" -Force -Recurse -EA SilentlyContinue
Write-Output "removed i639 data files and temp dirs"
