# C:\SocintAI\scripts\S5_force_standalone_build_and_start.ps1
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$root   = 'C:\SocintAI'
$logDir = Join-Path $root 'logs'
$runDir = Join-Path $root '.run'
$feRoot = Join-Path $root 'frontend'
$app    = Join-Path $feRoot 'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $runDir)) { New-Item -Type Directory -Force -Path $runDir | Out-Null }

$ts      = (Get-Date).ToString('yyyyMMdd_HHmmss')
$stepLog = Join-Path $logDir ("S5_force_standalone_build_and_start_{0}.log" -f $ts)
$buildOut= Join-Path $logDir ("next_build_standalone_{0}.out.log" -f $ts)
$buildErr= Join-Path $logDir ("next_build_standalone_{0}.err.log" -f $ts)
$startOut= Join-Path $logDir ("next_start_standalone_A_{0}.out.log" -f $ts)
$startErr= Join-Path $logDir ("next_start_standalone_A_{0}.err.log" -f $ts)
$pidFile = Join-Path $runDir 'next_A.pid'
$port    = 3001

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.force_standalone'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20; Write-Host $json; Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Patch next.config to output: standalone → rebuild → node standalone server' @{ app=$app; user=$env:UserName }

# sanity
$pkg = Join-Path $app 'package.json'
if (-not (Test-Path $pkg)) { throw "Next app not found at $app" }

# 1) patch next.config.ts to ensure output:'standalone'
$config = Join-Path $app 'next.config.ts'
if (-not (Test-Path $config)) { throw "Missing $config" }
$backup = Join-Path $app ("next.config.backup_{0}.ts" -f $ts)
Copy-Item -LiteralPath $config -Destination $backup -Force

$content = Get-Content $config -Raw
# if "output" not present, insert it inside the exported object
if ($content -notmatch 'output\s*:') {
  $content = $content -replace 'const\s+nextConfig\s*:\s*NextConfig\s*=\s*\{\s*', 'const nextConfig: NextConfig = { output: "standalone", '
} else {
  # if present but not standalone, replace its value
  $content = [regex]::Replace($content, 'output\s*:\s*["''][^"'']+["'']', 'output: "standalone"')
}
Set-Content -LiteralPath $config -Value $content -Encoding UTF8
J 'info' 'config.patch' 'Patched next.config.ts to output: standalone' @{ config=$config; backup=$backup }
$configPatched = $true

# 2) stop any previous server & clear .next
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) { try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {} }
}
$nextDir = Join-Path $app '.next'
if (Test-Path $nextDir) { try { Remove-Item -Recurse -Force -LiteralPath $nextDir } catch {} }

# 3) resolve pnpm
$pnpm = $null
try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
if (-not $pnpm) {
  try { corepack enable | Out-Null; corepack prepare pnpm@latest --activate | Out-Null } catch {}
  try { $pnpm = (Get-Command pnpm -ErrorAction Stop).Source } catch {}
}
if (-not $pnpm) { throw "pnpm not available" }
J 'info' 'env.pnpm' 'pnpm path' @{ pnpm=$pnpm }

# 4) build (synchronous)
$cmd = $env:ComSpec; if (-not $cmd) { $cmd = 'C:\Windows\System32\cmd.exe' }
$buildCmd = '"' + $pnpm + '"' + ' build'
$buildOk = $false
try {
  $pBuild = Start-Process -FilePath $cmd -WorkingDirectory $app `
            -ArgumentList '/d','/s','/c', $buildCmd `
            -PassThru -NoNewWindow -Wait `
            -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
  $exitBuild = 0; try { $exitBuild = $pBuild.ExitCode } catch {}
  $buildOk = ($exitBuild -eq 0) -and (Test-Path (Join-Path $app '.next\standalone\server.js'))
  J ($buildOk ? 'info' : 'warn') 'build.done' 'Build finished' @{ ok=$buildOk; exit=$exitBuild; standalone_server=(Join-Path $app '.next\standalone\server.js') }
} catch {
  J 'error' 'build.fail' 'Build failed to start' @{ err="$_" }
}

# 5) free port & start standalone with Node
$startOk = $false; $nodePid = $null
if ($buildOk) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($c) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  $nodeExe = (Get-Command node -ErrorAction Stop).Source
  $serverJs = Join-Path $app '.next\standalone\server.js'
  $envVars = @{ PORT="$port"; HOSTNAME="127.0.0.1" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $nodeExe
  $psi.WorkingDirectory = $app
  $psi.ArgumentList = @($serverJs)
  foreach($kv in $envVars.GetEnumerator()){ $psi.Environment[$kv.Key] = $kv.Value }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  Start-Sleep -Milliseconds 1200
  if ($p -and -not $p.HasExited) {
    $nodePid = $p.Id
    Set-Content -LiteralPath $pidFile -Value $nodePid -Encoding ASCII
    $startOk = $true
    # also mirror to logs
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
  }
  J ($startOk ? 'info' : 'warn') 'start.spawn' 'node .next/standalone/server.js' @{ ok=$startOk; nodePid=$nodePid; port=$port }
}

# 6) wait for port & probe
$listening = $false
for ($i=0; $i -lt 60 -and -not $listening; $i++) {
  Start-Sleep -Milliseconds 600
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $listening = $true }
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
J ($probeOk ? 'info' : 'warn') 'probe.api' 'Probe /api/health (standalone)' @{ ok=$probeOk; status=$status; why=$why }

# 7) summary
$ready = ($configPatched -and $buildOk -and $startOk -and $listening -and $probeOk)
$summary = [ordered]@{
  config_patched        = $configPatched
  build_ok              = $buildOk
  start_ok              = $startOk
  port_3001_listening   = $listening
  probe_api_ok          = $probeOk
  node_pid              = $nodePid
  pid_file              = $pidFile
  log_file              = $stepLog
  duration_ms           = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2        = $ready
}
J ($ready ? 'info' : 'warn') 'summary' 'S5.1p2 standalone summary' $summary

Write-Host ("`n== S5.1p2 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
