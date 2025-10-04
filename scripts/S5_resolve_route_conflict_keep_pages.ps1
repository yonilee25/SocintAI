# C:\SocintAI\scripts\S5_resolve_route_conflict_keep_pages.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId   = [guid]::NewGuid().ToString()
$started = Get-Date

# Paths
$root    = 'C:\SocintAI'
$feRoot  = Join-Path $root 'frontend'
$app     = Join-Path $feRoot 'socint-frontend'
$logDir  = Join-Path $root 'logs'
$runDir  = Join-Path $root '.run'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -Type Directory -Force -Path $runDir | Out-Null }

$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_resolve_route_conflict_keep_pages_{0}.log" -f $ts)
$buildOut= Join-Path $logDir ("next_build_conflictfix_{0}.out.log" -f $ts)
$buildErr= Join-Path $logDir ("next_build_conflictfix_{0}.err.log" -f $ts)
$startOut= Join-Path $logDir ("next_start_conflictfix_A_{0}.out.log" -f $ts)
$startErr= Join-Path $logDir ("next_start_conflictfix_A_{0}.err.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'
$port    = 3001

function J { param($lvl,$op,$msg,$data=@{})
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.resolve_route_conflict_keep_pages'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Remove app route (keep pages API) → rebuild → start → probe' @{ app=$app; user=$env:UserName }

# 0) sanity
$pkg = Join-Path $app 'package.json'
if (-not (Test-Path $pkg)) { throw "Next app not found at $app" }

# 1) remove App Router’s /api/health route (backup first)
$appRoute = Join-Path $app 'src\app\api\health\route.ts'
$appRouteRemoved = $false
$appRouteBackup  = $null
if (Test-Path $appRoute) {
  $appRouteBackup = $appRoute + ('.removed_{0}.bak' -f $ts)
  Copy-Item -LiteralPath $appRoute -Destination $appRouteBackup -Force
  Remove-Item -LiteralPath $appRoute -Force
  $appRouteRemoved = $true
}
J 'info' 'route.remove' 'App router /api/health removed (kept Pages API)' @{ removed=$appRouteRemoved; backup=$appRouteBackup; path=$appRoute }

# 2) stop old server, clear .next
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} }
}
$nextDir = Join-Path $app '.next'
if (Test-Path $nextDir) { try { Remove-Item -Recurse -Force -LiteralPath $nextDir } catch {} }

# 3) resolve pnpm path
$pnpm = $null
try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpm) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpm) { throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpm }

# 4) rebuild (synchronous)
$cmd = $env:ComSpec; if (-not $cmd) { $cmd = 'C:\Windows\System32\cmd.exe' }
$buildCmd = '"' + $pnpm + '"' + ' run -s build'
$buildOk = $false; $exitBuild = -999
try {
  $pBuild = Start-Process -FilePath $cmd -WorkingDirectory $app `
            -ArgumentList '/d','/s','/c', $buildCmd `
            -PassThru -NoNewWindow -Wait `
            -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
  try { $exitBuild = $pBuild.ExitCode } catch {}
  $buildOk = ($exitBuild -eq 0)
  J ($buildOk ? 'info' : 'warn') 'build.done' 'Build finished' @{ ok=$buildOk; exit=$exitBuild; out=$buildOut; err=$buildErr }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_" }
}

# 5) free port & start Next correctly (pnpm exec next start)
$startOk = $false; $nodePid = $null
if ($buildOk) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($c) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  $arg = '"' + $pnpm + '"' + ' exec next start -p 3001 -H 127.0.0.1'
  $p = Start-Process -FilePath $cmd -WorkingDirectory $app `
        -ArgumentList '/d','/s','/c', $arg `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $startOut -RedirectStandardError $startErr
  Start-Sleep -Milliseconds 1200
  if ($p -and -not $p.HasExited) { $startOk = $true }
  J ($startOk ? 'info' : 'warn') 'start.spawn' 'cmd wrapper started' @{ ok=$startOk; out=$startOut; err=$startErr }
}

# 6) wait for port & probe
$listening = $false; $tries=0
while (-not $listening -and $tries -lt 60) {
  Start-Sleep -Milliseconds 600; $tries++
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
      $listening = $true
      $nodePid = $conn.OwningProcess
      Set-Content -LiteralPath $pidFile -Value $nodePid -Encoding ASCII
    }
  } catch {}
}
$probeOk = $false; $status=0; $why=''
if ($listening) {
  $tries = 0
  while (-not $probeOk -and $tries -lt 40) {
    Start-Sleep -Milliseconds 600; $tries++
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:3001/api/health' -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch { $status = -1; $why = "$($_.Exception.Message)" }
  }
}
J ($probeOk ? 'info' : 'warn') 'probe' 'GET /api/health' @{ ok=$probeOk; status=$status; why=$why }

# 7) summary
$ready = ($appRouteRemoved -and $buildOk -and $startOk -and $listening -and $probeOk)
$summary = [ordered]@{
  app_route_removed    = $appRouteRemoved
  app_route_backup     = $appRouteBackup
  build_ok             = $buildOk
  start_ok             = $startOk
  port_3001_listening  = $listening
  node_pid             = $nodePid
  probe_api_ok         = $probeOk
  logs = @{
    build_out = $buildOut; build_err = $buildErr
    start_out = $startOut; start_err = $startErr
  }
  pid_file             = $pidFile
  log_file             = $stepLog
  duration_ms          = [int]((Get-Date) - $started).TotalMilliseconds
  ready_for_S5_2       = $ready
}
J ($ready ? 'info' : 'warn') 'summary' 'S5.1p4 conflict-resolve summary' $summary

Write-Host ("`n== S5.1p4 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
