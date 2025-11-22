# uninstall-bounty-worker.ps1
# - Stops the bounty worker (node.exe bounty-worker.mjs)
# - Removes the "BountyWorker" startup Scheduled Task
# - Deletes C:\bounty-worker and C:\BountyTools
# - Removes C:\BountyTools from user PATH
#
# Safe to run via:
#   irm 'https://raw.githubusercontent.com/itchydonut08/bounty-worker-bootstrap/main/uninstall-bounty-worker.ps1' | iex

$ErrorActionPreference = "Stop"

Write-Host "=== Bounty Worker Uninstall ==="

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "This script should be run as Administrator."
        [void](Read-Host "Press Enter to continue anyway (may fail), or Ctrl+C to quit")
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
        Write-Host ("[PATH] {0} was not in user PATH." -f $dir)
        return
    }

    $newPath = ($newParts -join ";")
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host ("[PATH] Removed {0} from user PATH." -f $dir)
}

Assert-Admin

$ToolsDir  = "C:\BountyTools"
$WorkerDir = "C:\bounty-worker"
$TaskName  = "BountyWorker"

# 1) Stop & remove the scheduled task
Write-Host ("[*] Checking for scheduled task {0}..." -f $TaskName)
try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ("  - Stopping scheduled task {0} (if running)..." -f $TaskName)
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        } catch {
            Write-Warning ("    Failed to stop task {0}: {1}" -f $TaskName, $_.Exception.Message)
        }

        Write-Host ("  - Unregistering scheduled task {0}..." -f $TaskName)
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("[+] Scheduled task {0} removed." -f $TaskName)
    } else {
        Write-Host ("  - No scheduled task named {0} found." -f $TaskName)
    }
} catch {
    Write-Warning ("  - Could not inspect/remove scheduled task: {0}" -f $_.Exception.Message)
}

# 2) Kill any node.exe processes that are running bounty-worker.mjs
Write-Host "[*] Looking for node.exe processes running bounty-worker.mjs..."

try {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "bounty-worker\.mjs" }

    if ($procs) {
        foreach ($p in $procs) {
            Write-Host ("  - Terminating PID {0} (node bounty-worker.mjs)" -f $p.ProcessId)
            try {
                Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null
            } catch {
                Write-Warning ("    Failed to terminate PID {0}: {1}" -f $p.ProcessId, $_.Exception.Message)
            }
        }
    } else {
        Write-Host "  - No bounty-worker node.exe processes found."
    }
} catch {
    Write-Warning ("  - Could not inspect/terminate node.exe processes: {0}" -f $_.Exception.Message)
}

# 3) Remove worker directory
Write-Host ("[*] Removing worker directory {0}" -f $WorkerDir)
if (Test-Path -LiteralPath $WorkerDir) {
    try {
        Remove-Item -Recurse -Force -LiteralPath $WorkerDir
        Write-Host ("  - Removed {0}" -f $WorkerDir)
    } catch {
        Write-Warning ("  - Failed to remove worker directory {0}. Error: {1}" -f $WorkerDir, $_.Exception.Message)
    }
} else {
    Write-Host ("  - {0} does not exist." -f $WorkerDir)
}

# 4) Remove tools directory
Write-Host ("[*] Removing tools directory {0}" -f $ToolsDir)
if (Test-Path -LiteralPath $ToolsDir) {
    try {
        Remove-Item -Recurse -Force -LiteralPath $ToolsDir
        Write-Host ("  - Removed {0}" -f $ToolsDir)
    } catch {
        Write-Warning ("  - Failed to remove tools directory {0}. Error: {1}" -f $ToolsDir, $_.Exception.Message)
    }
} else {
    Write-Host ("  - {0} does not exist." -f $ToolsDir)
}

# 5) Clean PATH entry
Write-Host ("[*] Cleaning up PATH entry for {0}" -f $ToolsDir)
Remove-From-UserPath $ToolsDir

Write-Host ""
Write-Host "=== Uninstall complete. ==="
Write-Host "Node.js is still installed on this machine (in case other things use it)."
Write-Host "If you want to remove Node entirely, use Apps & Features or:"
Write-Host "  winget uninstall OpenJS.NodeJS.LTS"
Write-Host ""
Write-Host "If you added any aliases in your PowerShell profile (like setup-bounty-worker), remove them from:"
Write-Host ("  {0}" -f $PROFILE)
