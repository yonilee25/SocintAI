# C:\SocintAI\scripts\S5_verify_artifacts_and_probe.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir  = Join-Path $repoRoot 'logs'
$runDir  = Join-Path $repoRoot '.run'
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_verify_artifacts_and_probe_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{})
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.verify_artifacts_and_probe'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Verifying build artifacts + live HTTP codes + start-log tails' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) Build artifact: route in .next/server/app/**/api/health/route.*
$buildDir = Join-Path $appRoot '.next\server\app'
$routeFile = $null
if (Test-Path $buildDir) {
  try {
    $routeFile = Get-ChildItem $buildDir -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^route\.(m?js|cjs)$' -and $_.FullName -match '\\api\\health\\' } |
      Select-Object -First 1 -ExpandProperty FullName
  } catch {}
}
$buildRouteFound = [bool]$routeFile
J 'info' 'artifact' 'Build route artifact check' @{ found=$buildRouteFound; path=$routeFile }

# 2) Running PID + listening port(s)
$pidRunning=$false; $pidVal=$null; $ports=@()
if (Test-Path $pidFile) {
  $pidVal = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($pidVal) {
    $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    $pidRunning = ($p -ne $null)
    if ($pidRunning) {
      try {
        $ports = Get-NetTCPConnection -OwningProcess $pidVal -State Listen -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty LocalPort
      } catch {}
    }
  }
}
$ports = @($ports | Sort-Object -Unique)
$chosenPort = 0
if ($ports -contains 3001) { $chosenPort = 3001 }
elseif ($ports -contains 3003) { $chosenPort = 3003 }
elseif ($ports.Count -gt 0) { $chosenPort = $ports[0] }
J 'info' 'server' 'Server runtime status' @{ pid=$pidVal; pid_running=$pidRunning; listening_ports=$ports; chosen_port=$chosenPort }

# 3) HTTP probes (capture codes)
function ProbeCode([int]$port,[string]$path) {
  $o = @{ code = 0; why = ''; url = ("http://127.0.0.1:{0}{1}" -f $port,$path) }
  try {
    $r = Invoke-WebRequest -Uri $o.url -TimeoutSec 5
    $o.code = [int]$r.StatusCode
  } catch {
    $o.code = -1
    $o.why  = "$_"
  }
  return $o
}
$root = @{ code=0; url=''; why='' }; $api=@{ code=0; url=''; why='' }
if ($chosenPort -ne 0) {
  $root = ProbeCode -port $chosenPort -path '/'
  $api  = ProbeCode -port $chosenPort -path '/api/health'
}
J 'info' 'probe' 'HTTP probe results' @{ root=$root; api=$api }

# 4) tail start logs if present
$startOut = Get-ChildItem (Join-Path $logDir 'next_start*_A_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$startErr = Get-ChildItem (Join-Path $logDir 'next_start*_A_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$outTail=@(); $errTail=@(); $outPath=$null; $errPath=$null
if ($startOut) { $outPath=$startOut.FullName; try { $outTail = Get-Content $outPath -Tail 120 } catch {} }
if ($startErr) { $errPath=$startErr.FullName; try { $errTail = Get-Content $errPath -Tail 120 } catch {} }
J 'info' 'logs' 'Start log tails' @{ out=$outPath; err=$errPath }

# 5) inference
$likely='unknown'
if (-not $buildRouteFound) { $likely='route-missing-in-build' }
elseif (-not $pidRunning -or $chosenPort -eq 0) { $likely='server-not-running' }
elseif ($root.code -eq 200 -and $api.code -eq 404) { $likely='route-not-loaded-404' }
elseif ($root.code -eq -1 -or $api.code -eq -1) { $likely='connection-failed' }
elseif ($root.code -eq 200 -and $api.code -eq 200) { $likely='ok' }

# 6) summary
$ready = ($api.code -eq 200)
$summary = [ordered]@{
  build_route_found = $buildRouteFound
  build_route_path  = $routeFile
  pid_running       = $pidRunning
  port_listening    = ($chosenPort -ne 0)
  chosen_port       = $chosenPort
  root_code         = $root.code
  api_code          = $api.code
  likely_cause      = $likely
  start_out_tail    = $outTail
  start_err_tail    = $errTail
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1g artifacts+probe summary' $summary

Write-Host ("`n== S5.1g Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
