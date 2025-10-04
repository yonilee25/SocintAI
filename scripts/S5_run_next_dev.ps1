param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir  = Join-Path $repoRoot 'logs'
$runDir  = Join-Path $repoRoot '.run'
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_run_next_dev_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$appLog  = Join-Path $logDir ("next_dev_A_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$lvl; step='S5.run_next_dev';
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Start Next.js dev on :3001 and probe health' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) prechecks
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  J 'error' 'precheck' 'package.json not found; run S5_init_next_app.ps1 first' @{ appRoot=$appRoot }
  throw "Missing Next app at $appRoot"
}

# 2) ensure pnpm
function Pnpm-Detect { 
  try { $v = (pnpm -v) 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() } } catch {}
  return $null
}
$pnpmVer = Pnpm-Detect
if (-not $pnpmVer) {
  try {
    corepack enable | Out-Null
    corepack prepare pnpm@latest --activate | Out-Null
    $pnpmVer = Pnpm-Detect
  } catch {
    J 'warn' 'corepack' 'Corepack pnpm enable failed; trying npm -g pnpm' @{ err="$_" }
    npm i -g pnpm --no-fund --no-audit | Out-Null
    $pnpmVer = Pnpm-Detect
  }
}
if ($pnpmVer) { J 'info' 'env.pnpm' 'pnpm status' @{ version=$pnpmVer; ok=$true } }
else { J 'warn' 'env.pnpm' 'pnpm not available' @{ ok=$false } }

# 3) install deps (idempotent)
$installOk = $false
try {
  Push-Location $appRoot
  pnpm install --reporter silent | Out-Null
  $installOk = $true
  Pop-Location
} catch {
  try { Pop-Location } catch {}
  J 'warn' 'install' 'pnpm install failed' @{ err="$_" }
}

# 4) if stale PID exists and process absent, remove it
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $p = Get-Process -Id $old -ErrorAction SilentlyContinue
    if (-not $p) { Remove-Item $pidFile -ErrorAction SilentlyContinue }
  }
}

# 5) start Next dev on :3001 (background)
$devStarted = $false
$procId = 0
try {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'pwsh'
  $psi.ArgumentList = @(
    '-NoLogo','-NoExit','-Command',
    "Set-Location `"$appRoot`"; pnpm exec next dev -p 3001 -H 127.0.0.1 2>&1 | Tee-Object -FilePath `"$appLog`""
  )
  $psi.UseShellExecute = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  Start-Sleep -Milliseconds 700
  if ($p -and -not $p.HasExited) {
    $procId = $p.Id
    Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
    $devStarted = $true
  }
  if ($devStarted) { J 'info' 'dev.start' 'Spawned Next dev process' @{ procId=$procId; log=$appLog } }
  else { J 'warn' 'dev.start' 'Failed to spawn Next dev process' @{} }
} catch {
  J 'error' 'dev.start' 'Failed to start Next dev' @{ err="$_" }
}

# 6) poll health endpoint
$probeOk = $false; $status = 0; $why=''; $tries=0
while (-not $probeOk -and $tries -lt 40) {
  Start-Sleep -Milliseconds 600
  $tries++
  try {
    $res = Invoke-WebRequest -Uri 'http://127.0.0.1:3001/api/health' -TimeoutSec 2
    if ($res.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
  } catch {
    $status = -1; $why = "$_"
  }
}
if ($probeOk) { J 'info' 'probe.api' 'Probed /api/health on :3001' @{ ok=$true; status=$status; tries=$tries } }
else { J 'warn' 'probe.api' 'Health probe failed' @{ ok=$false; status=$status; tries=$tries; err=$why } }

# 7) summary
$ready = ($installOk -and $devStarted -and $probeOk)
$summary = [ordered]@{
  install_ok        = $installOk
  dev_started       = $devStarted
  dev_pid           = $procId
  dev_log           = $appLog
  probe_api_ok      = $probeOk
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1 run-dev summary' $summary

Write-Host ("`n== S5.1 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
