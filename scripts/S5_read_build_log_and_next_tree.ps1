# C:\SocintAI\scripts\S5_read_build_log_and_next_tree.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

$root   = 'C:\SocintAI'
$logDir = Join-Path $root 'logs'
$feRoot = Join-Path $root 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog= Join-Path $logDir ("S5_read_build_log_and_next_tree_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{})
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.read_build_log_and_next_tree'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Reading latest build logs and inspecting .next tree' @{ user=$env:UserName; machine=$env:COMPUTERNAME; app=$app }

# 1) newest build logs (any of our earlier names)
$buildOut = Get-ChildItem (Join-Path $logDir 'next_build*.*.out.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Desc | Select-Object -First 1
$buildErr = Get-ChildItem (Join-Path $logDir 'next_build*.*.err.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Desc | Select-Object -First 1
$outTail  = @()
$errTail  = @()
$outPath  = $null
$errPath  = $null
try { if ($buildOut) { $outPath=$buildOut.FullName; $outTail = Get-Content $outPath -Tail 120 } } catch {}
try { if ($buildErr) { $errPath=$buildErr.FullName; $errTail = Get-Content $errPath -Tail 120 } } catch {}
J 'info' 'build.logs' 'Collected build log tails' @{ out=$outPath; err=$errPath }

# 2) inspect .next structure
$nextDir            = Join-Path $app '.next'
$serverAppDir       = Join-Path $nextDir 'server\app'
$serverPagesDir     = Join-Path $nextDir 'server\pages'
$hasNext            = Test-Path $nextDir
$hasServerApp       = Test-Path $serverAppDir
$hasServerPages     = Test-Path $serverPagesDir
$hasBuildId         = Test-Path (Join-Path $nextDir 'BUILD_ID')
$hasStandalone      = Test-Path (Join-Path $nextDir 'standalone')
$hasPrerenderMan    = Test-Path (Join-Path $nextDir 'prerender-manifest.json')

$nextTop = @()
$serverTop = @()
try { if ($hasNext)      { $nextTop   = Get-ChildItem $nextDir -ErrorAction SilentlyContinue | Select-Object -First 20 -ExpandProperty Name } } catch {}
try { if ($hasServerApp) { $serverTop = Get-ChildItem $serverAppDir -ErrorAction SilentlyContinue | Select-Object -First 20 -ExpandProperty Name } } catch {}

# 3) inference
$inf = 'unknown'
if (-not $hasNext)                           { $inf = 'no-.next' }
elseif (-not $hasServerApp -and -not $hasServerPages) { $inf = 'no-server-subdirs' }
elseif ($hasServerPages -or $hasServerApp)   { $inf = 'server-present' }

# 4) summary
$summary = [ordered]@{
  last_build_logs = @{ out=$outPath; err=$errPath; out_tail=$outTail; err_tail=$errTail }
  has_next_dir            = $hasNext
  has_server_app          = $hasServerApp
  has_server_pages        = $hasServerPages
  has_BUILD_ID            = $hasBuildId
  has_standalone          = $hasStandalone
  has_prerender_manifest  = $hasPrerenderMan
  next_top                = $nextTop
  next_server_top         = $serverTop
  inference               = $inf
  log_file                = $stepLog
  duration_ms             = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_fix_step      = $true
}
J 'info' 'summary' 'S5.1o build+tree summary' $summary

Write-Host ("`n== S5.1o Health: READY (see {0})" -f $stepLog)
