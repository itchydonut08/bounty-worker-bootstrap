
# uninstall-bounty-worker.ps1
# Undoes what setup-bounty-worker.ps1 did:
#   - Stop any bounty-worker node processes
#   - Remove C:\bounty-worker
#   - Remove C:\BountyTools
#   - Remove C:\BountyTools from user PATH

$ErrorActionPreference = "Stop"

Write-Host "=== Bounty Worker Uninstall ==="

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "This script should be run as Administrator."
        Read-Host "Press Enter to continue anyway (may fail), or Ctrl+C to quit"
    }
}

function Remove-From-UserPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) {
        Write-Host "[PATH] No user PATH found."
        return
    }

    $parts = $userPath.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
    $newParts = $parts | Where-Object { $_ -ne $dir }
    if ($newParts.Count -eq $parts.Count) {
        Write-Host "[PATH] $dir was not in user PATH."
        return
    }

    $newPath = ($newParts -join ";")
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "[PATH] Removed $dir from user PATH."
}

Assert-Admin

$ToolsDir  = "C:\BountyTools"
$WorkerDir = "C:\bounty-worker"

Write-Host "[*] Trying to stop any running bounty-worker node processes..."

try {
    # Find node.exe processes whose CommandLine includes 'bounty-worker.mjs'
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "bounty-worker\.mjs" }

    if ($procs) {
        foreach ($p in $procs) {
            Write-Host "  - Killing PID $($p.ProcessId) (node bounty-worker.mjs)"
            Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null
        }
    } else {
        Write-Host "  - No bounty-worker node processes found."
    }
} catch {
    Write-Warning "Could not inspect/kill node processes: $($_.Exception.Message)"
}

Write-Host "[*] Removing worker directory: $WorkerDir"
if (Test-Path $WorkerDir) {
    try {
        Remove-Item -Recurse -Force $WorkerDir
        Write-Host "  - Removed $WorkerDir"
    } catch {
        Write-Warning "  - Failed to remove $WorkerDir: $($_.Exception.Message)"
    }
} else {
    Write-Host "  - $WorkerDir does not exist."
}

Write-Host "[*] Removing tools directory: $ToolsDir"
if (Test-Path $ToolsDir) {
    try {
        Remove-Item -Recurse -Force $ToolsDir
        Write-Host "  - Removed $ToolsDir"
    } catch {
        Write-Warning "  - Failed to remove $ToolsDir: $($_.Exception.Message)"
    }
} else {
    Write-Host "  - $ToolsDir does not exist."
}

Write-Host "[*] Cleaning up PATH entry for $ToolsDir"
Remove-From-UserPath $ToolsDir

Write-Host ""
Write-Host "=== Uninstall complete. ==="
Write-Host "If you created any aliases in your PowerShell profile (like 'setup-bounty-worker'),"
Write-Host "you can remove those lines from:"
Write-Host "  $PROFILE"
Write-Host ""
Write-Host "Node.js is still installed. If you want to remove Node completely, use Apps & Features"
Write-Host "or 'winget uninstall OpenJS.NodeJS.LTS' (if winget is installed)."
