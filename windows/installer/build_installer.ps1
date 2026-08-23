#Requires -Version 5.1
<#
.SYNOPSIS
    Builds SnipSnap for Windows and packages it into a single installer .exe.

.DESCRIPTION
    Run from anywhere; paths are resolved relative to this script. The finished
    installer lands in dist\ at the repo root and is the only file you need to
    send to someone.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1

.PARAMETER SkipFlutterBuild
    Package whatever is already in build\windows\x64\runner\Release instead of
    rebuilding. Useful when iterating on the installer itself.
#>
[CmdletBinding()]
param(
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Resolve-Path (Join-Path $ScriptDir '..\..')
$ReleaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
$OutputDir  = Join-Path $RepoRoot 'dist'
$IssFile    = Join-Path $ScriptDir 'snipsnap.iss'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# --- 1. Version, read from pubspec so the installer never drifts from the app --
Write-Step 'Reading version from pubspec.yaml'
$pubspec = Get-Content (Join-Path $RepoRoot 'pubspec.yaml') -Raw
$match = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?')
if (-not $match.Success) { throw 'Could not parse "version:" from pubspec.yaml' }
$Version = $match.Groups[1].Value
Write-Host "    SnipSnap $Version"

# --- 2. Build ----------------------------------------------------------------
if ($SkipFlutterBuild) {
    Write-Step 'Skipping flutter build (-SkipFlutterBuild)'
} else {
    Write-Step 'flutter build windows --release'
    Push-Location $RepoRoot
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
}

if (-not (Test-Path (Join-Path $ReleaseDir 'snipsnap.exe'))) {
    throw "No snipsnap.exe in $ReleaseDir - the build did not produce a bundle."
}

# --- 3. Visual C++ runtime, copied in next to the exe ------------------------
# The Flutter bundle does not include the MSVC runtime, and a machine that has
# never had Visual Studio or a VC++ redistributable on it will fail to start the
# app with a missing-DLL dialog. Copying the DLLs into the app directory
# (app-local deployment) avoids needing admin rights to install the system-wide
# redistributable, which a per-user installer does not have.
Write-Step 'Adding the Visual C++ runtime DLLs'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$crtCopied = $false
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($vsPath) {
        $redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
        # Microsoft.VCRedistVersion.default.txt names the version Microsoft
        # considers current, but the folder actually on disk is frequently a
        # different patch level, so treat the file as a hint and fall back to
        # whatever versioned folder is newest.
        $candidates = @()
        $verFile = Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt'
        if (Test-Path $verFile) {
            $candidates += Join-Path $redistRoot ((Get-Content $verFile -Raw).Trim())
        }
        if (Test-Path $redistRoot) {
            $candidates += (Get-ChildItem $redistRoot -Directory |
                            Sort-Object Name -Descending |
                            ForEach-Object { $_.FullName })
        }

        $crtDir = $candidates |
                  Where-Object { Test-Path (Join-Path $_ 'x64') } |
                  ForEach-Object {
                      Get-ChildItem (Join-Path $_ 'x64') -Directory `
                          -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
                  } |
                  Select-Object -First 1

        if ($crtDir) {
            Copy-Item (Join-Path $crtDir.FullName '*.dll') -Destination $ReleaseDir -Force
            Write-Host "    from $($crtDir.FullName)"
            $crtCopied = $true
        }
    }
}
if (-not $crtCopied) {
    Write-Warning ('Could not locate the VC++ redistributable DLLs. The installer will ' +
                   'still build, but will only run on machines that already have the ' +
                   'Visual C++ Redistributable installed.')
}

# --- 4. Inno Setup -----------------------------------------------------------
Write-Step 'Locating Inno Setup'
$iscc = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles       'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { $iscc = $onPath.Source }
}

if (-not $iscc) {
    Write-Host '    Inno Setup is not installed.' -ForegroundColor Yellow
    # Never block on a prompt in CI - the job would hang until it timed out.
    $interactive = [Environment]::UserInteractive -and -not $env:CI
    $answer = if ($interactive) { Read-Host '    Install it now with winget? [Y/n]' } else { 'n' }
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        & winget install --id JRSoftware.InnoSetup --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget install failed with exit code $LASTEXITCODE" }
        $iscc = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles       'Inno Setup 6\ISCC.exe')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $iscc) {
        throw 'Inno Setup 6 is required. Install it from https://jrsoftware.org/isdl.php and re-run.'
    }
}
Write-Host "    $iscc"

Write-Step 'Compiling the installer'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
& $iscc `
    "/DMyAppVersion=$Version" `
    "/DSourceDir=$ReleaseDir" `
    "/DOutputDir=$OutputDir" `
    $IssFile
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$installer = Join-Path $OutputDir "SnipSnap-$Version-windows-x64-setup.exe"
$sizeMb = [math]::Round((Get-Item $installer).Length / 1MB, 1)

Write-Host "`nInstaller ready:" -ForegroundColor Green
Write-Host "  $installer  ($sizeMb MB)"
Write-Host ''
Write-Host 'This is unsigned, so the first person to run it will see a blue' -ForegroundColor Yellow
Write-Host '"Windows protected your PC" screen. They need to click More info,' -ForegroundColor Yellow
Write-Host 'then Run anyway. See docs/release.md.' -ForegroundColor Yellow
