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
$stepLog = Join-Path $logDir ("S5_diag_next_dev_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$lvl; step='S5.diag_next_dev';
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 12
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Diagnosing Next dev start failure' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# pnpm present?
function Pnpm-Detect { try { $v = (pnpm -v) 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() } } catch {}; return $null }
$pnpmVer = Pnpm-Detect
$pnpmOk  = [bool]$pnpmVer
if ($pnpmOk) { J 'info' 'env.pnpm' 'pnpm detection' @{ version=$pnpmVer; ok=$true } } else { J 'warn' 'env.pnpm' 'pnpm not found' @{ ok=$false } }

# next present?
$nextVer=''; $nextOk=$false; $nextOut=$null
try {
  Push-Location $appRoot
  $nextOut = pnpm exec next --version 2>&1
  if ($LASTEXITCODE -eq 0 -and $nextOut) {
    $nextVer = ($nextOut -join "`n").Trim()
    $nextOk=$true
  }
  Pop-Location
} catch { try { Pop-Location } catch {}; $nextOk=$false }
if ($nextOk) { J 'info' 'env.next' 'next --version ok' @{ ok=$true; version=$nextVer } } else { J 'warn' 'env.next' 'next not available' @{ ok=$false } }

# port 3001 listening?
$portListen = $false; $portPid=$null; $portName=$null
try {
  $c = Get-NetTCPConnection -LocalPort 3001 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) {
    $portListen = $true
    $portPid = $c.OwningProcess
    try { $portName = (Get-Process -Id $portPid -ErrorAction SilentlyContinue).ProcessName } catch {}
  }
} catch {}
J 'info' 'port.3001' 'Port 3001 status' @{ listening=$portListen; pid=$portPid; name=$portName }

# spawned PID present/running?
$devPidPresent = $false; $devPidRunning=$false; $devPid=$null
if (Test-Path $pidFile) {
  $devPid = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($devPid) {
    $devPidPresent = $true
    $p = Get-Process -Id $devPid -ErrorAction SilentlyContinue
    $devPidRunning = ($p -ne $null)
  }
}
J 'info' 'pid' 'Spawned PID status' @{ pid_file=$pidFile; present=$devPidPresent; running=$devPidRunning; pid=$devPid }

# dev log tail
$devLog = $null; $devTail = @()
try {
  $devLog = Get-ChildItem (Join-Path $logDir 'next_dev_A_*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
  if ($devLog) { $devTail = Get-Content $devLog.FullName -Tail 60 }
} catch {}
J 'info' 'log.tail' 'Next dev log tail' @{ file=($devLog ? $devLog.FullName : $null); tail=$devTail }

# summary
$summary = [ordered]@{
  pnpm_ok               = $pnpmOk
  next_ok               = $nextOk
  next_version          = $nextVer
  port_3001_listening   = $portListen
  port_3001_pid         = $portPid
  port_3001_name        = $portName
  dev_pid_present       = $devPidPresent
  dev_pid_running       = $devPidRunning
  dev_pid               = $devPid
  dev_log_file          = ($devLog ? $devLog.FullName : $null)
  ready_for_S5_1b       = $true
  log_file              = $stepLog
  duration_ms           = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1a diag summary' $summary

Write-Host ("`n== S5.1a Health: READY (see {0})" -f $stepLog)
