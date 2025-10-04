param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$root   = 'C:\SocintAI'
$repo   = $root
$logDir = Join-Path $repo 'logs'
$runDir = Join-Path $repo '.run'
$feRoot = Join-Path $repo 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_runtime_probe_multi_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.runtime_probe_multi'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Runtime multi-port probe + build route checks' @{ user=$env:UserName; machine=$env:COMPUTERNAME; app=$app }

# 1) read current Next PID
$pidFile = Join-Path $runDir 'next_A.pid'
$procId = $null; $procRunning=$false
if (Test-Path $pidFile) {
  $procId = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($procId) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $procRunning = ($p -ne $null)
  }
}
J 'info' 'pid' 'PID status' @{ pid_file=$pidFile; pid=$procId; running=$procRunning }

# 2) discover listening ports for this PID
$ports=@()
if ($procRunning) {
  try {
    $ports = Get-NetTCPConnection -OwningProcess $procId -State Listen -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty LocalPort
  } catch {}
}
$ports = @($ports | Sort-Object -Unique)
J 'info' 'ports' 'Ports by PID' @{ pid=$procId; ports=$ports }

# 3) probe root + /api/health across candidates
function Probe($port, $path) {
  $o=[ordered]@{ port=$port; path=$path; code=0; why='' }
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}{1}" -f $port,$path) -TimeoutSec 4
    $o.code = [int]$r.StatusCode
  } catch {
    $o.code = -1
    $o.why  = "$_"
  }
  return $o
}
$candidates = @()
$candidates += $ports
foreach ($p in @(3001,3003,3000)) { if (-not ($candidates -contains $p)) { $candidates += $p } }
$candidates = @($candidates | Sort-Object -Unique)

$probes = @()
foreach ($p in $candidates) {
  $probes += (Probe -port $p -path '/')
  $probes += (Probe -port $p -path '/api/health')
}
J 'info' 'probes' 'Multi-port probes complete' @{ candidates=$candidates; results=$probes }

# 4) check build outputs for both app-router and pages-router APIs
$appServerDir   = Join-Path $app '.next\server\app'
$pagesServerDir = Join-Path $app '.next\server\pages'
$builtAppRoute  = $null
$builtPagesRt   = $null

if (Test-Path $appServerDir) {
  try {
    $builtAppRoute = Get-ChildItem $appServerDir -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\api\\health\\' -and $_.Name -match '^route\.(m?js|cjs)$' } |
      Select-Object -First 1 -ExpandProperty FullName
  } catch {}
}

if (Test-Path $pagesServerDir) {
  try {
    $builtPagesRt = Get-ChildItem $pagesServerDir -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\api\\health(\.js|\.mjs|\.cjs)$' -or $_.Name -eq 'health.js' -or $_.Name -eq 'health.mjs' -or $_.Name -eq 'health.cjs' } |
      Select-Object -First 1 -ExpandProperty FullName
  } catch {}
}

J 'info' 'build.scan' 'Built route presence' @{ built_app_route=$builtAppRoute; built_pages_route=$builtPagesRt; app_dir=$appServerDir; pages_dir=$pagesServerDir }

# 5) inference
$inference = 'unknown'
# look for any port that serves root 200 but api 404 — route missing
$root200   = $probes | Where-Object { $_.path -eq '/' } | Where-Object { $_.code -eq 200 }
$api200    = $probes | Where-Object { $_.path -eq '/api/health' } | Where-Object { $_.code -eq 200 }
$api404    = $probes | Where-Object { $_.path -eq '/api/health' } | Where-Object { $_.code -eq 404 }
if (-not $procRunning) { $inference = 'server-not-running' }
elseif ($api200.Count -gt 0) { $inference = 'ok' }
elseif ($root200.Count -gt 0 -and $api404.Count -gt 0) { $inference = 'route-404' }
elseif ($builtPagesRt -or $builtAppRoute) { $inference = 'route-built-but-not-reachable' }
elseif (-not $builtPagesRt -and -not $builtAppRoute) { $inference = 'no-route-built' }

# 6) summary
$summary = [ordered]@{
  proc_running            = $procRunning
  ports_by_pid            = $ports
  probe_results           = $probes
  built_app_route_found   = [bool]$builtAppRoute
  built_app_route_path    = $builtAppRoute
  built_pages_route_found = [bool]$builtPagesRt
  built_pages_route_path  = $builtPagesRt
  inference               = $inference
  log_file                = $stepLog
  duration_ms             = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_fix_step      = $true
}
J 'info' 'summary' 'S5.1m runtime+build summary' $summary

Write-Host ("`n== S5.1m Health: READY (see {0})" -f $stepLog)
