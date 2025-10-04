# C:\SocintAI\scripts\S5_patch_build_and_start_node.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId   = [guid]::NewGuid().ToString()
$started = Get-Date

# paths
$root   = 'C:\SocintAI'
$feRoot = Join-Path $root 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
$logDir = Join-Path $root 'logs'
$runDir = Join-Path $root '.run'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_patch_build_and_start_node_{0}.log" -f $ts)
$buildLog= Join-Path $logDir ("next_build_standard_{0}.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'
$port    = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.patch_build_and_start_node'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Patch build to "next build", then start Next via Node and probe /api/health' @{ app=$app; user=$env:UserName }

# 0) sanity
$pkgPath = Join-Path $app 'package.json'
if (-not (Test-Path $pkgPath)) { throw "package.json not found at $pkgPath" }

# 1) patch package.json "build" to exactly "next build" (remove --turbopack)
$pkgBackup = Join-Path $app ("package.backup_{0}.json" -f $ts)
Copy-Item -LiteralPath $pkgPath -Destination $pkgBackup -Force
$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
if (-not $pkg.scripts) { $pkg | Add-Member -NotePropertyName scripts -NotePropertyValue (@{}) }
$oldBuild = $pkg.scripts.build
$pkg.scripts.build = "next build"
$patchedJson = $pkg | ConvertTo-Json -Depth 30
Set-Content -LiteralPath $pkgPath -Value $patchedJson -Encoding UTF8
$patched = $true
J 'info' 'pkg.patch' 'Patched build script to "next build"' @{ previous=$oldBuild; backup=$pkgBackup }

# 2) stop any old server & clear .next
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} }
}
$nextDir = Join-Path $app '.next'
if (Test-Path $nextDir) { try { Remove-Item -Recurse -Force -LiteralPath $nextDir } catch {} }

# 3) run build (live, tee to file)
Push-Location $app
$exit = -999
try {
  ">>> Running: pnpm run -s build (standard webpack build)" | Tee-Object -FilePath $buildLog -Append
  & pnpm run -s build 2>&1 | Tee-Object -FilePath $buildLog -Append
  $exit = $LASTEXITCODE
} finally { Pop-Location }
$hasNext     = Test-Path (Join-Path $app '.next')
$hasSrvPages = Test-Path (Join-Path $app '.next\server\pages')
$hasSrvApp   = Test-Path (Join-Path $app '.next\server\app')
$buildOk = ($exit -eq 0 -and $hasNext -and ($hasSrvPages -or $hasSrvApp))
J 'info' 'build.done' 'Build verification' @{ exit=$exit; has_next=$hasNext; server_pages=$hasSrvPages; server_app=$hasSrvApp }

# 4) start Next via Node directly (node node_modules/next/dist/bin/next start)
$startOk   = $false
$nodePid   = $null
$nodeExe   = $null
try { $nodeExe = (Get-Command node -ErrorAction Stop).Source } catch { throw "Node not found in PATH" }
if ($buildOk) {
  # ensure port free
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($c) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  $binNext = Join-Path $app 'node_modules\next\dist\bin\next'
  if (-not (Test-Path $binNext)) { throw "Unable to find next CLI at $binNext" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $nodeExe
  $psi.WorkingDirectory = $app
  $psi.ArgumentList = @($binNext, 'start', '-p', "$port", '-H', '127.0.0.1')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.Environment['PORT']     = "$port"
  $psi.Environment['HOSTNAME'] = '127.0.0.1'

  $p = [System.Diagnostics.Process]::Start($psi)
  Start-Sleep -Milliseconds 1200
  if ($p -and -not $p.HasExited) { $startOk = $true }
  J 'info' 'start.spawn' 'Started Next via Node' @{ ok=$startOk; shell_pid=$($p.Id) }
}

# 5) wait for port to listen and probe
$listening = $false; $nodeOwner = $null
for ($i=0; $i -lt 60 -and -not $listening; $i++) {
  Start-Sleep -Milliseconds 700
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $listening = $true; $nodeOwner = $conn.OwningProcess }
  } catch {}
}
if ($listening) { Set-Content -LiteralPath $pidFile -Value $nodeOwner -Encoding ASCII }

$probeOk = $false; $status=0; $why=''
if ($listening) {
  for ($i=0; $i -lt 40 -and -not $probeOk; $i++) {
    Start-Sleep -Milliseconds 600
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch { $status = -1; $why = "$($_.Exception.Message)" }
  }
}
J ($probeOk ? 'info' : 'warn') 'probe' 'GET /api/health' @{ ok=$probeOk; status=$status; why=$why }

# 6) summary
$ready = ($patched -and $buildOk -and $startOk -and $listening -and $probeOk)
$summary = [ordered]@{
  pkg_build_patched    = $patched
  build_ok             = $buildOk
  start_ok             = $startOk
  port_3001_listening  = $listening
  node_pid             = $nodeOwner
  probe_api_ok         = $probeOk
  build_log            = $buildLog
  pid_file             = $pidFile
  log_file             = $stepLog
  duration_ms          = [int]((Get-Date) - $started).TotalMilliseconds
  ready_for_S5_2       = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1p5 build-standard+node-start summary' $summary

Write-Host ("`n== S5.1p5 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
