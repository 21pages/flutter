param(
  [string]$DartSdkPath = (Join-Path $PSScriptRoot "..\src\flutter\third_party\dart"),
  [string]$PatchDir = (Join-Path $PSScriptRoot "..\patches\windows7")
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
  param(
    [string[]]$Arguments
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git @Arguments 2>&1
    return [pscustomobject]@{
      ExitCode = $LASTEXITCODE
      Output = $output
    }
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

$dartSdk = (Resolve-Path -LiteralPath $DartSdkPath).Path
$patchRoot = (Resolve-Path -LiteralPath $PatchDir).Path

$requiredFile = Join-Path $dartSdk "runtime\bin\platform_win.cc"
if (-not (Test-Path -LiteralPath $requiredFile)) {
  throw "Dart SDK source tree was not found at '$dartSdk'. Run gclient sync first."
}

$patches = @(
  "0001-revert-platform-win-hostname.patch",
  "0002-win7-load-unwinding-records-api-dynamically.patch",
  "0003-remove-pathcch-dependency-from-file-win.patch"
)

foreach ($patch in $patches) {
  $patchPath = Join-Path $patchRoot $patch
  if (-not (Test-Path -LiteralPath $patchPath)) {
    throw "Patch file was not found: $patchPath"
  }

  Push-Location $dartSdk
  try {
    $check = Invoke-Git @("apply", "--check", $patchPath)
    if ($check.ExitCode -eq 0) {
      $apply = Invoke-Git @("apply", $patchPath)
      if ($apply.ExitCode -ne 0) {
        Write-Host $apply.Output
        throw "Failed to apply patch: $patch"
      }
      Write-Host "Applied $patch"
      continue
    }

    $reverse = Invoke-Git @("apply", "--reverse", "--check", $patchPath)
    if ($reverse.ExitCode -eq 0) {
      Write-Host "Already applied $patch"
      continue
    }

    Write-Host $check.Output
    Write-Host $reverse.Output
    throw "Patch does not apply cleanly: $patch"
  } finally {
    Pop-Location
  }
}
