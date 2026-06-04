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

function Try-ApplyPatch {
  param(
    [string]$PatchPath,
    [string]$PatchName
  )

  $checkFailures = @()
  $modes = @(
    @{
      Name = "plain"
      Check = @("apply", "--check", $PatchPath)
      Apply = @("apply", $PatchPath)
    },
    @{
      Name = "ignore-whitespace"
      Check = @("apply", "--check", "--ignore-space-change", "--ignore-whitespace", $PatchPath)
      Apply = @("apply", "--ignore-space-change", "--ignore-whitespace", $PatchPath)
    },
    @{
      Name = "three-way"
      Check = @("apply", "--check", "--3way", $PatchPath)
      Apply = @("apply", "--3way", $PatchPath)
    },
    @{
      Name = "three-way-ignore-whitespace"
      Check = @("apply", "--check", "--3way", "--ignore-space-change", "--ignore-whitespace", $PatchPath)
      Apply = @("apply", "--3way", "--ignore-space-change", "--ignore-whitespace", $PatchPath)
    }
  )

  foreach ($mode in $modes) {
    $check = Invoke-Git $mode.Check
    if ($check.ExitCode -eq 0) {
      $apply = Invoke-Git $mode.Apply
      if ($apply.ExitCode -ne 0) {
        Write-Host $apply.Output
        throw "Failed to apply patch: $PatchName"
      }
      Write-Host "Applied $PatchName"
      return $true
    }
    $checkFailures += [pscustomobject]@{
      Mode = $mode.Name
      Output = $check.Output
    }
  }

  $reverseModes = @(
    @{
      Name = "reverse"
      Check = @("apply", "--reverse", "--check", $PatchPath)
    },
    @{
      Name = "reverse-ignore-whitespace"
      Check = @("apply", "--reverse", "--check", "--ignore-space-change", "--ignore-whitespace", $PatchPath)
    }
  )

  foreach ($mode in $reverseModes) {
    $reverse = Invoke-Git $mode.Check
    if ($reverse.ExitCode -eq 0) {
      Write-Host "Already applied $PatchName"
      return $true
    }
    $checkFailures += [pscustomobject]@{
      Mode = $mode.Name
      Output = $reverse.Output
    }
  }

  Write-Host "Patch $PatchName did not match using any apply mode."
  foreach ($failure in $checkFailures) {
    Write-Host "git apply mode '$($failure.Mode)' failed:"
    if ($failure.Output) {
      Write-Host $failure.Output
    }
  }
  return $false
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

Push-Location $dartSdk
try {
  $dartRevision = Invoke-Git @("rev-parse", "HEAD")
  if ($dartRevision.ExitCode -eq 0) {
    Write-Host "Dart SDK revision: $($dartRevision.Output)"
  }
} finally {
  Pop-Location
}

foreach ($patch in $patches) {
  $patchPath = Join-Path $patchRoot $patch
  if (-not (Test-Path -LiteralPath $patchPath)) {
    throw "Patch file was not found: $patchPath"
  }

  Push-Location $dartSdk
  try {
    if (Try-ApplyPatch $patchPath $patch) {
      continue
    }

    if ($patch -eq "0001-revert-platform-win-hostname.patch") {
      $platformWin = Join-Path $dartSdk "runtime\bin\platform_win.cc"
      Write-Host "Current LocalHostname context:"
      Select-String -Path $platformWin -Pattern "LocalHostname|GetHostNameW|gethostname|WideCharToMultiByte" -Context 4,4
    }
    throw "Patch does not apply cleanly: $patch"
  } finally {
    Pop-Location
  }
}
