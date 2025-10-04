# C:\SocintAI\scripts\S5_patch_tsconfig_include_and_rebuild.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# Paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
$runDir = Join-Path $repoRoot '.run'
$feRoot = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }

$ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog  = Join-Path $logDir ("S5_patch_tsconfig_include_and_rebuild_{0}.log" -f $ts)
$buildOut = Join-Path $logDir ("next_build_tsfix_{0}.out.log" -f $ts)
$buildErr = Join-Path $logDir ("next_build_tsfix_{0}.err.log" -f $ts)
$startOut = Join-Path $logDir ("next_start_tsfix_A_{0}.out.log" -f $ts)
$startErr = Join-Path $logDir ("next_start_tsfix_A_{0}.err.log" -f $ts)
$pidFile  = Join-Path $runDir 'next_A.pid'
$port     = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o = [ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.patch_tsconfig_include'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json = $o | ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Patch tsconfig includes → rebuild → restart → probe /api/health' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 0) sanity
$tsFile = Join-Path $appRoot 'tsconfig.json'
if (-not (Test-Path $tsFile)) { throw "tsconfig.json not found at $tsFile" }

# 1) backup tsconfig
$backup = Join-Path $appRoot ("tsconfig.backup_{0}.json" -f $ts)
Copy-Item -LiteralPath $tsFile -Destination $backup -Force
J 'info' 'backup' 'Backed up tsconfig.json' @{ backup=$backup }

# 2) load & patch includes
$tsJson = Get-Content $tsFile -Raw | ConvertFrom-Json
$include = @()
try { $include = @($tsJson.include) } catch { $include = @() }
if ($include.Count -eq 0) {
  $include = @("next-env.d.ts","**/*.ts","**/*.tsx",".next/types/**/*.ts","src/**/*.ts","src/**/*.tsx")
} else {
  $need = @("src/**/*.ts","src/**/*.tsx")
  foreach ($n in $need) { if (-not ($include -contains $n)) { $include += $n } }
  if (-not ($include -contains "next-env.d.ts")) { $include += "next-env.d.ts" }
  if (-not ($include -contains "**/*.ts")) { $include += "**/*.ts" }
  if (-not ($include -contains "**/*.tsx")) { $include += "**/*.tsx" }
}
$tsJson | Add-Member -NotePropertyName include -NotePropertyValue $include -Force

# Make sure compilerOptions exists
if (-not $tsJson.compilerOptions) { $tsJson | Add-Member -NotePropertyName compilerOptions -NotePropertyValue (@{}) }
# Ensure noEmit true (safe), moduleResolution bundler (default for Next 15)
if ($tsJson.compilerOptions.noEmit -eq $null) { $tsJson.compilerOptions.noEmit = $true }
if ($tsJson.compilerOptions.moduleResolution -eq $null) { $tsJson.compilerOptions.moduleResolution = "bundler" }

# Save tsconfig
$patchedJson = $tsJson | ConvertTo-Json -Depth 50
Set-Content -LiteralPath $tsFile -Value $patchedJson -Encoding UTF8
$tsPatched = $true
J 'info' 'tsconfig.patch' 'Patched tsconfig include patterns' @{ include=$include }

# 3) stop previous server if running
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($proc) {
      try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {}
      Start-Sleep -Milliseconds 300
      J 'info' 'stop.prev' 'Stopped previous Next server' @{ oldPid=$old }
    }
  }
}

# 4) resolve pnpm path
$pnpmCmd = $null
try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpmCmd) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpmCmd = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpmCmd) { throw "pnpm not available in PATH" }
J 'info' 'env.pnpm' 'pnpm path resolved' @{ pnpm=$pnpmCmd }

# 5) rebuild (synchronous)
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
  $lvl = if ($buildOk) { 'info' } else { 'warn' }
  J $lvl 'build.done' 'Build finished' @{ ok=$buildOk; exit=$exitBuild; out=$buildOut; err=$buildErr }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_"; out=$buildOut; errlog=$buildErr }
}

# 6) free/bind port
try {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($c) {
    try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 300
    J 'warn' 'port.free' 'Freed busy port 3001' @{ ownerPid=$c.OwningProcess }
  }
} catch {}

# 7) start prod server (non-blocking) with cmd wrapper; split logs
$startOk = $false
$procId = 0
if ($buildOk) {
  $startCmd = '"' + $pnpmCmd + '"' + " start -p $port -H 127.0.0.1"
  try {
    $pStart = Start-Process -FilePath $cmdExe -WorkingDirectory $appRoot `
              -ArgumentList '/d','/s','/c', $startCmd `
              -PassThru -WindowStyle Hidden `
              -RedirectStandardOutput $startOut -RedirectStandardError $startErr
    Start-Sleep -Milliseconds 1500
    if ($pStart -and -not $pStart.HasExited) {
      $procId = $pStart.Id
      Set-Content -LiteralPath $pidFile -Value $procId -Encoding ASCII
      $startOk = $true
    }
    $lvl = if ($startOk) { 'info' } else { 'warn' }
    J $lvl 'start.spawn' 'Started Next prod server' @{ ok=$startOk; procId=$procId; port=$port; out=$startOut; err=$startErr }
  } catch {
    J 'error' 'start.fail' 'Start-Process failed for next start' @{ err="$_"; out=$startOut; errlog=$startErr }
  }
}

# 8) probe /api/health
$probeOk = $false; $status=0; $tries=0; $why=''
if ($startOk) {
  while (-not $probeOk -and $tries -lt 60) {
    Start-Sleep -Milliseconds 800
    $tries++
    try {
      $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $port) -TimeoutSec 4
      if ($r.StatusCode -eq 200) { $probeOk = $true; $status = 200 }
    } catch {
      $status = -1; $why = "$_"
    }
  }
}
$lv = if ($probeOk) { 'info' } else { 'warn' }
J $lv 'probe.api' 'Probe /api/health after tsconfig fix' @{ ok=$probeOk; port=$port; status=$status; tries=$tries; why=$why }

# 9) summary
$ready = ($buildOk -and $startOk -and $probeOk)
$summary = [ordered]@{
  tsconfig_path     = $tsFile
  tsconfig_patched  = $tsPatched
  build_ok          = $buildOk
  start_ok          = $startOk
  probe_api_ok      = $probeOk
  dev_pid           = $procId
  dev_port          = $port
  build_log_out     = $buildOut
  build_log_err     = $buildErr
  start_log_out     = $startOut
  start_log_err     = $startErr
  pid_file          = $pidFile
  log_file          = $stepLog
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2    = $ready
}
$lev = if ($ready) { 'info' } else { 'warn' }
J $lev 'summary' 'S5.1j tsconfig+rebuild summary' $summary

Write-Host ("`n== S5.1j Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
