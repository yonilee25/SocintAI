# C:\SocintAI\scripts\S5_add_pages_api_health_and_rebuild.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
$runDir = Join-Path $repoRoot '.run'
$feRoot = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -Type Directory -Force -Path $runDir | Out-Null }

$ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog  = Join-Path $logDir ("S5_add_pages_api_health_and_rebuild_{0}.log" -f $ts)
$buildOut = Join-Path $logDir ("next_build_pagesapi_{0}.out.log" -f $ts)
$buildErr = Join-Path $logDir ("next_build_pagesapi_{0}.err.log" -f $ts)
$startOut = Join-Path $logDir ("next_start_pagesapi_A_{0}.out.log" -f $ts)
$startErr = Join-Path $logDir ("next_start_pagesapi_A_{0}.err.log" -f $ts)
$pidFile  = Join-Path $runDir 'next_A.pid'
$port     = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.add_pages_api_health'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Add pages API fallback /api/health → rebuild → restart → probe' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# sanity
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) { throw "Next app not found at $appRoot" }

# 1) write src/pages/api/health.ts (idempotent)
$pagesApiDir = Join-Path $appRoot 'src\pages\api'
if (-not (Test-Path $pagesApiDir)) { New-Item -ItemType Directory -Force -Path $pagesApiDir | Out-Null }
$pagesHealth = Join-Path $pagesApiDir 'health.ts'
if (-not (Test-Path $pagesHealth)) {
  $code = @"
import type { NextApiRequest, NextApiResponse } from 'next';
export default function handler(_req: NextApiRequest, res: NextApiResponse) {
  res.status(200).json({ ok: true, service: 'socint-frontend', ts: new Date().toISOString() });
}
"@
  Set-Content -LiteralPath $pagesHealth -Value $code -Encoding UTF8
}
J 'info' 'write.pagesapi' 'Wrote pages API route' @{ path=$pagesHealth }

# 2) stop previous server if running
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($proc) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} ; Start-Sleep -Milliseconds 300 }
    J 'info' 'stop.prev' 'Stopped previous Next server' @{ oldPid=$old }
  }
}

# 3) resolve pnpm path
$pnpmCmd = $null
try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpmCmd) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpmCmd) { throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpmCmd }

# 4) rebuild (synchronous)
$cmdExe = $env:ComSpec; if (-not $cmdExe) { $cmdExe = 'C:\Windows\System32\cmd.exe' }
$buildCmd = '"' + $pnpmCmd + '"' + ' build'
$buildOk = $false
try {
  $pBuild = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
            -ArgumentList '/d','/s','/c', $buildCmd `
            -PassThru -NoNewWindow -Wait `
            -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
  $exitBuild = 0; try { $exitBuild = $pBuild.ExitCode } catch {}
  $buildOk = ($exitBuild -eq 0)
  J ($buildOk ? 'info' : 'warn') 'build.done' 'Build finished' @{ ok=$buildOk; exit=$exitBuild; out=$buildOut; err=$buildErr }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_"; out=$buildOut; errlog=$buildErr }
}

# 5) free/bind port
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} ; Start-Sleep -Milliseconds 300 }
} catch {}

# 6) start prod server again
$startOk = $false; $procId = 0
if ($buildOk) {
  $startCmd = '"' + $pnpmCmd + '"' + " start -p $port -H 127.0.0.1"
  try {
    $pStart = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
              -ArgumentList '/d','/s','/c', $startCmd `
              -PassThru -WindowStyle Hidden `
              -RedirectStandardOutput $startOut -RedirectStandardError $startErr
    Start-Sleep -Milliseconds 1500
    if ($pStart -and -not $pStart.HasExited) {
      $procId = $pStart.Id
      Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
      $startOk = $true
    }
    J ($startOk ? 'info' : 'warn') 'start.spawn' 'Started Next prod server' @{ ok=$startOk; procId=$procId; port=$port; out=$startOut; err=$startErr }
  } catch {
    J 'error' 'start.fail' 'Start-Process failed for next start' @{ err="$_"; out=$startOut; errlog=$startErr }
  }
}

# 7) probe /api/health
$probeOk = $false; $status=0; $tries=0; $why=''
if ($startOk) {
  while (-not $probeOk -and $tries -lt 60) {
    Start-Sleep -Milliseconds 800
    $tries++
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 4
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch { $status = -1; $why = "$_" }
  }
}
J ($probeOk ? 'info' : 'warn') 'probe.api' 'Probe /api/health after pages API fallback' @{ ok=$probeOk; port=$port; status=$status; tries=$tries; why=$why }

# 8) summary
$ready = ($buildOk -and $startOk -and $probeOk)
$summary = [ordered]@{
  pages_api_path   = $pagesHealth
  build_ok         = $buildOk
  start_ok         = $startOk
  probe_api_ok     = $probeOk
  dev_pid          = $procId
  dev_port         = $port
  build_log_out    = $buildOut
  build_log_err    = $buildErr
  start_log_out    = $startOut
  start_log_err    = $startErr
  pid_file         = $pidFile
  log_file         = $stepLog
  duration_ms      = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2   = $ready
}
J ($ready ? 'info' : 'warn') 'summary' 'S5.1l pages-API fallback summary' $summary

Write-Host ("`n== S5.1l Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
