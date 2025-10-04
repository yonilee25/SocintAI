# C:\SocintAI\scripts\S5_build_verbose.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$root   = 'C:\SocintAI'
$logDir = Join-Path $root 'logs'
$feRoot = Join-Path $root 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$ts     = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog= Join-Path $logDir ("S5_build_verbose_{0}.log" -f $ts)
$buildLog = Join-Path $logDir ("next_build_verbose_{0}.log" -f $ts)

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.build_verbose'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

# 0) Context + env
$cwdOk  = Test-Path $app
$pkg    = Join-Path $app 'package.json'
$hasPkg = Test-Path $pkg
$pkgJson = $null; $buildScript = $null
if ($hasPkg) { try { $pkgJson = Get-Content $pkg -Raw | ConvertFrom-Json; $buildScript = $pkgJson.scripts.build } catch {} }
J 'info' 'ctx' 'Context and package.json' @{ app=$app; cwd_ok=$cwdOk; has_pkg=$hasPkg; build_script=$buildScript }

# 1) Versions
$nodeVer = $null; $pnpmVer=$null
try { $nodeVer = (& node -v) } catch {}
try { $pnpmVer = (& pnpm -v) } catch {}
J 'info' 'env' 'Tool versions' @{ node=$nodeVer; pnpm=$pnpmVer }

if (-not $cwdOk -or -not $hasPkg) { throw "App folder or package.json missing" }

# 2) Run build with live output (tee to file)
Push-Location $app
$exit = -999
try {
  $env:NEXT_TELEMETRY_DISABLED = '1'
  $env:CI = '1'
  if ($buildScript) {
    ">>> Running: pnpm run -s build" | Tee-Object -FilePath $buildLog -Append
    & pnpm run -s build 2>&1 | Tee-Object -FilePath $buildLog -Append
    $exit = $LASTEXITCODE
  } else {
    ">>> Running: npx --yes next build" | Tee-Object -FilePath $buildLog -Append
    & npx --yes next build 2>&1 | Tee-Object -FilePath $buildLog -Append
    $exit = $LASTEXITCODE
  }
} finally {
  Pop-Location
}

# 3) Verify artifacts
$nextDir     = Join-Path $app '.next'
$serverApp   = Join-Path $nextDir 'server\app'
$serverPages = Join-Path $nextDir 'server\pages'
$standalone  = Join-Path $app '.next\standalone\server.js'

$hasNext     = Test-Path $nextDir
$hasAppSrv   = Test-Path $serverApp
$hasPagesSrv = Test-Path $serverPages
$hasStandaloneSrv = Test-Path $standalone

$summary = [ordered]@{
  cwd_ok                   = $cwdOk
  has_pkg                  = $hasPkg
  build_script_present     = [bool]$buildScript
  node_ver                 = $nodeVer
  pnpm_ver                 = $pnpmVer
  next_exists              = $hasNext
  server_app_exists        = $hasAppSrv
  server_pages_exists      = $hasPagesSrv
  standalone_server_exists = $hasStandaloneSrv
  exit_code                = $exit
  build_log                = $buildLog
  step_log                 = $stepLog
  duration_ms              = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2           = ($hasAppSrv -or $hasPagesSrv -or $hasStandaloneSrv)
}
J 'info' 'summary' 'S5.1p3 build-verify summary' $summary
