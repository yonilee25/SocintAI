param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$root   = 'C:\SocintAI'
$repo   = $root
$logDir = Join-Path $repo 'logs'
$runDir = Join-Path $repo '.run'
$feRoot = Join-Path $repo 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

$ts     = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog= Join-Path $logDir ("S5_start_next_correct_{0}.log" -f $ts)
$outLog = Join-Path $logDir ("next_start_correct_A_{0}.out.log" -f $ts)
$errLog = Join-Path $logDir ("next_start_correct_A_{0}.err.log" -f $ts)
$pidFile= Join-Path $runDir 'next_A.pid'
$port   = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.start_next_correct'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Start Next via pnpm exec next start -p 3001 -H 127.0.0.1' @{ user=$env:UserName; machine=$env:COMPUTERNAME; app=$app }

# sanity
if (-not (Test-Path (Join-Path $app 'package.json'))) { throw "Next app not found at $app" }

# resolve pnpm
$pnpm = $null
try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpm) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpm) { throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path' @{ pnpm=$pnpm }

# stop old server
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 250
  }
}

# free port if needed
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) {
    try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 250
  }
} catch {}

# spawn: cmd /c "<pnpm> exec next start -p 3001 -H 127.0.0.1"
$cmd = $env:ComSpec; if (-not $cmd) { $cmd = 'C:\Windows\System32\cmd.exe' }
$arg = '"' + $pnpm + '"' + ' exec next start -p 3001 -H 127.0.0.1'
$spawnOk = $false; $shellPid = 0
try {
  $p = Start-Process -FilePath $cmd -WorkingDirectory $app `
        -ArgumentList '/d','/s','/c', $arg `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  Start-Sleep -Milliseconds 1200
  if ($p -and -not $p.HasExited) { $shellPid = $p.Id; $spawnOk = $true }
  if ($spawnOk) { J 'info' 'spawn' 'cmd wrapper started' @{ ok=$true; shellPid=$shellPid; out=$outLog; err=$errLog } }
  else { J 'warn' 'spawn' 'cmd wrapper failed to stay running' @{ ok=$false; out=$outLog; err=$errLog } }
} catch { J 'error' 'spawn' 'Start-Process failed' @{ err="$_" } }

# find Node PID that owns :3001
$nodePid = $null; $listening = $false
for ($i=0; $i -lt 60 -and -not $listening; $i++) {
  Start-Sleep -Milliseconds 700
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $nodePid = $conn.OwningProcess; $listening = $true }
  } catch {}
}
if ($listening -and $nodePid) { Set-Content -LiteralPath $pidFile -Value $nodePid -Encoding ASCII }
if ($listening) { J 'info' 'listen' 'Port 3001 is listening' @{ ok=$true; nodePid=$nodePid } }
else { J 'warn' 'listen' 'Port 3001 not listening yet' @{ ok=$false } }

# probe /api/health
$probeOk = $false; $status = 0; $why = ''
if ($listening) {
  for ($i=0; $i -lt 40 -and -not $probeOk; $i++) {
    Start-Sleep -Milliseconds 600
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:3001/api/health' -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch {
      $status = -1; $why = "$($_.Exception.Message)"
    }
  }
}
if ($probeOk) { J 'info' 'probe' 'Hit /api/health on :3001' @{ ok=$true; status=$status } }
else { J 'warn' 'probe' 'Probe /api/health failed' @{ ok=$false; status=$status; why=$why; out=$outLog; err=$errLog } }

# also scan standalone artifacts (optional)
$standPages = $null
try {
  $standPages = Get-ChildItem (Join-Path $app '.next\standalone\server\pages') -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match '\\api\\health(\.js|\.mjs|\.cjs)$' } |
               Select-Object -First 1 -ExpandProperty FullName
} catch {}
$standApp = $null
try {
  $standApp = Get-ChildItem (Join-Path $app '.next\standalone\server\app') -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -match '\\api\\health\\' -and $_.Name -match '^route\.(m?js|cjs)$' } |
              Select-Object -First 1 -ExpandProperty FullName
} catch {}
J 'info' 'standalone.scan' 'Standalone route artifacts' @{ pages_api=$standPages; app_route=$standApp }

# summary
$ready = ($spawnOk -and $listening -and $probeOk)
$summary = [ordered]@{
  start_spawned        = $spawnOk
  node_pid_found       = ([bool]$nodePid)
  node_pid             = $nodePid
  port_3001_listening  = $listening
  probe_api_ok         = $probeOk
  out_log              = $outLog
  err_log              = $errLog
  pid_file             = $pidFile
  standalone_pages_api = $standPages
  standalone_app_route = $standApp
  log_file             = $stepLog
  duration_ms          = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2       = $ready
}
if ($ready) { J 'info' 'summary' 'S5.1n start-correct summary' $summary }
else { J 'warn' 'summary' 'S5.1n start-correct summary' $summary }

Write-Host ("`n== S5.1n Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
