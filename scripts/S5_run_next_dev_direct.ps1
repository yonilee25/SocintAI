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
$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_run_next_dev_direct_{0}.log" -f $ts)
$appLogOut = Join-Path $logDir ("next_dev_A_{0}.out.log" -f $ts)
$appLogErr = Join-Path $logDir ("next_dev_A_{0}.err.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$lvl; step='S5.run_next_dev_direct';
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Start Next dev (pnpm exec next dev -p 3001 -H 127.0.0.1) with split logs' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 0) prechecks
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  J 'error' 'precheck' 'package.json not found; run S5_init_next_app.ps1 first' @{ appRoot=$appRoot }
  throw "Missing Next app at $appRoot"
}

# 1) ensure pnpm
function Pnpm-Detect { try { $v = (pnpm -v) 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() } } catch {}; return $null }
$pnpmVer = Pnpm-Detect
if (-not $pnpmVer) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null; $pnpmVer = Pnpm-Detect }
  catch { npm i -g pnpm --no-fund --no-audit | Out-Null; $pnpmVer = Pnpm-Detect }
}
if ($pnpmVer) { J 'info' 'env.pnpm' 'pnpm ready' @{ version=$pnpmVer } } else { J 'warn' 'env.pnpm' 'pnpm not available' @{} }

# 2) install deps (idempotent)
$installOk = $false
try {
  Push-Location $appRoot
  pnpm install --reporter silent | Out-Null
  $installOk = $true
  Pop-Location
} catch { try { Pop-Location } catch {}; J 'warn' 'install' 'pnpm install failed' @{ err="$_" } }

# 3) clean stale pid
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $p = Get-Process -Id $old -ErrorAction SilentlyContinue
    if (-not $p) { Remove-Item $pidFile -ErrorAction SilentlyContinue }
  }
}

# 4) pick a port (fallback if busy)
$port = 3001
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) { $port = 3003; J 'warn' 'port.busy' 'Port 3001 busy; switching to 3003' @{ ownerPid=$c.OwningProcess } }
} catch {}

# 5) start Next dev via Start-Process (split logs!)
$devStarted = $false
$procId = 0
try {
  $args = @('exec','next','dev','-p',"$port",'-H','127.0.0.1')
  $p = Start-Process -FilePath 'pnpm' -ArgumentList $args -WorkingDirectory $appRoot `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $appLogOut -RedirectStandardError $appLogErr
  Start-Sleep -Milliseconds 900
  if ($p -and -not $p.HasExited) {
    $procId = $p.Id
    Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
    $devStarted = $true
  }
  if ($devStarted) { J 'info' 'dev.start' 'Spawned Next dev' @{ procId=$procId; port=$port; out=$appLogOut; err=$appLogErr } }
  else { J 'warn' 'dev.start' 'Failed to spawn Next dev (check logs)' @{ out=$appLogOut; err=$appLogErr } }
} catch {
  J 'error' 'dev.start' 'Start-Process failed' @{ err="$_"; out=$appLogOut; errlog=$appLogErr }
}

# 6) probe /api/health
$probeOk = $false; $status = 0; $why=''; $tries=0
while (-not $probeOk -and $tries -lt 50) {
  Start-Sleep -Milliseconds 600
  $tries++
  try {
    $res = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 2
    if ($res.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
  } catch {
    $status = -1; $why = "$_"
  }
}
if ($probeOk) { J 'info' 'probe.api' 'Probed /api/health' @{ ok=$true; port=$port; status=$status; tries=$tries } }
else { J 'warn' 'probe.api' 'Health probe failed' @{ ok=$false; port=$port; status=$status; tries=$tries; err=$why } }

# 7) summary
$ready = ($installOk -and $devStarted -and $probeOk)
$summary = [ordered]@{
  install_ok        = $installOk
  dev_started       = $devStarted
  dev_pid           = $procId
  dev_port          = $port
  dev_log_out       = $appLogOut
  dev_log_err       = $appLogErr
  probe_api_ok      = $probeOk
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1b run-dev summary' $summary

Write-Host ("`n== S5.1b Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
