param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir  = Join-Path $repoRoot 'logs'
$runDir  = Join-Path $repoRoot '.run'
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }
$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_run_next_dev_cmdwrap_{0}.log" -f $ts)
$outLog  = Join-Path $logDir ("next_dev_A_{0}.out.log" -f $ts)
$errLog  = Join-Path $logDir ("next_dev_A_{0}.err.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'

function J { param($lvl,$op,$msg,$data=@{})
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$lvl; step='S5.run_next_dev_cmdwrap';
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Start Next dev via cmd.exe wrapper (pnpm exec next dev -p 3001 -H 127.0.0.1)' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 0) prechecks
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  J 'error' 'precheck' 'package.json not found; run S5_init_next_app.ps1 first' @{ appRoot=$appRoot }
  throw "Missing Next app at $appRoot"
}

# 1) resolve pnpm path (shim)
$pnpmCmd = $null
try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpmCmd) {
  J 'warn' 'env.pnpm' 'pnpm not found in PATH; attempting corepack activation' @{}
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpmCmd) { J 'error' 'env.pnpm' 'pnpm still not available' @{}; throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpmCmd }

# 2) install deps (idempotent)
$installOk = $false
try {
  Push-Location $appRoot
  pnpm install --reporter silent | Out-Null
  $installOk = $true
  Pop-Location
} catch { try { Pop-Location } catch {}; J 'warn' 'install' 'pnpm install failed' @{ err="$_" } }

# 3) ensure port free (fallback to 3003 if busy)
$port = 3001
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) { $port = 3003; J 'warn' 'port.busy' 'Port 3001 busy; switching to 3003' @{ ownerPid=$c.OwningProcess } }
} catch {}

# 4) build cmd.exe command
$cmdExe = $env:ComSpec; if (-not $cmdExe) { $cmdExe = 'C:\Windows\System32\cmd.exe' }
# Properly quote pnpm path for cmd /c
$cmdStr = '"' + $pnpmCmd + '"' + " exec next dev -p $port -H 127.0.0.1"

# 5) start via Start-Process cmd.exe /d /s /c "<pnpm> exec next dev ..."
$devStarted = $false
$procId = 0
try {
  $p = Start-Process -FilePath $cmdExe `
        -ArgumentList '/d','/s','/c', $cmdStr `
        -WorkingDirectory $appRoot `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  Start-Sleep -Milliseconds 1000
  if ($p -and -not $p.HasExited) {
    $procId = $p.Id
    Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
    $devStarted = $true
  }
  if ($devStarted) { J 'info' 'dev.start' 'Spawned Next dev (cmd wrapper)' @{ procId=$procId; port=$port; out=$outLog; err=$errLog } }
  else { J 'warn' 'dev.start' 'Failed to spawn Next dev (check logs)' @{ out=$outLog; err=$errLog } }
} catch {
  J 'error' 'dev.start' 'Start-Process failed' @{ err="$_"; out=$outLog; errlog=$errLog }
}

# 6) probe /api/health
$probeOk = $false; $status = 0; $why=''; $tries=0
while (-not $probeOk -and $tries -lt 50) {
  Start-Sleep -Milliseconds 700
  $tries++
  try {
    $res = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
    if ($res.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
  } catch {
    $status = -1; $why = "$_"
  }
}
if ($probeOk) { J 'info' 'probe.api' 'Probed /api/health' @{ ok=$true; port=$port; status=$status; tries=$tries } }
else { J 'warn' 'probe.api' 'Health probe failed' @{ ok=$false; port=$port; status=$status; tries=$tries; err=$why; out=$outLog; errlog=$errLog } }

# 7) summary
$ready = ($installOk -and $devStarted -and $probeOk)
$summary = [ordered]@{
  install_ok        = $installOk
  dev_started       = $devStarted
  dev_pid           = $procId
  dev_port          = $port
  dev_log_out       = $outLog
  dev_log_err       = $errLog
  probe_api_ok      = $probeOk
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S5.1b cmdwrap summary' $summary

Write-Host ("`n== S5.1b Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
