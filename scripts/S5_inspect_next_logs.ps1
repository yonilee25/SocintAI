param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir   = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$stepLog  = Join-Path $logDir ("S5_inspect_next_logs_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.inspect_next_logs'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Inspecting latest Next dev logs for failure patterns' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# locate latest stdout/stderr logs created by S5_run_next_dev_cmdwrap.ps1
$lastOut = Get-ChildItem (Join-Path $logDir 'next_dev_A_*.out.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$lastErr = Get-ChildItem (Join-Path $logDir 'next_dev_A_*.err.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$outFile = $null; $errFile = $null; $outTail=@(); $errTail=@()
if ($lastOut) { $outFile = $lastOut.FullName; try { $outTail = Get-Content $outFile -Tail 120 } catch {} }
if ($lastErr) { $errFile = $lastErr.FullName; try { $errTail = Get-Content $errFile -Tail 120 } catch {} }

# join text for pattern scans
$outText = if ($outTail) { [string]::Join("`n",$outTail) } else { "" }
$errText = if ($errTail) { [string]::Join("`n",$errTail) } else { "" }
$both    = $outText + "`n" + $errText

# pattern scans (broad but useful)
$eaddrinuse        = ($both -match '(EADDRINUSE|address.*already.*in use|Port.*in use)')
$moduleNotFound    = ($both -match 'Module not found|Cannot find module')
$compileFailed     = ($both -match 'Failed to compile|Build failed|error.*compil')
$api404            = ($both -match 'GET\s+/api/health\s+404|api/health.+(not found|404)')
$edgeRuntimeIssue  = ($both -match 'Edge runtime.*not support|Edge Runtime.*crypto|Web Crypto API.*not available')
$npmPnpmFailure    = ($both -match 'ELIFECYCLE|command failed|Exit status|ERR!')
$nextReady         = ($both -match 'ready - started server|Started server|Local:\s*http://')

# guess likely cause
$likely = 'unknown'
if ($eaddrinuse)        { $likely = 'port-in-use' }
elseif ($moduleNotFound) { $likely = 'module-not-found' }
elseif ($compileFailed)  { $likely = 'compile-failed' }
elseif ($edgeRuntimeIssue){ $likely = 'edge-runtime-mismatch' }
elseif ($api404 -and $nextReady){ $likely = 'route-not-loaded' }
elseif ($nextReady -and -not $api404){ $likely = 'server-started-other-issue' }
elseif (-not $nextReady -and -not [string]::IsNullOrWhiteSpace($both)) { $likely = 'server-exited-early' }

# summary
$summary = [ordered]@{
  out_file            = $outFile
  err_file            = $errFile
  out_tail            = $outTail
  err_tail            = $errTail
  patterns = @{
    eaddrinuse       = $eaddrinuse
    module_not_found = $moduleNotFound
    compile_failed   = $compileFailed
    api_404          = $api404
    edge_runtime_issue = $edgeRuntimeIssue
    npm_pnpm_failure = $npmPnpmFailure
    next_ready       = $nextReady
  }
  likely_cause        = $likely
  log_file            = $stepLog
  duration_ms         = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2      = $false
}
J 'info' 'summary' 'S5.1e inspect summary' $summary

Write-Host ("`n== S5.1e Health: READY (see {0})" -f $stepLog)
