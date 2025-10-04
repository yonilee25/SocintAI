param()

$ErrorActionPreference = 'Stop'
$req = [guid]::NewGuid().ToString()
$start = Get-Date

$root = 'C:\SocintAI'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_tail_conflictpurge_log_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.tail_conflictpurge_log'; req_id=$req; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Tailing latest next_build_conflictpurge_*.log' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

$buildLog = Get-ChildItem (Join-Path $logDir 'next_build_conflictpurge_*.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Desc | Select-Object -First 1
$path = $null; $tail=@()
if ($buildLog) { $path = $buildLog.FullName; try { $tail = Get-Content $path -Tail 200 } catch {} }
J 'info' 'log.path' 'Build log path' @{ path=$path }

$text = [string]::Join("`n", @($tail))

# classify common causes
$conflictAppVsPages = ($text -match 'Conflicting app and page file .* "pages/api/health\.ts" .* "app/api/health/route\.ts"')
$stillHasAppRoute   = ($text -match 'app/api/health/route')
$tsError            = ($text -match 'TS\d{3,5}:|Type error|Cannot find name')
$moduleNotFound     = ($text -match 'Module not found|Cannot find module')
$emptyLogs          = [string]::IsNullOrWhiteSpace($text)

$likely = 'unknown'
if ($conflictAppVsPages -or $stillHasAppRoute) { $likely = 'router-conflict' }
elseif ($tsError)          { $likely = 'typescript-compile' }
elseif ($moduleNotFound)   { $likely = 'module-missing' }
elseif ($emptyLogs)        { $likely = 'empty-logs' }

$summary = [ordered]@{
  build_log_path = $path
  tail           = $tail
  flags = @{
    router_conflict   = ($conflictAppVsPages -or $stillHasAppRoute)
    ts_error          = $tsError
    module_not_found  = $moduleNotFound
    empty_logs        = $emptyLogs
  }
  likely_cause   = $likely
  log_file       = $stepLog
  duration_ms    = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1p6.log tail summary' $summary
