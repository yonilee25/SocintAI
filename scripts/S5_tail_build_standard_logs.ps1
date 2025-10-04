# C:\SocintAI\scripts\S5_tail_build_standard_logs.ps1  (PS7-safe; null-safe)
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$root   = 'C:\SocintAI'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_tail_build_standard_logs_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S5.tail_build_standard';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Tailing standard build logs (next_build_standard_*.log)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Locate most recent standard build log (from previous step)
$buildLog = Get-ChildItem (Join-Path $logDir 'next_build_standard_*.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Desc | Select-Object -First 1
$logPath  = $null; $tail=@()
if ($buildLog) { $logPath = $buildLog.FullName; try { $tail = Get-Content $logPath -Tail 200 } catch {} }
J 'info' 'log.path' 'Build log path' @{ path=$logPath }

# Pattern scans (combine to one text blob)
$text = [string]::Join("`n", @($tail))

$tsError          = ($text -match 'TS\d{3,5}:|Type error|Cannot find name|is not assignable|Type .* is not assignable')
$moduleNotFound   = ($text -match 'Module not found|Cannot find module')
$nextConfigErr    = ($text -match 'next\.config|Failed to load config|SyntaxError|Unexpected token')
$eslintError      = ($text -match 'ESLint' -and $text -match 'Error')
$edgeRuntime      = ($text -match 'Edge Runtime|Web Crypto API|unsupported runtime')
$memoryOut        = ($text -match 'JavaScript heap out of memory|FATAL ERROR: Reached heap limit')
$nodeVersionHint  = ($text -match 'requires Node|current: v|Node\.js version')
$missingBuildMsg  = ($text -match 'Could not find a production build|Run .*next build')

$likely = 'unknown'
if     ($tsError)         { $likely = 'typescript-compile' }
elseif ($moduleNotFound)  { $likely = 'module-missing' }
elseif ($nextConfigErr)   { $likely = 'next-config-error' }
elseif ($eslintError)     { $likely = 'eslint-error' }
elseif ($edgeRuntime)     { $likely = 'edge-runtime' }
elseif ($memoryOut)       { $likely = 'memory' }
elseif ($nodeVersionHint) { $likely = 'node-version' }
elseif ($missingBuildMsg) { $likely = 'no-build' }
elseif ([string]::IsNullOrWhiteSpace($text)) { $likely = 'empty-logs' }

$summary = [ordered]@{
  out_path        = $logPath
  out_tail        = $tail
  flags = @{
    ts_error          = $tsError
    module_not_found  = $moduleNotFound
    next_config_error = $nextConfigErr
    eslint_error      = $eslintError
    edge_runtime      = $edgeRuntime
    memory_out        = $memoryOut
    node_version_hint = $nodeVersionHint
    missing_build_msg = $missingBuildMsg
  }
  likely_cause  = $likely
  log_file      = $stepLog
  duration_ms   = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1p5.log standard build tail summary' $summary

Write-Host ("`n== S5.1p5.log Health: READY (see {0})" -f $stepLog)
