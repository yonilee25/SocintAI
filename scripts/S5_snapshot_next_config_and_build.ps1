# C:\SocintAI\scripts\S5_snapshot_next_config_and_build.ps1  (PS7-safe; no $pid collision)
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
$logDir  = Join-Path $repoRoot 'logs'
$runDir  = Join-Path $repoRoot '.run'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_snapshot_next_config_and_build_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{})
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.snapshot_next_config_and_build'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Snapshot Next config + build outputs + quick runtime sanity' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) Read next.config.*
$configCandidates = @('next.config.ts','next.config.mjs','next.config.js')
$configFile=$null; $configText=$null
foreach ($c in $configCandidates) {
  $p = Join-Path $appRoot $c
  if (Test-Path $p) { $configFile=$p; $configText=(Get-Content $p -Raw); break }
}
$snippet = $null
if ($configText) { $snippet = if ($configText.Length -gt 400) { $configText.Substring(0,400) } else { $configText } }

# Parse output/basePath (supports ' or ")
$outputVal=$null; $basePath=$null
if ($configText) {
  if ($configText -match 'output\s*:\s*["'']([^"'''']+)["'']') { $outputVal = $Matches[1] }
  if ($configText -match 'basePath\s*:\s*["'']([^"'''']+)["'']') { $basePath   = $Matches[1] }
}
J 'info' 'config' 'Parsed next.config values + snippet' @{ file=$configFile; parsed=@{output=$outputVal;basePath=$basePath}; snippet=$snippet }

# 2) Build outputs
$nextServerApp = Join-Path $appRoot '.next\server\app'
$hasNextServer = Test-Path $nextServerApp
$outDir        = Join-Path $appRoot 'out'
$hasOut        = Test-Path $outDir

$builtRoute = $null
if ($hasNextServer) {
  try {
    $builtRoute = Get-ChildItem $nextServerApp -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^route\.(m?js|cjs)$' -and $_.FullName -match '\\api\\health\\' } |
      Select-Object -First 1 -ExpandProperty FullName
  } catch {}
}

# 3) Runtime sanity (avoid $PID collision)
$pidFile = Join-Path $runDir 'next_A.pid'
$procId = $null; $procRunning=$false; $ports=@()
if (Test-Path $pidFile) {
  $procId = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($procId) {
    $pobj = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $procRunning = ($pobj -ne $null)
    if ($procRunning) {
      try {
        $ports = Get-NetTCPConnection -OwningProcess $procId -State Listen -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty LocalPort
      } catch {}
    }
  }
}

# 4) Plan inference
$plan = 'unknown'
if ($outputVal -eq 'export') { $plan = 'config-uses-export-next-start-wont-serve-apis' }
elseif ($hasOut -and -not $hasNextServer) { $plan = 'export-build-detected—switch to server build (no APIs in out/)' }
elseif (-not $builtRoute) { $plan = 'route-missing-in-build—adjust config or folder & rebuild' }
elseif ($basePath) { $plan = 'probe-with-basePath-prefix' }
elseif ($procRunning -and $ports.Count -gt 0) { $plan = 'runtime-ok—reprobe' }

# 5) Summary
$summary = [ordered]@{
  config_file              = $configFile
  config_snippet           = $snippet
  parsed                   = @{ output=$outputVal; basePath=$basePath }
  has_out_dir              = $hasOut
  has_next_server_app      = $hasNextServer
  built_health_route_found = [bool]$builtRoute
  built_health_route_path  = $builtRoute
  pid_running              = $procRunning
  listening_ports          = $ports
  next_fix_plan            = $plan
  log_file                 = $stepLog
  duration_ms              = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1k snapshot summary' $summary

Write-Host ("`n== S5.1k Health: READY (see {0})" -f $stepLog)
