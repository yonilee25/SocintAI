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

$ts       = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog  = Join-Path $logDir ("S5_run_next_prod_cmdwrap_{0}.log" -f $ts)
$buildOut = Join-Path $logDir ("next_build_{0}.out.log" -f $ts)
$buildErr = Join-Path $logDir ("next_build_{0}.err.log" -f $ts)
$startOut = Join-Path $logDir ("next_start_A_{0}.out.log" -f $ts)
$startErr = Join-Path $logDir ("next_start_A_{0}.err.log" -f $ts)
$pidFile  = Join-Path $runDir 'next_A.pid'
$port     = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S5.run_next_prod_cmdwrap';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Build + start Next in production on :3001 (cmd wrapper)' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 0) prechecks
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  J 'error' 'precheck' 'package.json not found; run S5_init_next_app.ps1 first' @{ appRoot=$appRoot }
  throw "Missing Next app at $appRoot"
}

# 1) resolve pnpm path
$pnpmCmd = $null
try {
  $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source
} catch {}
if (-not $pnpmCmd) {
  J 'info' 'corepack' 'Enabling corepack pnpm' @{}
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpmCmd) { J 'error' 'env.pnpm' 'pnpm not available' @{}; throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpmCmd }

# 2) install deps (idempotent)
$installOk = $false
try { Push-Location $appRoot; pnpm install --reporter silent | Out-Null; $installOk = $true; Pop-Location }
catch { try { Pop-Location } catch {}; J 'warn' 'install' 'pnpm install failed' @{ err="$_" } }

# 3) build (synchronous; use Start-Process -Wait and check ExitCode)
$cmdExe = $env:ComSpec; if (-not $cmdExe) { $cmdExe = 'C:\Windows\System32\cmd.exe' }
$buildCmd = '"' + $pnpmCmd + '"' + ' build'
$buildOk = $false
try {
  $pBuild = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
            -ArgumentList '/d','/s','/c', $buildCmd `
            -PassThru -NoNewWindow -Wait `
            -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
  $exitBuild = 0
  try { $exitBuild = $pBuild.ExitCode } catch {}
  $buildOk = ($exitBuild -eq 0)
  if ($buildOk) { J 'info' 'build.done' 'Build finished' @{ ok=$true; exit=$exitBuild; out=$buildOut; err=$buildErr } }
  else { J 'warn' 'build.done' 'Build had non-zero exit' @{ ok=$false; exit=$exitBuild; out=$buildOut; err=$buildErr } }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_"; out=$buildOut; errlog=$buildErr }
}

# 4) choose port (fallback if busy)
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) {
    $port = 3003
    J 'warn' 'port.busy' 'Port 3001 busy; switching to 3003' @{ ownerPid=$c.OwningProcess }
  }
} catch {}

# 5) start Next prod server (non-blocking) and verify running
$startOk = $false
$procId = 0
if ($buildOk) {
  $startCmd = '"' + $pnpmCmd + '"' + " start -p $port -H 127.0.0.1"
  try {
    $pStart = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
              -ArgumentList '/d','/s','/c', $startCmd `
              -PassThru -WindowStyle Hidden `
              -RedirectStandardOutput $startOut -RedirectStandardError $startErr
    Start-Sleep -Milliseconds 1200
    if ($pStart -and -not $pStart.HasExited) {
      $procId = $pStart.Id
      Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
      $startOk = $true
      J 'info' 'start.spawn' 'Started Next prod server' @{ ok=$true; procId=$procId; port=$port; out=$startOut; err=$startErr }
    } else {
      J 'warn' 'start.spawn' 'Next prod server exited quickly' @{ ok=$false; out=$startOut; err=$startErr }
    }
  } catch {
    J 'error' 'start.fail' 'Start-Process failed for next start' @{ err="$_"; out=$startOut; errlog=$startErr }
  }
}

# 6) probe /api/health
$probeOk = $false; $status=0; $tries=0; $why=''
if ($startOk) {
  while (-not $probeOk -and $tries -lt 60) {
    Start-Sleep -Milliseconds 700
    $tries++
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 3
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch {
      $status = -1; $why = "$_"
    }
  }
}
if ($probeOk) { J 'info' 'probe.api' 'Probe /api/health OK' @{ ok=$true; port=$port; status=$status; tries=$tries } }
else { J 'warn' 'probe.api' 'Probe /api/health failed' @{ ok=$false; port=$port; status=$status; tries=$tries; why=$why; out=$startOut; err=$startErr } }

# 7) summary
$ready = ($installOk -and $buildOk -and $startOk -and $probeOk)
$summary = [ordered]@{
  install_ok        = $installOk
  build_ok          = $buildOk
  start_ok          = $startOk
  dev_pid           = $procId
  dev_port          = $port
  build_log_out     = $buildOut
  build_log_err     = $buildErr
  start_log_out     = $startOut
  start_log_err     = $startErr
  probe_api_ok      = $probeOk
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
if ($ready) { J 'info' 'summary' 'S5.1p prod-run summary' $summary }
else { J 'warn' 'summary' 'S5.1p prod-run summary' $summary }

Write-Host ("`n== S5.1p Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
