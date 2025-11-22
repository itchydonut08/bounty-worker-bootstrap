# uninstall-bounty-worker.ps1
# Safe to run via: irm '.../uninstall-bounty-worker.ps1' | iex

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

Write-Host "[*] Trying to stop any running bounty-worker node processes..."

try {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "bounty-worker\.mjs" }

    if ($procs) {
        foreach ($p in $procs) {
            Write-Host ("  - Terminating PID {0} (node bounty-worker.mjs)" -f $p.ProcessId)
            Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null
        }
    } else {
        Write-Host "  - No bounty-worker node processes found."
    }
} catch {
    Write-Warning ("Could not inspect or kill node processes. Error: {0}" -f $_.Exception.Message)
}

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

Write-Host ("[*] Cleaning up PATH entry for {0}" -f $ToolsDir)
Remove-From-UserPath $ToolsDir

Write-Host ""
Write-Host "=== Uninstall complete. ==="
Write-Host "If you added any aliases (like setup-bounty-worker) to your PowerShell profile, remove them from:"
Write-Host ("  {0}" -f $PROFILE)
Write-Host ""
Write-Host "Node.js is still installed. If you want to remove Node entirely, use Apps & Features or:"
Write-Host "  winget uninstall OpenJS.NodeJS.LTS"
