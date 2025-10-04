param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
$logDir  = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_fix_health_route_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.fix_health_route'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Fixing /api/health location (src/app) and probing' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 0) verify project exists
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  J 'error' 'precheck' 'package.json not found; run S5_init_next_app.ps1 first' @{ appRoot=$appRoot }
  throw "Missing Next app at $appRoot"
}

# 1) pick correct app folder: prefer src\app; fallback to app\
$srcApp = Join-Path $appRoot 'src\app'
$plainApp = Join-Path $appRoot 'app'
$chosenApp = $null
if (Test-Path $srcApp) { $chosenApp = $srcApp } elseif (Test-Path $plainApp) { $chosenApp = $plainApp } else {
  # create src\app if neither exists (cna with --src-dir should have it)
  New-Item -ItemType Directory -Force -Path $srcApp | Out-Null
  $chosenApp = $srcApp
}
J 'info' 'choose.path' 'Selected app directory' @{ chosen=$chosenApp }

# 2) ensure api/health dir and write route.ts (Node runtime)
$apiDir = Join-Path $chosenApp 'api\health'
if (-not (Test-Path $apiDir)) { New-Item -ItemType Directory -Force -Path $apiDir | Out-Null }

$routePath = Join-Path $apiDir 'route.ts'
$routeCode = @"
export const runtime = 'nodejs';
import { NextResponse } from 'next/server';
import { randomUUID } from 'crypto';

export async function GET() {
  const req_id = randomUUID();
  return NextResponse.json(
    { ok: true, service: 'socint-frontend', req_id, ts: new Date().toISOString() },
    { status: 200 }
  );
}
"@
Set-Content -LiteralPath $routePath -Value $routeCode -Encoding UTF8
J 'info' 'write.route' 'Wrote /api/health route' @{ path=$routePath }

# 3) probe /api/health on 3001 and 3003 (in case we fell back earlier)
function Probe($port) {
  $o = [ordered]@{ port=$port; ok=$false; code=0; why='' }
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
    $o.ok = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
  } catch {
    $o.ok = $false; $o.code = -1; $o.why = "$_"
  }
  return $o
}

# small wait for HMR to pick up new file
Start-Sleep -Milliseconds 1200
$p1 = Probe 3001
$p3 = if (-not $p1.ok) { Probe 3003 } else { @{ port=3003; ok=$false; code=0; why='skipped' } }

$probeOk = ($p1.ok -or $p3.ok)
$activePort = if ($p1.ok) { 3001 } elseif ($p3.ok) { 3003 } else { 0 }

# 4) summary
$summary = [ordered]@{
  health_route_written = $true
  route_path           = $routePath
  probe_3001_ok        = $p1.ok
  probe_3003_ok        = $p3.ok
  active_port          = $activePort
  log_file             = $stepLog
  duration_ms          = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2       = $probeOk
}
$level = if ($summary.ready_for_S5_2) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1c route-fix summary' $summary

Write-Host ("`n== S5.1c Health: {0} (see {1})" -f ($(if($summary.ready_for_S5_2){'READY'}else{'NEEDS_ACTION'}), $stepLog))
