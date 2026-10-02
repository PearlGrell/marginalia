<#
.SYNOPSIS
  Builds the Marginalia APK and copies it to a USB-connected phone, without adb.

.DESCRIPTION
  The phone is reached through Windows' "This PC" device list (MTP, the same as
  copying in File Explorer), so USB debugging isn't needed. Unlock the phone and set
  USB to "File transfer" first. Then install the APK from the phone's Files app.

.EXAMPLE
  .\scripts\deploy-to-phone.ps1
  Debug build, copied to Marginalia/marginalia-debug-<time>.apk on the first phone found.

.EXAMPLE
  .\scripts\deploy-to-phone.ps1 -Mode release
  Release build for arm64 phones (much smaller and smoother), Marginalia/marginalia-release-<time>.apk.

.EXAMPLE
  .\scripts\deploy-to-phone.ps1 -SkipBuild -Device "Pixel 6a" -Folder Download
#>
param(
  [ValidateSet('debug', 'profile', 'release')]
  [string]$Mode = 'debug',

  [switch]$Release,

  # Copy the last build without rebuilding.
  [switch]$SkipBuild,

  # Phone name as shown under This PC. Defaults to the first phone found.
  [string]$Device,

  # Folder at the top of the phone's internal storage; created if missing.
  [string]$Folder = 'Marginalia'
)

if ($Release) {
  $Mode = 'release'
}

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
# A fresh name per build: Android's media index can keep serving an old file that was
# replaced in place over MTP, so the phone would install a stale build.
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$apkName = "marginalia-$Mode-$stamp.apk"

# ---- Build ----

$apkDir = Join-Path $projectRoot 'build\app\outputs\flutter-apk'
$builtApk = Join-Path $apkDir "app-$Mode.apk"

if (-not $SkipBuild) {
  Write-Host "Building $Mode APK..."
  # The build number rises with every build (minutes since 2026), so Android treats each
  # install as an update, and the build time shows on the home screen.
  $buildNumber = [int]((Get-Date) - [datetime]'2026-01-01').TotalMinutes
  $buildArgs = @('build', 'apk', "--$Mode", "--build-number=$buildNumber",
    "--dart-define=BUILD_STAMP=$stamp")
  # The Firebase project for sync, if this checkout has one (see docs/cloud-setup.md).
  $cloudConfig = Join-Path $projectRoot 'cloud.json'
  if (Test-Path $cloudConfig) { $buildArgs += "--dart-define-from-file=$cloudConfig" }
  # Debug builds need every ABI for hot reload tooling; others only need phones' arm64.
  if ($Mode -ne 'debug') { $buildArgs += @('--target-platform', 'android-arm64') }
  Push-Location $projectRoot
  try {
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path $builtApk)) {
  throw "No APK at $builtApk. Run without -SkipBuild first."
}

# ---- Find the phone ----

$shell = New-Object -ComObject Shell.Application
$devices = @($shell.NameSpace(17).Items() | Where-Object {
  $_.Type -match 'phone|portable|device' -and $_.Name -notmatch '\([A-Z]:\)$'
})
if ($Device) { $devices = @($devices | Where-Object Name -eq $Device) }
if ($devices.Count -eq 0) {
  throw "No phone found. Connect it by USB, unlock it, and set USB to 'File transfer'."
}
$phone = $devices[0]

$storage = @($phone.GetFolder.Items())[0]
if (-not $storage) {
  throw "Can't see $($phone.Name)'s storage. Unlock the phone and allow file access."
}
$storageFolder = $storage.GetFolder
$target = $storageFolder.Items() | Where-Object Name -eq $Folder
if (-not $target) {
  Write-Host "Creating $Folder on $($phone.Name)"
  $storageFolder.NewFolder($Folder)
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 500
    $target = $storageFolder.Items() | Where-Object Name -eq $Folder
  } until ($target -or (Get-Date) -gt $deadline)
  if (-not $target) { throw "Couldn't create '$Folder' on $($phone.Name)." }
}
$targetFolder = $target.GetFolder

# ---- Copy ----

# Shell copies keep the source name, so stage the APK under its final name.
$staging = Join-Path ([IO.Path]::GetTempPath()) 'marginalia-deploy'
New-Item -ItemType Directory -Force $staging | Out-Null
$staged = Join-Path $staging $apkName
Copy-Item $builtApk $staged -Force
$expectedBytes = (Get-Item $staged).Length

Write-Host ("Copying {0} ({1:N0} MB) to {2}\{3}..." -f $apkName, ($expectedBytes / 1MB), $phone.Name, $Folder)

# Remove older builds so the right one is easy to pick.
$old = @($targetFolder.Items() | Where-Object Name -like 'marginalia-*.apk')
foreach ($file in $old) {
  Write-Host "Removing old $($file.Name)"
  $file.InvokeVerb('delete')
}
if ($old.Count -gt 0) { Start-Sleep -Seconds 2 }

# 4 = no progress dialog, 16 = yes to all prompts.
$targetFolder.CopyHere($staged, 20)

# CopyHere returns immediately; wait until the file appears with its full size.
$deadline = (Get-Date).AddMinutes(10)
do {
  Start-Sleep -Seconds 2
  $copied = $targetFolder.Items() | Where-Object Name -eq $apkName
  $bytes = if ($copied) { $copied.ExtendedProperty('System.Size') } else { 0 }
} until (($copied -and $bytes -ge $expectedBytes) -or (Get-Date) -gt $deadline)

Remove-Item $staged -Force -ErrorAction SilentlyContinue

if (-not $copied -or $bytes -lt $expectedBytes) {
  throw "Copy didn't finish within 10 minutes. Check the phone's $Folder folder."
}
Write-Host "Done: $($phone.Name)\$Folder\$apkName"
Write-Host "Install it from the phone's Files app."
