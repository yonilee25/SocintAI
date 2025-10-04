# C:\SocintAI\scripts\S5_tail_next_start_logs.ps1  (PS7-safe, null-safe tails)
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repo   = 'C:\SocintAI'
$logDir = Join-Path $repo 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_tail_next_start_logs_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.tail_next_start_logs'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Tailing latest next_start_correct logs (null-safe)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

$out = Get-ChildItem (Join-Path $logDir 'next_start_correct_A_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$err = Get-ChildItem (Join-Path $logDir 'next_start_correct_A_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1

$outPath = if ($out) { $out.FullName } else { $null }
$errPath = if ($err) { $err.FullName } else { $null }

$outTail = @()
$errTail = @()
try { if ($outPath -and (Test-Path $outPath)) { $outTail = Get-Content $outPath -Tail 120 } } catch {}
try { if ($errPath -and (Test-Path $errPath)) { $errTail = Get-Content $errPath -Tail 120 } } catch {}

J 'info' 'logs' 'Collected log tails' @{ out=$outPath; err=$errPath }

# Pattern scans on safely-joined text
$text = [string]::Join("`n", @($outTail + $errTail))
$invalidArg       = ($text -match 'Unknown argument|Invalid option|Did you mean')
$bindError        = ($text -match 'EADDRINUSE|EACCES|listen EACCES|bind EACCES|address.*in use')
$moduleNotFound   = ($text -match 'Module not found|Cannot find module')
$missingBuild     = ($text -match 'Could not find a production build|Run .*next build')
$permissionError  = ($text -match 'EPERM|permission denied|Access is denied')
$readyLine        = ($text -match 'ready - started server|Started server|Local:\s*http://')

$likely = 'unknown'
if     ($missingBuild)   { $likely = 'no-build' }
elseif ($invalidArg)     { $likely = 'invalid-args' }
elseif ($bindError)      { $likely = 'port-bind' }
elseif ($moduleNotFound) { $likely = 'module-missing' }
elseif ($permissionError){ $likely = 'permission' }
elseif ($readyLine)      { $likely = 'server-ready-but-other-issue' }

$summary = [ordered]@{
  out_tail        = $outTail
  err_tail        = $errTail
  invalid_arg     = $invalidArg
  bind_error      = $bindError
  module_not_found= $moduleNotFound
  missing_build   = $missingBuild
  permission_error= $permissionError
  server_ready_log= $readyLine
  likely_cause    = $likely
  log_file        = $stepLog
  duration_ms     = [int]((Get-Date) - $start).TotalMilliseconds
}
J 'info' 'summary' 'S5.1n.log tail summary' $summary

Write-Host ("`n== S5.1n.log Health: READY (see {0})" -f $stepLog)
