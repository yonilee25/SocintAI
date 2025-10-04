# C:\SocintAI\scripts\S5_fix_app_scaffold_and_restart.ps1
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

$ts       = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog  = Join-Path $logDir ("S5_fix_app_scaffold_and_restart_{0}.log" -f $ts)
$buildOut = Join-Path $logDir ("next_build_fix_{0}.out.log" -f $ts)
$buildErr = Join-Path $logDir ("next_build_fix_{0}.err.log" -f $ts)
$startOut = Join-Path $logDir ("next_start_fix_A_{0}.out.log" -f $ts)
$startErr = Join-Path $logDir ("next_start_fix_A_{0}.err.log" -f $ts)
$pidFile  = Join-Path $runDir 'next_A.pid'
$port     = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.fix_app_scaffold_and_restart'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Ensure src/app scaffold, rebuild, restart, probe /api/health' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# sanity
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) { throw "Next app not found at $appRoot" }

# resolve pnpm
$pnpmCmd = $null
try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpmCmd) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpmCmd) { throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpmCmd }

# 1) write src/app layout + page + health route (idempotent)
$srcApp = Join-Path $appRoot 'src\app'
if (-not (Test-Path $srcApp)) { New-Item -ItemType Directory -Force -Path $srcApp | Out-Null }

$layoutPath = Join-Path $srcApp 'layout.tsx'
if (-not (Test-Path $layoutPath)) {
  $layoutCode = @"
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang=\"en\"><body style={{fontFamily:'system-ui'}}>{children}</body></html>
  );
}
"@
  Set-Content -LiteralPath $layoutPath -Value $layoutCode -Encoding UTF8
}

$pagePath = Join-Path $srcApp 'page.tsx'
if (-not (Test-Path $pagePath)) {
  $pageCode = @"
export default function Home() {
  return (
    <main style={{padding:24,fontFamily:'system-ui'}}>
      <h1>Socint Frontend (prod)</h1>
      <p>/api/health should return JSON.</p>
    </main>
  );
}
"@
  Set-Content -LiteralPath $pagePath -Value $pageCode -Encoding UTF8
}

$apiDir = Join-Path $srcApp 'api\health'
if (-not (Test-Path $apiDir)) { New-Item -ItemType Directory -Force -Path $apiDir | Out-Null }

$routePath = Join-Path $apiDir 'route.ts'
if (-not (Test-Path $routePath)) {
  $routeCode = @"
export const runtime = 'nodejs';
import { NextResponse } from 'next/server';
import { randomUUID } from 'crypto';
export async function GET() {
  const req_id = randomUUID();
  return NextResponse.json({ ok: true, service: 'socint-frontend', req_id, ts: new Date().toISOString() }, { status: 200 });
}
"@
  Set-Content -LiteralPath $routePath -Value $routeCode -Encoding UTF8
}

$scaffoldWritten = (Test-Path $layoutPath) -and (Test-Path $pagePath) -and (Test-Path $routePath)
J 'info' 'scaffold' 'Scaffold status' @{ layout=$layoutPath; page=$pagePath; route=$routePath; ok=$scaffoldWritten }

# 2) stop previous server if running
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $p = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($p) {
      try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {}
      Start-Sleep -Milliseconds 300
      J 'info' 'stop.prev' 'Stopped previous Next server' @{ oldPid=$old }
    }
  }
}

# 3) build
$cmdExe = $env:ComSpec; if (-not $cmdExe) { $cmdExe = 'C:\Windows\System32\cmd.exe' }
$buildCmd = '"' + $pnpmCmd + '"' + ' build'
$buildOk = $false
try {
  $pBuild = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
            -ArgumentList '/d','/s','/c', $buildCmd `
            -PassThru -NoNewWindow -Wait `
            -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
  $exitBuild = 0
  try { $exitBuild = $pBuild.ExitCode } catch {}
  $buildOk = ($exitBuild -eq 0)
  $level = if ($buildOk) { 'info' } else { 'warn' }
  J $level 'build.done' 'Build finished' @{ ok=$buildOk; exit=$exitBuild; out=$buildOut; err=$buildErr }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_"; out=$buildOut; errlog=$buildErr }
}

# 4) free port if busy
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) {
    try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 300
    J 'warn' 'port.free' 'Freed busy port 3001' @{ ownerPid=$c.OwningProcess }
  }
} catch {}

# 5) start prod server
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
    $level = if ($startOk) { 'info' } else { 'warn' }
    J $level 'start.spawn' 'Started Next prod server' @{ ok=$startOk; procId=$procId; port=$port; out=$startOut; err=$startErr }
  } catch {
    J 'error' 'start.fail' 'Start-Process failed for next start' @{ err="$_"; out=$startOut; errlog=$startErr }
  }
}

# 6) probe /api/health
$probeOk = $false; $status=0; $tries=0; $why=''
if ($startOk) {
  while (-not $probeOk -and $tries -lt 60) {
    Start-Sleep -Milliseconds 700
    $tries++
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch { $status = -1; $why = "$_" }
  }
}
$level = if ($probeOk) { 'info' } else { 'warn' }
J $level 'probe.api' 'Probe /api/health after scaffold' @{ ok=$probeOk; port=$port; status=$status; tries=$tries; why=$why }

# 7) summary
$ready = ($scaffoldWritten -and $buildOk -and $startOk -and $probeOk)
$summary = [ordered]@{
  scaffold_written  = $scaffoldWritten
  build_ok          = $buildOk
  start_ok          = $startOk
  probe_api_ok      = $probeOk
  dev_pid           = $procId
  dev_port          = $port
  layout_path       = $layoutPath
  page_path         = $pagePath
  route_path        = $routePath
  build_log_out     = $buildOut
  build_log_err     = $buildErr
  start_log_out     = $startOut
  start_log_err     = $startErr
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1f scaffold+restart summary' $summary

Write-Host ("`n== S5.1f Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
