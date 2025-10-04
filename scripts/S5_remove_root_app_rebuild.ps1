# C:\SocintAI\scripts\S5_remove_root_app_rebuild.ps1  (PS7-safe; no ternaries)
param()

$ErrorActionPreference = 'Stop'
$reqId   = [guid]::NewGuid().ToString()
$started = Get-Date

$root   = 'C:\SocintAI'
$feRoot = Join-Path $root 'frontend'
$appDir = Join-Path $feRoot 'socint-frontend'
$logDir = Join-Path $root 'logs'
$runDir = Join-Path $root '.run'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_remove_root_app_rebuild_{0}.log" -f $ts)
$buildLog= Join-Path $logDir ("next_build_after_app_remove_{0}.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'
$port    = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.remove_root_app_rebuild'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Remove root app/, rebuild (webpack), start via Node, probe /api/health' @{ app=$appDir; user=$env:UserName }

# 0) sanity
$pkgPath = Join-Path $appDir 'package.json'
if (-not (Test-Path $pkgPath)) { throw "package.json not found at $pkgPath" }

# 1) if a root app/ exists, back it up and remove it (we keep src/app/)
$rootApp = Join-Path $appDir 'app'
$backup  = Join-Path $appDir ("app.removed_{0}" -f $ts)
$removedRootApp = $false
if (Test-Path $rootApp) {
  try {
    Copy-Item -LiteralPath $rootApp -Destination $backup -Recurse -Force
    Remove-Item -LiteralPath $rootApp -Recurse -Force
    $removedRootApp = $true
  } catch {
    J 'warn' 'app.remove' 'Failed to remove root app/ (check permissions)' @{ err="$_" }
  }
}
J 'info' 'app.remove' 'Root app/ removal status' @{ existed=(Test-Path $backup); removed=$removedRootApp; backup=$backup }

# 2) stop any old server & clear .next
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} }
}
$nextDir = Join-Path $appDir '.next'
if (Test-Path $nextDir) { try { Remove-Item -Recurse -Force -LiteralPath $nextDir } catch {} }

# 3) run standard build (uses package.json "build": "next build")
Push-Location $appDir
$exit = -999
try {
  ">>> Running: pnpm run -s build (standard webpack build)" | Tee-Object -FilePath $buildLog -Append
  & pnpm run -s build 2>&1 | Tee-Object -FilePath $buildLog -Append
  $exit = $LASTEXITCODE
} finally { Pop-Location }

$hasNext     = Test-Path (Join-Path $appDir '.next')
$hasSrvPages = Test-Path (Join-Path $appDir '.next\server\pages')
$hasSrvApp   = Test-Path (Join-Path $appDir '.next\server\app')
$buildOk = ($exit -eq 0 -and $hasNext -and ($hasSrvPages -or $hasSrvApp))
J 'info' 'build.verify' 'Build verification' @{ exit=$exit; has_next=$hasNext; server_pages=$hasSrvPages; server_app=$hasSrvApp; build_log=$buildLog }

# 4) start Next via Node CLI (bind 127.0.0.1:3001)
$startOk  = $false
$nodeOwner = $null

$nodeExe = (Get-Command node -ErrorAction Stop).Source
$binNext = Join-Path $appDir 'node_modules\next\dist\bin\next'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = $nodeExe
$psi.WorkingDirectory = $appDir
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.Environment['PORT']     = "$port"
$psi.Environment['HOSTNAME'] = '127.0.0.1'

# IMPORTANT: add args one by one (ArgumentList is read-only)
$psi.ArgumentList.Add($binNext)      | Out-Null
$psi.ArgumentList.Add('start')       | Out-Null
$psi.ArgumentList.Add('-p')          | Out-Null
$psi.ArgumentList.Add("$port")       | Out-Null
$psi.ArgumentList.Add('-H')          | Out-Null
$psi.ArgumentList.Add('127.0.0.1')   | Out-Null

$p = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 1200
$startOk = ($p -and -not $p.HasExited)
J 'info' 'start.spawn' 'Started Next via Node' @{ ok=$startOk; shell_pid=($p ? $p.Id : 0) }

# 5) wait for port & probe
$listening = $false; $tries = 0
while (-not $listening -and $tries -lt 60) {
  Start-Sleep -Milliseconds 700; $tries++
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $listening = $true; $nodeOwner = $conn.OwningProcess; Set-Content -LiteralPath $pidFile -Value $nodeOwner -Encoding ASCII }
  } catch {}
}
$probeOk = $false; $status = 0; $why = ''
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
$ready = ($removedRootApp -and $buildOk -and $startOk -and $listening -and $probeOk)
$summary = [ordered]@{
  root_app_removed      = $removedRootApp
  build_ok              = $buildOk
  start_ok              = $startOk
  port_3001_listening   = $listening
  node_pid              = $nodeOwner
  probe_api_ok          = $probeOk
  build_log             = $buildLog
  pid_file              = $pidFile
  log_file              = $stepLog
  duration_ms           = [int]((Get-Date) - $started).TotalMilliseconds
  ready_for_S5_2        = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1p7 remove-root-app summary' $summary

Write-Host ("`n== S5.1p7 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
