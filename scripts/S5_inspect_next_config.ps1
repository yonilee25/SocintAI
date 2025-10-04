param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$feRoot  = Join-Path $repoRoot 'frontend'
$appRoot = Join-Path $feRoot   'socint-frontend'
$logDir  = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -Type Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_inspect_next_config_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S5.inspect_next_config'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

function Slurp([string]$p) { if (Test-Path $p) { return (Get-Content $p -Raw) } return $null }

J 'info' 'start' 'Inspecting Next config, package scripts, and tsconfig' @{ user=$env:UserName; machine=$env:COMPUTERNAME; appRoot=$appRoot }

# 1) detect next.config.*
$configCandidates = @('next.config.ts','next.config.mjs','next.config.js')
$configFile = $null; $configText = $null
foreach ($c in $configCandidates) {
  $p = Join-Path $appRoot $c
  if (Test-Path $p) { $configFile = $p; $configText = Slurp $p; break }
}
J 'info' 'config.file' 'Detected next config file' @{ file=$configFile }

# 2) parse values safely (use single-quoted strings with doubled single-quotes)
$outputValue = $null
$expAppDir   = $null
if ($configText) {
  # output: "export" | "standalone" | etc.
  if ($configText -match 'output\s*:\s*["'']([^"'''']+)["'']') { $outputValue = $Matches[1] }
  # experimental.appDir: true/false
  if ($configText -match 'experimental\s*:\s*\{[^}]*appDir\s*:\s*(true|false)') { $expAppDir = $Matches[1] }
}
J 'info' 'config.parse' 'Parsed next config' @{ output=$outputValue; experimental_appDir=$expAppDir }

# 3) package.json start script
$pkgFile = Join-Path $appRoot 'package.json'
$startScript = $null
if (Test-Path $pkgFile) {
  try {
    $pkgJson = Get-Content $pkgFile -Raw | ConvertFrom-Json
    $startScript = $pkgJson.scripts.start
  } catch { }
}
J 'info' 'package' 'package.json start' @{ start=$startScript }

# 4) tsconfig + src/app presence
$tsFile = Join-Path $appRoot 'tsconfig.json'
$tsText = Slurp $tsFile
$tsIncludesSrc = $null
if ($tsText) {
  if ($tsText -match '"rootDir"\s*:\s*"src"') { $tsIncludesSrc = $true }
  elseif ($tsText -match '"include"\s*:\s*\[[^\]]*"src') { $tsIncludesSrc = $true }
  else { $tsIncludesSrc = $false }
}
$srcAppExists = Test-Path (Join-Path $appRoot 'src\app')
J 'info' 'tsconfig' 'tsconfig + src/app presence' @{ tsfile=$tsFile; src_app=$srcAppExists; ts_includes_src=$tsIncludesSrc }

# 5) infer blocking reason
$block = 'unknown'
if ($outputValue -eq 'export') { $block = 'output-export-disables-api' }
elseif ($srcAppExists -eq $false) { $block = 'missing-src-app' }
elseif ($tsIncludesSrc -eq $false) { $block = 'tsconfig-missing-src-include' }
elseif ([string]::IsNullOrWhiteSpace($startScript)) { $block = 'missing-start-script' }
elseif ($null -eq $outputValue) { $block = 'no-output-specified' }
else { $block = 'config-ok' }

# 6) summary
$summary = [ordered]@{
  config_file            = $configFile
  output_value           = $outputValue
  experimental_app_dir   = $expAppDir
  package_start_cmd      = $startScript
  tsconfig_file          = $tsFile
  tsconfig_src_includes  = $tsIncludesSrc
  src_app_exists         = $srcAppExists
  blocking_reason        = $block
  log_file               = $stepLog
  duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_fix_step     = $true
}
J 'info' 'summary' 'S5.1i config-inspect summary' $summary

Write-Host ("`n== S5.1i Health: READY (see {0})" -f $stepLog)
