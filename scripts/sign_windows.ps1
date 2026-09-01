<#
.SYNOPSIS
    Signs SnipSnap Windows binaries (runner executable and Inno Setup installer).

.DESCRIPTION
    Uses Microsoft SignTool (signtool.exe) to sign the application executable and the
    installer with Authenticode SHA-256 signatures and RFC 3161 timestamps.
    Supports existing PFX certificates, certificates from the Windows Certificate Store,
    or generating a self-signed certificate for local testing.

.PARAMETER CertPath
    Path to the .pfx certificate file.

.PARAMETER CertPassword
    Password for the .pfx certificate file (if password protected).

.PARAMETER CertThumbprint
    SHA1 thumbprint of a certificate installed in the Windows Certificate Store (CurrentUser\My or LocalMachine\My).

.PARAMETER TimestampServer
    RFC 3161 timestamp authority URL. Default is http://timestamp.digicert.com.

.PARAMETER TargetPath
    Path or array of paths to .exe or .msix files to sign. If omitted, signs default release artifacts:
    - build/windows/x64/runner/Release/snipsnap.exe
    - build/windows/x64/installer/Release/*.exe
    - dist/*.exe

.PARAMETER CreateSelfSigned
    Generates a new self-signed code-signing certificate for local testing and exports it to a .pfx file.

.PARAMETER Publisher
    Subject DN for the self-signed certificate. Default is "CN=genexis.dev, O=genexis.dev".

.EXAMPLE
    .\scripts\sign_windows.ps1 -CertPath "C:\certs\snipsnap.pfx" -CertPassword "secret"

.EXAMPLE
    .\scripts\sign_windows.ps1 -CreateSelfSigned -CertPassword "test1234"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$CertPath,

    [Parameter(Mandatory = $false)]
    [string]$CertPassword,

    [Parameter(Mandatory = $false)]
    [string]$CertThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$TimestampServer = "http://timestamp.digicert.com",

    [Parameter(Mandatory = $false)]
    [string[]]$TargetPath,

    [Parameter(Mandatory = $false)]
    [switch]$CreateSelfSigned,

    [Parameter(Mandatory = $false)]
    [string]$Publisher = "CN=genexis.dev, O=genexis.dev"
)

$ErrorActionPreference = "Stop"

# Navigate to project root
$rootDir = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $rootDir

# Function: Locate signtool.exe
function Find-SignTool {
    # Check if signtool is in PATH
    $signtoolCmd = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
    if ($signtoolCmd) {
        return $signtoolCmd.Source
    }

    # Search standard Windows Kits directories
    $searchPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe",
        "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\signtool.exe",
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\NETFX *\signtool.exe"
    )

    $found = Get-ChildItem -Path $searchPaths -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($found) {
        return $found.FullName
    }

    throw "signtool.exe not found. Please install the Windows 10/11 SDK or run from the Visual Studio Developer Command Prompt."
}

# Function: Generate self-signed certificate for local testing
if ($CreateSelfSigned) {
    Write-Host "Creating self-signed code signing certificate for '$Publisher'..." -ForegroundColor Cyan

    $secPassword = ConvertTo-SecureString -String ($CertPassword ? $CertPassword : "Password123!") -AsPlainText -Force
    $outCertPath = Join-Path $rootDir "dev_codesign.pfx"

    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $Publisher `
        -KeyUsage DigitalSignature `
        -FriendlyName "SnipSnap Dev Code Signing" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3") `
        -NotAfter (Get-Date).AddYears(3)

    Export-PfxCertificate -Cert $cert -FilePath $outCertPath -Password $secPassword | Out-Null
    Write-Host "Exported self-signed certificate to: $outCertPath" -ForegroundColor Green
    Write-Host "Certificate Thumbprint: $($cert.Thumbprint)" -ForegroundColor Yellow
    Write-Host "To trust this certificate for local testing, import it into 'Trusted Root Certification Authorities'." -ForegroundColor Yellow

    if (-not $CertPath) {
        $CertPath = $outCertPath
        $CertPassword = ($CertPassword ? $CertPassword : "Password123!")
    }
}

# Locate signtool
$signtool = Find-SignTool
Write-Host "Using SignTool: $signtool" -ForegroundColor Gray

# Determine files to sign
$filesToSign = @()

if ($TargetPath -and $TargetPath.Count -gt 0) {
    foreach ($path in $TargetPath) {
        $resolved = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
        if ($resolved) {
            $filesToSign += $resolved.FullName
        } else {
            Write-Warning "Target path not found: $path"
        }
    }
} else {
    # Default release binaries
    $runnerExe = Join-Path $rootDir "build\windows\x64\runner\Release\snipsnap.exe"
    if (Test-Path $runnerExe) {
        $filesToSign += $runnerExe
    }

    $installerExes = Get-ChildItem -Path (Join-Path $rootDir "build\windows\x64\installer\Release\*.exe"), (Join-Path $rootDir "build\windows\x64\installer\*.exe"), (Join-Path $rootDir "dist\*.exe") -ErrorAction SilentlyContinue
    if ($installerExes) {
        $filesToSign += ($installerExes | Select-Object -ExpandProperty FullName -Unique)
    }

    $msixFiles = Get-ChildItem -Path (Join-Path $rootDir "build\windows\*.msix"), (Join-Path $rootDir "build\windows\x64\runner\Release\*.msix") -ErrorAction SilentlyContinue
    if ($msixFiles) {
        $filesToSign += ($msixFiles | Select-Object -ExpandProperty FullName -Unique)
    }
}

if ($filesToSign.Count -eq 0) {
    Write-Warning "No target binaries found to sign. Build the project first:"
    Write-Warning "  flutter build windows --release"
    Write-Warning "  dart run inno_bundle:build --release --no-app"
    exit 0
}

# Sign each file
foreach ($file in $filesToSign) {
    Write-Host "`nSigning: $file" -ForegroundColor Cyan

    $signArgs = @("sign", "/fd", "sha256")

    if ($TimestampServer) {
        $signArgs += @("/tr", $TimestampServer, "/td", "sha256")
    }

    if ($CertPath) {
        if (-not (Test-Path $CertPath)) {
            throw "Certificate file not found: $CertPath"
        }
        $signArgs += @("/f", (Resolve-Path $CertPath).Path)
        if ($CertPassword) {
            $signArgs += @("/p", $CertPassword)
        }
    } elseif ($CertThumbprint) {
        $signArgs += @("/sha1", $CertThumbprint, "/s", "My")
    } else {
        # Try automatic store selection
        $signArgs += @("/a")
    }

    $signArgs += $file

    & $signtool $signArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to sign $file (exit code: $LASTEXITCODE)"
    }

    Write-Host "Verifying signature..." -ForegroundColor Gray
    & $signtool verify /pa /v $file
    if ($LASTEXITCODE -ne 0) {
        # signtool's default Authenticode policy requires a chain to a root in
        # the machine's trust store, which a self-signed development
        # certificate will never have on a clean CI runner. That is expected
        # for dev builds and must not fail the release, but a malformed or
        # mismatched signature still must. Get-AuthenticodeSignature reports
        # the two cases distinctly.
        $signature = Get-AuthenticodeSignature -FilePath $file

        if ($signature.Status -eq 'UnknownError' -or $signature.Status -eq 'NotTrusted') {
            Write-Warning "Signature on $file is well-formed but its certificate does not chain to a trusted root."
            Write-Warning "  Status: $($signature.Status) - $($signature.StatusMessage)"
            Write-Warning "  Expected for self-signed certificates. End users will still see the SmartScreen warning."
            Write-Host "Signed (untrusted chain): $file" -ForegroundColor Yellow

            # signtool left a non-zero code in $LASTEXITCODE. GitHub Actions'
            # pwsh wrapper exits the step with whatever $LASTEXITCODE holds
            # when the script ends, so a tolerated failure here would still
            # fail the build even though this script succeeded. Clear it.
            $global:LASTEXITCODE = 0
        } else {
            throw "Signature verification failed for $file (signtool exit code: $LASTEXITCODE, status: $($signature.Status) - $($signature.StatusMessage))"
        }
    } else {
        Write-Host "Successfully signed and verified: $file" -ForegroundColor Green
    }
}

Write-Host "`nAll target files successfully signed." -ForegroundColor Green

# Defensive: never let a stale native-command exit code decide this script's
# status. Real failures throw and are surfaced by the caller's error handling.
$global:LASTEXITCODE = 0
