param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir   = Join-Path $repoRoot 'logs'
$feRoot   = Join-Path $repoRoot 'frontend'
$appRoot  = Join-Path $feRoot   'socint-frontend'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $feRoot)) { New-Item -ItemType Directory -Force -Path $feRoot | Out-Null }
$logFile  = Join-Path $logDir ("S5_init_next_app_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param([string]$lvl,[string]$op,[string]$msg,[hashtable]$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S5.init_next_app';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Bootstrapping Next.js app (socint-frontend)' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) Node check (18+)
$nodeOk=$false; $nodeVersion=$null
try {
  $nodeVersion = (node -v) 2>$null
  if ($nodeVersion -match '^v(\d+)\.') { $nodeOk = ([int]$Matches[1] -ge 18) }
} catch {}
if ($nodeOk) { J 'info' 'env.node' 'Node version' @{ node=$nodeVersion; ok=$true } }
else { J 'warn' 'env.node' 'Node v18+ required' @{ node=$nodeVersion; ok=$false } }

# 2) Ensure pnpm via corepack; fallback to npm -g pnpm
function Pnpm-Detect {
  try { $v = (pnpm -v) 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() } } catch {}
  return $null
}
$pnpmVer = Pnpm-Detect
if (-not $pnpmVer) {
  try {
    J 'info' 'corepack' 'Enabling corepack & activating pnpm@latest' @{}
    corepack enable | Out-Null
    corepack prepare pnpm@latest --activate | Out-Null
  } catch {
    J 'warn' 'corepack' 'Corepack failed; trying npm i -g pnpm' @{ err="$_" }
    npm i -g pnpm --no-fund --no-audit | Out-Null
  }
  $pnpmVer = Pnpm-Detect
}
$pnpmOk = [bool]$pnpmVer
if ($pnpmOk) { J 'info' 'env.pnpm' 'pnpm ready' @{ version=$pnpmVer } } else { J 'warn' 'env.pnpm' 'pnpm not available' @{} }

# 3) Create Next.js app if not present
$appCreated=$false
if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
  Push-Location $feRoot
  if ($pnpmOk) {
    J 'info' 'cna.run' 'pnpm dlx create-next-app' @{ root=$feRoot }
    $argsPnpm = @('dlx','create-next-app@latest','socint-frontend','--ts','--eslint','--tailwind','--app','--src-dir','--import-alias','@/*','--yes')
    try { & pnpm @argsPnpm | ForEach-Object { J 'info' 'cna.out' 'create-next-app output' @{ line=$_ } } }
    catch { J 'warn' 'cna.err' 'pnpm dlx failed, will try npx fallback' @{ err="$_" } }
  }
  if (-not (Test-Path (Join-Path $appRoot 'package.json'))) {
    J 'info' 'cna.run.npx' 'npx create-next-app fallback' @{ root=$feRoot }
    $argsNpx = @('create-next-app@latest','socint-frontend','--ts','--eslint','--tailwind','--app','--src-dir','--import-alias','@/*','--yes')
    & npx @argsNpx | ForEach-Object { J 'info' 'cna.out' 'create-next-app output' @{ line=$_ } }
  }
  Pop-Location
  $appCreated = Test-Path (Join-Path $appRoot 'package.json')
  if ($appCreated) { J 'info' 'cna.done' 'create-next-app finished' @{ created=$true } } else { J 'warn' 'cna.done' 'create-next-app did not produce package.json' @{ created=$false } }
} else {
  J 'info' 'cna.skip' 'App already exists; skipping create-next-app' @{ appRoot=$appRoot }
}

# 4) Ensure /app and /api/health route
$appDir = Join-Path $appRoot 'app'
$apiDir = Join-Path $appDir 'api\health'
if (-not (Test-Path $apiDir)) { New-Item -ItemType Directory -Force -Path $apiDir | Out-Null }
$health = @"
import { NextResponse } from 'next/server';
import { randomUUID } from 'crypto';

export async function GET() {
  const req_id = randomUUID();
  return NextResponse.json({
    ok: true,
    service: 'socint-frontend',
    req_id,
    ts: new Date().toISOString()
  }, { status: 200 });
}
"@
Set-Content -LiteralPath (Join-Path $apiDir 'route.ts') -Value $health -Encoding UTF8

# minimal page if missing
$pagePath = Join-Path $appDir 'page.tsx'
if (-not (Test-Path $pagePath)) {
  $page = @"
export default function Home() {
  return (
    <main style={{padding: 24, fontFamily: 'system-ui'}}>
      <h1>Socint Frontend</h1>
      <p>Next.js 14 starter is live.</p>
    </main>
  );
}
"@
  Set-Content -LiteralPath $pagePath -Value $page -Encoding UTF8
}

# 5) Result checks
$hasPkg = Test-Path (Join-Path $appRoot 'package.json')
$hasHealth = Test-Path (Join-Path $apiDir 'route.ts')

$summary = [ordered]@{
  node_v18_plus     = $nodeOk
  pnpm_ok           = $pnpmOk
  app_exists        = $hasPkg
  health_route_ok   = $hasHealth
  app_root          = $appRoot
  log_file          = $logFile
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_1    = ($nodeOk -and $pnpmOk -and $hasPkg -and $hasHealth)
}
$level = if ($summary.ready_for_S5_1) { 'info' } else { 'warn' }
J $level 'summary' 'S5 init summary' $summary

Write-Host ("`n== S5.0 Health: {0} (see {1})" -f ($(if($summary.ready_for_S5_1){'READY'}else{'NEEDS_ACTION'}), $logFile))
