# setup-bounty-worker.ps1
# One-shot installer for a Windows bounty worker.
# Does:
#   - Install Node.js LTS via winget (if node is missing)
#   - Download & install subfinder, httpx, nuclei to C:\BountyTools
#   - Add C:\BountyTools to PATH (user)
#   - Create C:\bounty-worker with:
#       * bounty-worker.mjs
#       * worker-config.json
#       * register-and-run.ps1
#       * start_worker.vbs
#   - Run register-and-run.ps1 (which starts the worker & registers with Pi)
#
# After this:
#   - Double-click C:\bounty-worker\start_worker.vbs to start worker hidden.

$ErrorActionPreference = "Stop"

Write-Host "=== Bounty Worker Setup ==="

# ---------- Helpers ----------

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Warning "This script should be run as Administrator. Right-click it and choose 'Run with PowerShell' or 'Run as Administrator'."
        Read-Host "Press Enter to continue anyway (may fail), or Ctrl+C to quit"
    }
}

function Ensure-Folder($path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

function Ensure-Tool-In-Path($exeName) {
    $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
    return [bool]$cmd
}

function Append-To-UserPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }

    $parts = $userPath.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts -contains $dir) {
        Write-Host "[PATH] $dir already in user PATH."
        return
    }

    $newPath = ($userPath.TrimEnd(";") + ";" + $dir)
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "[PATH] Added $dir to user PATH. You may need to open a new PowerShell/terminal for it to take effect there."
}

Assert-Admin

# ---------- Config ----------

$ToolsDir  = "C:\BountyTools"
$WorkerDir = "C:\bounty-worker"
$PiUrl     = "http://bountypi.local:3000"
$WorkerPort = 4000

Ensure-Folder $ToolsDir
Ensure-Folder $WorkerDir

# ---------- 1. Ensure Node.js LTS ----------

if (Ensure-Tool-In-Path "node") {
    Write-Host "[Node] Node.js already installed."
} else {
    Write-Host "[Node] Node.js not found. Attempting to install via winget..."
    if (Ensure-Tool-In-Path "winget") {
        try {
            winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
            Write-Host "[Node] Winget installation attempted. Restart this script if node is still missing."
        } catch {
            Write-Warning "[Node] winget install failed: $($_.Exception.Message)"
            Write-Warning "Please install Node.js LTS manually from https://nodejs.org and re-run this script."
            throw
        }
    } else {
        Write-Warning "[Node] winget not found. Please install Node.js LTS manually from https://nodejs.org, then re-run this script."
        throw "Node.js missing and winget unavailable."
    }
}

# After install attempt, re-check
if (-not (Ensure-Tool-In-Path "node")) {
    Write-Warning "[Node] Node.js still not found in PATH. Please install it and try again."
    throw "Node.js not available."
}

# ---------- 2. Install ProjectDiscovery tools ----------

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
    if (Test-Path $exePath) {
        Write-Host "[Tools] $($tool.Name) already present at $exePath"
        continue
    }

    Write-Host "[Tools] Downloading $($tool.Name)..."
    $zipTemp = Join-Path $tempRoot ($tool.Name + ".zip")
    Invoke-WebRequest -Uri $tool.Url -OutFile $zipTemp

    $extractDir = Join-Path $tempRoot $tool.Name
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $zipTemp -DestinationPath $extractDir

    # Try to find the exe
    $foundExe = Get-ChildItem -Path $extractDir -Recurse -Filter $tool.Exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundExe) {
        Copy-Item $foundExe.FullName $exePath
        Write-Host "[Tools] Installed $($tool.Name) to $exePath"
    } else {
        Write-Warning "[Tools] Could not find $($tool.Exe) inside extracted archive."
    }
}

Append-To-UserPath $ToolsDir

Write-Host "[Tools] Checking tools on PATH..."
foreach ($name in @("subfinder","httpx","nuclei")) {
    if (Ensure-Tool-In-Path $name) {
        Write-Host "  - $name OK"
    } else {
        Write-Warning "  - $name NOT found. Use a new terminal or verify PATH includes $ToolsDir."
    }
}

# ---------- 3. Create bounty-worker Node project ----------

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

# bounty-worker.mjs
$workerJs = @'
import express from 'express';
import fs from 'node:fs/promises';
import path from 'node:path';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);

const app = express();
const PORT = 4000;

const DATA_DIR = path.join(process.cwd(), 'worker-data');
const RECON_DIR = path.join(DATA_DIR, 'recon');

const SUBFINDER_RL = 20;
const HTTPX_RL = 20;
const HTTPX_THREADS = 30;

const NUCLEI_SEVERITIES = 'medium,high,critical';
const NUCLEI_RL = 10;
const NUCLEI_CONCURRENCY = 10;

async function ensureDir(p) {
  await fs.mkdir(p, { recursive: true });
}

function safeId(id) {
  return String(id || 'unknown').replace(/[^a-z0-9_\\-:.]/gi, '_');
}

function parseHttpxJsonLines(stdout) {
  const lines = stdout.split('\\n').map(l => l.trim()).filter(Boolean);
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
        title: obj.title || ''
      });
    } catch {
      // ignore
    }
  }

  return { liveHosts, urls };
}

function parseNucleiJsonLines(stdout) {
  const lines = stdout.split('\\n').map(l => l.trim()).filter(Boolean);
  const findings = [];

  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      findings.push({
        template: obj.template || obj.id || '',
        severity: obj.info?.severity || '',
        url: obj.url || '',
        matcher: obj.matcher_name || '',
        type: obj.type || ''
      });
    } catch {
      // ignore
    }
  }

  return findings;
}

app.use(express.json());

app.get('/api/health', (req, res) => {
  res.json({ ok: true, msg: 'bounty worker online' });
});

app.post('/api/recon', async (req, res) => {
  try {
    const { id, platform, name, domains } = req.body || {};
    if (!domains || !Array.isArray(domains) || domains.length === 0) {
      return res.status(400).json({ error: 'domains array required' });
    }

    const sid = safeId(id || name);
    const workDir = path.join(RECON_DIR, sid);
    await ensureDir(workDir);

    const domainsPath = path.join(workDir, 'domains.txt');
    await fs.writeFile(domainsPath, domains.join('\\n') + '\\n', 'utf8');

    const pipelineCmd = [
      `cd "${workDir}"`,
      `subfinder -dL "${domainsPath}" -silent -rl ${SUBFINDER_RL}`,
      `sort -u`,
      `httpx -silent -json -threads ${HTTPX_THREADS} -rl ${HTTPX_RL} -mc 200,301,302`
    ].join(' | ');

    console.log(\`[worker] recon pipeline for \${id || name} -> \${pipelineCmd}\`);

    let httpxStdout = '';
    try {
      const result = await execAsync(pipelineCmd, {
        maxBuffer: 50 * 1024 * 1024,
        shell: true
      });
      httpxStdout = result.stdout;
    } catch (err) {
      console.error('[worker] recon pipeline error:', err.message);
      httpxStdout = err.stdout || '';
    }

    const { liveHosts, urls } = parseHttpxJsonLines(httpxStdout);
    console.log(\`[worker] \${id || name}: \${liveHosts.length} live hosts\`);

    let nucleiFindings = [];
    if (urls.length > 0) {
      const urlsPath = path.join(workDir, 'urls.txt');
      await fs.writeFile(urlsPath, urls.join('\\n') + '\\n', 'utf8');

      const nucleiCmd = [
        `cd "${workDir}"`,
        `nuclei -silent -json -l "${urlsPath}"`,
        `-severity ${NUCLEI_SEVERITIES}`,
        `-rl ${NUCLEI_RL}`,
        `-c ${NUCLEI_CONCURRENCY}`
      ].join(' ');

      console.log(\`[worker] nuclei for \${id || name} -> \${nucleiCmd}\`);

      try {
        const result = await execAsync(nucleiCmd, {
          maxBuffer: 50 * 1024 * 1024,
          shell: true
        });
        nucleiFindings = parseNucleiJsonLines(result.stdout || '');
      } catch (err) {
        console.error('[worker] nuclei error:', err.message);
        nucleiFindings = parseNucleiJsonLines(err.stdout || '');
      }

      console.log(\`[worker] \${id || name}: \${nucleiFindings.length} nuclei findings\`);
    } else {
      console.log('[worker] no live URLs, skipping nuclei');
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
    console.error('[worker] fatal error in /api/recon', e);
    res.status(500).json({ error: 'worker error' });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(\`Bounty worker listening on http://0.0.0.0:\${PORT}\`);
});
'@

$workerJsPath = Join-Path $WorkerDir "bounty-worker.mjs"
$workerJs | Out-File -FilePath $workerJsPath -Encoding utf8 -Force

# worker-config.json
$configJson = @"
{
  "piUrl": "$PiUrl",
  "port": $WorkerPort,
  "name": "$($env:COMPUTERNAME)"
}
"@

$configPath = Join-Path $WorkerDir "worker-config.json"
$configJson | Out-File -FilePath $configPath -Encoding utf8 -Force

# register-and-run.ps1
$registerPs1 = @'
$ErrorActionPreference = "Stop"

Set-Location -Path $PSScriptRoot

$configPath = Join-Path $PSScriptRoot "worker-config.json"
if (Test-Path $configPath) {
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
        Write-Warning "$name not found in PATH. Please install it (or add to PATH) before using this worker."
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
    Write-Host "[*] Detected IP: $ip"
    Write-Host "[*] Worker URL: $workerUrl"
    Write-Host "[*] Registering worker with Pi at $($piUrl)/api/workers/register ..."

    try {
        $body = @{
            url  = $workerUrl
            name = $name
        } | ConvertTo-Json

        $resp = Invoke-RestMethod -Method Post -Uri "$piUrl/api/workers/register" `
            -Body $body -ContentType "application/json"

        Write-Host "[+] Registration response:" ($resp | ConvertTo-Json -Depth 4)
    } catch {
        Write-Warning "Failed to register worker with Pi: $($_.Exception.Message)"
    }
}

Write-Host "[*] Done. Worker should now be active. Pi will use it automatically."
'@

$registerPath = Join-Path $WorkerDir "register-and-run.ps1"
$registerPs1 | Out-File -FilePath $registerPath -Encoding utf8 -Force

# start_worker.vbs
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

Write-Host "[Worker] Files created in $WorkerDir"

# ---------- 4. Kick off worker once ----------

Write-Host "[Worker] Launching worker (register-and-run.ps1) hidden..."
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$registerPath`"" -WindowStyle Hidden

Write-Host "=== Setup complete. Worker is starting. ==="
Write-Host "Next time, just double-click: $startVbsPath"
