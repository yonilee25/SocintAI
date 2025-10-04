# C:\SocintAI\scripts\S5_purge_app_health_rebuild.ps1  (PS7-safe; no ternaries)
param()

$ErrorActionPreference = 'Stop'
$reqId   = [guid]::NewGuid().ToString()
$started = Get-Date

$root   = 'C:\SocintAI'
$feRoot = Join-Path $root 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
$logDir = Join-Path $root 'logs'
$runDir = Join-Path $root '.run'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_purge_app_health_rebuild_{0}.log" -f $ts)
$buildLog= Join-Path $logDir ("next_build_conflictpurge_{0}.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'
$port    = 3001

function J { param($lvl,$op,$msg,$data=@{})
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.purge_app_health_rebuild'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Purge App /api/health routes, rebuild, start (node), probe' @{ app=$app; user=$env:UserName }

# 0) sanity
$pkgPath = Join-Path $app 'package.json'
if (-not (Test-Path $pkgPath)) { throw "package.json not found at $pkgPath" }

# 1) find ANY app/api/health/route.* under root AND src
$purgeList = @()
$patterns = @(
  (Join-Path $app 'app\api\health\route.*'),
  (Join-Path $app 'src\app\api\health\route.*')
)
foreach ($pat in $patterns) {
  try {
    $purgeList += Get-ChildItem $pat -ErrorAction SilentlyContinue
  } catch {}
}
$removed = @()
foreach ($f in $purgeList) {
  $bak = $f.FullName + ('.removed_{0}.bak' -f $ts)
  try { Copy-Item -LiteralPath $f.FullName -Destination $bak -Force; Remove-Item -LiteralPath $f.FullName -Force; $removed += $f.FullName } catch {}
}
J 'info' 'purge' 'Removed App Router health routes (if any)' @{ removed=$removed }

# 2) ensure Pages API exists (src/pages/api/health.ts)
$pagesApiDir = Join-Path $app 'src\pages\api'
if (-not (Test-Path $pagesApiDir)) { New-Item -ItemType Directory -Force -Path $pagesApiDir | Out-Null }
$pagesHealth = Join-Path $pagesApiDir 'health.ts'
if (-not (Test-Path $pagesHealth)) {
  $code = @"
import type { NextApiRequest, NextApiResponse } from 'next';
export default function handler(_req: NextApiRequest, res: NextApiResponse) {
  res.status(200).json({ ok: true, service: 'socint-frontend', ts: new Date().toISOString() });
}
"@
  Set-Content -LiteralPath $pagesHealth -Value $code -Encoding UTF8
}
J 'info' 'ensure.pagesapi' 'Pages API present at /api/health' @{ path=$pagesHealth }

# 3) stop any old server & clean .next
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} }
}
$nextDir = Join-Path $app '.next'
if (Test-Path $nextDir) { try { Remove-Item -Recurse -Force -LiteralPath $nextDir } catch {} }

# 4) run standard build (we previously patched package.json to "next build")
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

# 5) start Next via Node CLI (bind 127.0.0.1:3001)
$startOk = $false; $nodeOwner = $null
if ($buildOk) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($c) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  $nodeExe = (Get-Command node -ErrorAction Stop).Source
  $binNext = Join-Path $app 'node_modules\next\dist\bin\next'
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
  J 'info' 'start.spawn' 'Started Next via Node' @{ ok=$startOk; shell_pid=($p ? $p.Id : 0) }
}

# 6) wait for port & probe
$listening = $false
for ($i=0; $i -lt 60 -and -not $listening; $i++) {
  Start-Sleep -Milliseconds 700
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $listening = $true; $nodeOwner = $conn.OwningProcess; Set-Content -LiteralPath $pidFile -Value $nodeOwner -Encoding ASCII }
  } catch {}
}
$probeOk = $false; $status=0; $why=''
if ($listening) {
  for ($i=0; $i -lt 40 -and -not $probeOk; $i++) {
    Start-Sleep -Milliseconds 600
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch { $status=-1; $why="$($_.Exception.Message)" }
  }
}
J ($probeOk ? 'info' : 'warn') 'probe' 'GET /api/health' @{ ok=$probeOk; status=$status; why=$why }

# 7) summary
$ready = ($buildOk -and $startOk -and $listening -and $probeOk)
$summary = [ordered]@{
  removed_app_routes    = $removed
  build_ok              = $buildOk
  start_ok              = $startOk
  port_3001_listening   = $listening
  node_pid              = $nodeOwner
  probe_api_ok          = $probeOk
  pages_api_path        = $pagesHealth
  build_log             = $buildLog
  pid_file              = $pidFile
  log_file              = $stepLog
  duration_ms           = [int]((Get-Date) - $started).TotalMilliseconds
  ready_for_S5_2        = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1p6 purge+rebuild summary' $summary

Write-Host ("`n== S5.1p6 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
