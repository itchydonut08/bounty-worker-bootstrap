# setup-bounty-worker.ps1
# One-shot installer for a Windows bounty worker.
# - Installs Node (via winget if needed)
# - Installs subfinder / httpx / nuclei to C:\BountyTools
# - Creates C:\bounty-worker Node project
# - Registers a Scheduled Task "BountyWorker" to start at logon (hidden)
# - Starts the task immediately
#
# Safe to run via:
#   irm 'https://raw.githubusercontent.com/itchydonut08/bounty-worker-bootstrap/main/setup-bounty-worker.ps1' | iex

$ErrorActionPreference = "Stop"

Write-Host "=== Bounty Worker Setup (with startup) ==="

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "This script should be run as Administrator for best results."
        [void](Read-Host "Press Enter to continue anyway (may fail), or Ctrl+C to quit")
    }
}

function Ensure-Folder($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

function Tool-Exists($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Append-To-UserPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }

    $parts = $userPath.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts -contains $dir) {
        Write-Host ("[PATH] {0} already in user PATH." -f $dir)
        return
    }

    $newPath = ($userPath.TrimEnd(";") + ";" + $dir)
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host ("[PATH] Added {0} to user PATH (new terminals will see it)." -f $dir)
}

Assert-Admin

# --- Config ---
$ToolsDir   = "C:\BountyTools"
$WorkerDir  = "C:\bounty-worker"
$PiUrl      = "http://bountypi.local:3000"  # change to http://<pi-ip>:3000 if DNS doesn't work
$WorkerPort = 4000
$TaskName   = "BountyWorker"

Ensure-Folder $ToolsDir
Ensure-Folder $WorkerDir

Write-Host ("[*] Tools directory:  {0}" -f $ToolsDir)
Write-Host ("[*] Worker directory: {0}" -f $WorkerDir)

# --- 1. Ensure Node.js LTS ---
if (Tool-Exists "node") {
    Write-Host "[Node] Node.js already installed."
} else {
    Write-Host "[Node] Node.js not found. Attempting to install via winget..."
    if (Tool-Exists "winget") {
        try {
            winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
            Write-Host "[Node] Winget installation attempted. If node is still missing, install manually."
        } catch {
            Write-Warning ("[Node] winget install failed: {0}" -f $_.Exception.Message)
            Write-Warning "Please install Node.js LTS manually from https://nodejs.org and re-run this script."
            throw
        }
    } else {
        Write-Warning "[Node] winget is not available. Please install Node.js LTS manually and re-run this script."
        throw "Node.js missing and winget not found."
    }
}

if (-not (Tool-Exists "node")) {
    Write-Warning "[Node] Node.js still not found in PATH. Aborting."
    throw "Node.js not available after installation attempt."
}

# --- 2. Install ProjectDiscovery tools (subfinder, httpx, nuclei) ---
$downloads = @(
    @{
        Name = "subfinder"
        Exe  = "subfinder.exe"
        Url  = "https://github.com/projectdiscovery/subfinder/releases/download/v2.6.6/subfinder_2.6.6_windows_amd64.zip"
    },
    @{
        Name = "httpx"
        Exe  = "httpx.exe"
        Url  = "https://github.com/projectdiscovery/httpx/releases/download/v1.6.10/httpx_1.6.10_windows_amd64.zip"
    },
    @{
        Name = "nuclei"
        Exe  = "nuclei.exe"
        Url  = "https://github.com/projectdiscovery/nuclei/releases/download/v3.3.8/nuclei_3.3.8_windows_amd64.zip"
    }
)

$tempRoot = Join-Path $env:TEMP "bounty-tools"
Ensure-Folder $tempRoot

foreach ($tool in $downloads) {
    $exePath = Join-Path $ToolsDir $tool.Exe
    if (Test-Path -LiteralPath $exePath) {
        Write-Host ("[Tools] {0} already present at {1}" -f $tool.Name, $exePath)
        continue
    }

    Write-Host ("[Tools] Downloading {0}..." -f $tool.Name)
    $zipTemp = Join-Path $tempRoot ($tool.Name + ".zip")
    Invoke-WebRequest -Uri $tool.Url -OutFile $zipTemp

    $extractDir = Join-Path $tempRoot $tool.Name
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -Recurse -Force $extractDir
    }
    Expand-Archive -Path $zipTemp -DestinationPath $extractDir

    $foundExe = Get-ChildItem -Path $extractDir -Recurse -Filter $tool.Exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundExe) {
        Copy-Item $foundExe.FullName $exePath
        Write-Host ("[Tools] Installed {0} to {1}" -f $tool.Name, $exePath)
    } else {
        Write-Warning ("[Tools] Could not find {0} inside archive for {1}" -f $tool.Exe, $tool.Name)
    }
}

Append-To-UserPath $ToolsDir

Write-Host "[Tools] Quick check on PATH:"
foreach ($name in @("subfinder","httpx","nuclei")) {
    if (Tool-Exists $name) {
        Write-Host ("  - {0} OK" -f $name)
    } else {
        Write-Warning ("  - {0} NOT found. Open a new PowerShell window or ensure PATH includes {1}" -f $name, $ToolsDir)
    }
}

# --- 3. Create bounty-worker Node project ---
Set-Location $WorkerDir

# package.json
$packageJson = @'
{
  "name": "bounty-worker",
  "version": "1.0.0",
  "description": "Bounty worker (subfinder + httpx + nuclei)",
  "main": "bounty-worker.mjs",
  "type": "module",
  "scripts": {
    "start": "node bounty-worker.mjs"
  },
  "dependencies": {
    "express": "^4.21.0"
  }
}
'@

$packagePath = Join-Path $WorkerDir "package.json"
$packageJson | Out-File -FilePath $packagePath -Encoding utf8 -Force

Write-Host "[Worker] Installing Node dependencies (express)..."
npm install | Out-Null

# bounty-worker.mjs (worker server)
$workerJs = @'
import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import { exec } from "node:child_process";
import { promisify } from "node:util";

const execAsync = promisify(exec);

const app = express();
const PORT = 4000;

const DATA_DIR = path.join(process.cwd(), "worker-data");
const RECON_DIR = path.join(DATA_DIR, "recon");

const SUBFINDER_RL = 20;
const HTTPX_RL = 20;
const HTTPX_THREADS = 30;

const NUCLEI_SEVERITIES = "medium,high,critical";
const NUCLEI_RL = 10;
const NUCLEI_CONCURRENCY = 10;

async function ensureDir(p) {
  await fs.mkdir(p, { recursive: true });
}

function safeId(id) {
  return String(id || "unknown").replace(/[^a-z0-9_.:~-]/gi, "_");
}


function parseHttpxJsonLines(stdout) {
  const lines = stdout.split("\\n").map(l => l.trim()).filter(Boolean);
  const liveHosts = [];
  const urls = [];

  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      const url = obj.url || obj.host;
      if (!url) continue;
      urls.push(url);
      liveHosts.push({
        url,
        status: obj.status_code,
        title: obj.title || ""
      });
    } catch {
      // ignore
    }
  }

  return { liveHosts, urls };
}

function parseNucleiJsonLines(stdout) {
  const lines = stdout.split("\\n").map(l => l.trim()).filter(Boolean);
  const findings = [];

  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      findings.push({
        template: obj.template || obj.id || "",
        severity: obj.info?.severity || "",
        url: obj.url || "",
        matcher: obj.matcher_name || "",
        type: obj.type || ""
      });
    } catch {
      // ignore
    }
  }

  return findings;
}

app.use(express.json());

app.get("/api/health", (req, res) => {
  res.json({ ok: true, msg: "bounty worker online" });
});

app.post("/api/recon", async (req, res) => {
  try {
    const { id, platform, name, domains } = req.body || {};
    if (!domains || !Array.isArray(domains) || domains.length === 0) {
      return res.status(400).json({ error: "domains array required" });
    }

    const sid = safeId(id || name);
    const workDir = path.join(RECON_DIR, sid);
    await ensureDir(workDir);

    const domainsPath = path.join(workDir, "domains.txt");
    await fs.writeFile(domainsPath, domains.join("\\n") + "\\n", "utf8");

    const pipelineCmd = [
      `cd "${workDir}"`,
      `subfinder -dL "${domainsPath}" -silent -rl ${SUBFINDER_RL}`,
      "sort -u",
      `httpx -silent -json -threads ${HTTPX_THREADS} -rl ${HTTPX_RL} -mc 200,301,302`
    ].join(" | ");

    console.log(`[worker] recon pipeline for ${id || name} -> ${pipelineCmd}`);

    let httpxStdout = "";
    try {
      const result = await execAsync(pipelineCmd, {
        maxBuffer: 50 * 1024 * 1024,
        shell: true
      });
      httpxStdout = result.stdout;
    } catch (err) {
      console.error("[worker] recon pipeline error:", err.message);
      httpxStdout = err.stdout || "";
    }

    const { liveHosts, urls } = parseHttpxJsonLines(httpxStdout);
    console.log(`[worker] ${id || name}: ${liveHosts.length} live hosts`);

    let nucleiFindings = [];
    if (urls.length > 0) {
      const urlsPath = path.join(workDir, "urls.txt");
      await fs.writeFile(urlsPath, urls.join("\\n") + "\\n", "utf8");

      const nucleiCmd = [
        `cd "${workDir}"`,
        `nuclei -silent -json -l "${urlsPath}"`,
        `-severity ${NUCLEI_SEVERITIES}`,
        `-rl ${NUCLEI_RL}`,
        `-c ${NUCLEI_CONCURRENCY}`
      ].join(" ");

      console.log(`[worker] nuclei for ${id || name} -> ${nucleiCmd}`);

      try {
        const result = await execAsync(nucleiCmd, {
          maxBuffer: 50 * 1024 * 1024,
          shell: true
        });
        nucleiFindings = parseNucleiJsonLines(result.stdout || "");
      } catch (err) {
        console.error("[worker] nuclei error:", err.message);
        nucleiFindings = parseNucleiJsonLines(err.stdout || "");
      }

      console.log(`[worker] ${id || name}: ${nucleiFindings.length} nuclei findings`);
    } else {
      console.log("[worker] no live URLs, skipping nuclei");
    }

    res.json({
      id,
      platform,
      name,
      domains,
      liveHosts,
      nucleiFindings
    });
  } catch (e) {
    console.error("[worker] fatal error in /api/recon", e);
    res.status(500).json({ error: "worker error" });
  }
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Bounty worker listening on http://0.0.0.0:${PORT}`);
});
'@

$workerJsPath = Join-Path $WorkerDir "bounty-worker.mjs"
$workerJs | Out-File -FilePath $workerJsPath -Encoding utf8 -Force

# worker-config.json (inject PiUrl & port)
$configJson = @"
{
  "piUrl": "$PiUrl",
  "port": $WorkerPort,
  "name": "$($env:COMPUTERNAME)"
}
"@

$configPath = Join-Path $WorkerDir "worker-config.json"
$configJson | Out-File -FilePath $configPath -Encoding utf8 -Force

# register-and-run.ps1 (used by startup task / VBS)
$registerPs1 = @'
$ErrorActionPreference = "Stop"

Set-Location -Path $PSScriptRoot

$configPath = Join-Path $PSScriptRoot "worker-config.json"
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
} else {
    $config = [pscustomobject]@{
        piUrl = "http://bountypi.local:3000"
        port  = 4000
        name  = $env:COMPUTERNAME
    }
}

$piUrl = $config.piUrl
$port  = $config.port
$name  = $config.name

function Check-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Warning ("{0} not found in PATH. Install it or add to PATH." -f $name)
    }
}

Check-Tool "node"
Check-Tool "subfinder"
Check-Tool "httpx"
Check-Tool "nuclei"

Write-Host "[*] Starting worker server (node bounty-worker.mjs) hidden..."
Start-Process -FilePath "node" -ArgumentList "bounty-worker.mjs" -WindowStyle Hidden

Start-Sleep -Seconds 3

$ip = Get-NetIPAddress -AddressFamily IPv4 `
    | Where-Object {
        $_.IPAddress -ne "127.0.0.1" -and
        $_.IPAddress -notlike "169.254.*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } `
    | Sort-Object -Property IPAddress `
    | Select-Object -First 1 -ExpandProperty IPAddress

if (-not $ip) {
    Write-Warning "Could not detect a suitable IPv4 address. Worker will still run, but registration may fail."
} else {
    $workerUrl = "http://$($ip):$port"
    Write-Host ("[*] Detected IP: {0}" -f $ip)
    Write-Host ("[*] Worker URL: {0}" -f $workerUrl)
    Write-Host ("[*] Registering worker with Pi at {0}/api/workers/register ..." -f $piUrl)

    try {
        $body = @{
            url  = $workerUrl
            name = $name
        } | ConvertTo-Json

        $resp = Invoke-RestMethod -Method Post -Uri ("{0}/api/workers/register" -f $piUrl) `
            -Body $body -ContentType "application/json"

        Write-Host "[+] Registration response:"
        $resp | ConvertTo-Json -Depth 4
    } catch {
        Write-Warning ("Failed to register worker with Pi. Error: {0}" -f $_.Exception.Message)
    }
}

Write-Host "[*] Done. Worker should now be active."
'@

$registerPath = Join-Path $WorkerDir "register-and-run.ps1"
$registerPs1 | Out-File -FilePath $registerPath -Encoding utf8 -Force

# start_worker.vbs (called by Scheduled Task, fully hidden)
$startVbs = @'
Dim shell, fso, scriptPath, folder
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = WScript.ScriptFullName
folder = fso.GetFile(scriptPath).ParentFolder.Path

cmd = "powershell -ExecutionPolicy Bypass -File """ & folder & "\register-and-run.ps1"""

shell.Run cmd, 0, False
'@

$startVbsPath = Join-Path $WorkerDir "start_worker.vbs"
$startVbs | Out-File -FilePath $startVbsPath -Encoding ascii -Force

Write-Host ("[Worker] Files created in {0}" -f $WorkerDir)

# --- 4. Create Scheduled Task for startup ---
Write-Host ""
Write-Host ("[*] Configuring startup task '{0}'..." -f $TaskName)

# Remove existing task if any
try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ("  - Removing existing task {0}..." -f $TaskName)
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
} catch {
    Write-Warning ("  - Could not inspect/remove existing task: {0}" -f $_.Exception.Message)
}

$arg     = '"' + $startVbsPath + '"'
$action  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description "Start bounty worker at user logon" | Out-Null
    Write-Host ("[+] Scheduled task {0} created. Worker will start automatically on logon." -f $TaskName)
} catch {
    Write-Warning ("[!] Failed to register scheduled task: {0}" -f $_.Exception.Message)
}

# Start it right now
try {
    Write-Host "[*] Starting scheduled task now..."
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[+] Worker launch requested via Scheduled Task."
} catch {
    Write-Warning ("  - Could not start scheduled task immediately: {0}" -f $_.Exception.Message)
}

Write-Host ""
Write-Host "=== Setup complete. Worker should now be running in the background and will auto-start on logon. ==="
Write-Host "To verify from this machine:  Invoke-RestMethod http://localhost:4000/api/health"
Write-Host "To uninstall everything later, use uninstall-bounty-worker.ps1."
