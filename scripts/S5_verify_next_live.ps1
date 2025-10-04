param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir  = Join-Path $repoRoot 'logs'
$runDir  = Join-Path $repoRoot '.run'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_verify_next_live_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.verify_next_live'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Verifying live Next dev: PID, ports, health, log tails' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# 1) load PID
$pidPresent=$false; $pidRunning=$false; $pidVal=$null
if (Test-Path $pidFile) {
  $pidVal = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($pidVal) {
    $pidPresent = $true
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    $pidRunning = ($proc -ne $null)
  }
}
J 'info' 'pid' 'PID status' @{ pid_file=$pidFile; pid_present=$pidPresent; pid_running=$pidRunning; pid=$pidVal }

# 2) list ports by PID
$ports=@()
if ($pidRunning) {
  try {
    $ports = Get-NetTCPConnection -OwningProcess $pidVal -State Listen -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty LocalPort
  } catch {}
}
$ports = @($ports | Sort-Object -Unique)
J 'info' 'ports' 'Listening ports by PID' @{ pid=$pidVal; ports=$ports }

# choose candidate port (prefer 3001, then 3003, else first)
$candidatePort = 0
if ($ports -contains 3001) { $candidatePort = 3001 }
elseif ($ports -contains 3003) { $candidatePort = 3003 }
elseif ($ports.Count -gt 0) { $candidatePort = $ports[0] }

# 3) probe helpers
function Probe {
  param([int]$port,[string]$path)
  $o=[ordered]@{ url=("http://127.0.0.1:{0}{1}" -f $port, $path); ok=$false; code=0; why='' }
  try {
    $r = Invoke-WebRequest -Uri $o.url -TimeoutSec 3
    $o.ok = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
  } catch { $o.ok=$false; $o.code=-1; $o.why="$_" }
  return $o
}

$root = @{ ok=$false; code=0; url='' }; $api=@{ ok=$false; code=0; url='' }
if ($candidatePort -ne 0) {
  $root = Probe -port $candidatePort -path '/'
  $api  = Probe -port $candidatePort -path '/api/health'
}

# 4) tail dev logs (stdout + stderr)
$lastOut = Get-ChildItem (Join-Path $logDir 'next_dev_A_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$lastErr = Get-ChildItem (Join-Path $logDir 'next_dev_A_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$outFile = $null; $errFile = $null; $outTail=@(); $errTail=@()
if ($lastOut) { $outFile = $lastOut.FullName; try {$outTail = Get-Content $outFile -Tail 80 } catch {} }
if ($lastErr) { $errFile = $lastErr.FullName; try {$errTail = Get-Content $errFile -Tail 80 } catch {} }
J 'info' 'log.tail' 'Dev log tails' @{ out=$outFile; err=$errFile }

# 5) quick inference
$likely='unknown'
if (-not $pidPresent -or -not $pidRunning) { $likely='server-not-running' }
elseif ($candidatePort -eq 0 -or $ports.Count -eq 0) { $likely='no-listen-port' }
elseif (-not $root.ok -and -not $api.ok) { $likely='server-not-ready-or-port-mismatch' }
elseif ($root.ok -and -not $api.ok) { $likely='route-not-loaded-or-404' }
elseif ($api.ok) { $likely='ok' }

# 6) summary
$ready = ($root.ok -and $api.ok)
$summary = [ordered]@{
  pid_present      = $pidPresent
  pid_running      = $pidRunning
  pid              = $pidVal
  listening_ports  = $ports
  chosen_port      = $candidatePort
  http_root_ok     = $root.ok
  http_root_code   = $root.code
  http_api_ok      = $api.ok
  http_api_code    = $api.code
  likely_cause     = $likely
  out_tail         = $outTail
  err_tail         = $errTail
  log_file         = $stepLog
  duration_ms      = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2   = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1d verify-live summary' $summary

Write-Host ("`n== S5.1d Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
