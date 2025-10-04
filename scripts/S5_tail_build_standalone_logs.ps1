# C:\SocintAI\scripts\S5_tail_build_standalone_logs.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date
$root  = 'C:\SocintAI'
$logDir= Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_tail_build_standalone_logs_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S5.tail_build_standalone';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Tailing next_build_standalone logs' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# find newest standalone build logs; fall back to any next_build*.*
$buildOut = Get-ChildItem (Join-Path $logDir 'next_build_standalone_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$buildErr = Get-ChildItem (Join-Path $logDir 'next_build_standalone_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if (-not $buildOut) { $buildOut = Get-ChildItem (Join-Path $logDir 'next_build_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1 }
if (-not $buildErr) { $buildErr = Get-ChildItem (Join-Path $logDir 'next_build_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1 }

$outPath = $null; $errPath = $null
if ($buildOut) { $outPath = $buildOut.FullName }
if ($buildErr) { $errPath = $buildErr.FullName }

$outTail = @(); $errTail = @()
try { if ($outPath -and (Test-Path $outPath)) { $outTail = Get-Content $outPath -Tail 150 } } catch {}
try { if ($errPath -and (Test-Path $errPath)) { $errTail = Get-Content $errPath -Tail 150 } } catch {}
J 'info' 'logs' 'Collected build log tails' @{ out=$outPath; err=$errPath }

# pattern scan
$text = [string]::Join("`n", @($outTail + $errTail))
$tsError          = ($text -match 'TS\d{3,5}:|Type error|Cannot find name|Cannot find module.+\.ts')
$missingTypes     = ($text -match '@types/react|@types/node|type definitions|Cannot find type declarations')
$moduleNotFound   = ($text -match 'Module not found|Cannot find module')
$edgeRuntime      = ($text -match 'Edge Runtime|Web Crypto API|unsupported runtime')
$nextConfigErr    = ($text -match 'next\.config|Failed to load config|SyntaxError|Unexpected token')
$invalidRoute     = ($text -match 'API route|conflicts|duplicated route|Invalid path')
$eslintBlock      = ($text -match 'ESLint' -and $text -match 'Error')
$memoryOut        = ($text -match 'JavaScript heap out of memory|FATAL ERROR: Reached heap limit')
$nodeVersion      = ($text -match 'Node\.js version|requires Node|current: v')

$likely = 'unknown'
if ($tsError -or $missingTypes)      { $likely = 'typescript-compile' }
elseif ($moduleNotFound)             { $likely = 'module-missing' }
elseif ($nextConfigErr)              { $likely = 'next-config-error' }
elseif ($invalidRoute)               { $likely = 'route-conflict' }
elseif ($edgeRuntime)                { $likely = 'edge-runtime-mismatch' }
elseif ($eslintBlock)                { $likely = 'eslint-error' }
elseif ($memoryOut)                  { $likely = 'memory' }
elseif ($nodeVersion)                { $likely = 'node-version' }
elseif ([string]::IsNullOrWhiteSpace($text)) { $likely = 'empty-logs' }

$summary = [ordered]@{
  out_tail        = $outTail
  err_tail        = $errTail
  flags = @{
    ts_error          = $tsError
    missing_types     = $missingTypes
    module_not_found  = $moduleNotFound
    next_config_error = $nextConfigErr
    route_invalid     = $invalidRoute
    edge_runtime      = $edgeRuntime
    eslint_error      = $eslintBlock
    memory_out        = $memoryOut
    node_version_hint = $nodeVersion
  }
  likely_cause  = $likely
  log_file      = $stepLog
  duration_ms   = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1p2.log standalone build tail summary' $summary

Write-Host ("`n== S5.1p2.log Health: READY (see {0})" -f $stepLog)
