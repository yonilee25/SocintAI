# C:\SocintAI\scripts\S5_read_start_logs_and_tree.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
$logDir  = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_read_start_logs_and_tree_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.read_start_logs_and_tree'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Read start logs and list built app tree' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) find newest start logs (both our variants)
$startOut = Get-ChildItem (Join-Path $logDir 'next_start*_A_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$startErr = Get-ChildItem (Join-Path $logDir 'next_start*_A_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$outTail=@(); $errTail=@(); $outPath=$null; $errPath=$null
if ($startOut) { $outPath=$startOut.FullName; try { $outTail = Get-Content $outPath -Tail 120 } catch {} }
if ($startErr) { $errPath=$startErr.FullName; try { $errTail = Get-Content $errPath -Tail 120 } catch {} }
J 'info' 'logs.tail' 'Start log tails' @{ out=$outPath; err=$errPath; out_tail=$outTail; err_tail=$errTail }

# 2) list .next\server\app contents (top-level) + route glob
$serverApp = Join-Path $appRoot '.next\server\app'
$topList = @()
if (Test-Path $serverApp) {
  try {
    $topList = Get-ChildItem $serverApp -ErrorAction SilentlyContinue | Select-Object -First 50 -ExpandProperty Name
  } catch {}
}
$routeMatches = @()
try {
  if (Test-Path $serverApp) {
    $routeMatches = Get-ChildItem $serverApp -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^route\.(m?js|cjs)$' -and $_.FullName -match '\\api\\health\\' } |
      Select-Object -ExpandProperty FullName
  }
} catch {}
J 'info' 'tree' '.next/server/app snapshot + route matches' @{ server_app=$serverApp; top_level=$topList; route_glob_matches=$routeMatches }

# 3) inference
$inf = 'unknown'
if (-not (Test-Path $serverApp)) { $inf='no-server-app-build' }
elseif ($routeMatches.Count -eq 0) { $inf='route-not-built' }
elseif ($errTail -match 'Error|ERR|EADDRINUSE|Cannot find|Failed') { $inf='server-error-see-logs' }
elseif ($outTail -match 'ready - started server|started server|Local:\s*http://') { $inf='server-started-unknown-api' }

# 4) summary
$summary = [ordered]@{
  start_out_tail = $outTail
  start_err_tail = $errTail
  app_server_tree_sample = $topList
  route_glob_matches = $routeMatches
  inference = $inf
  log_file = $stepLog
  duration_ms = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2 = $false
}
J 'info' 'summary' 'S5.1h logs+tree summary' $summary

Write-Host ("`n== S5.1h Health: READY (see {0})" -f $stepLog)
