<#
.SYNOPSIS
    Build the FilterInspection Windows installer.

.DESCRIPTION
    1. Reads the version number from NIRcam-first/version.py
    2. Sanity-checks weights/supervised_global.pt is the real (not dummy) file
    3. Compiles nircam_launcher.pyw and BasicDemo.py with Nuitka
    4. Compiles the Inno Setup installer script
    5. Moves the resulting setup exe into dist/ with the version in its name

    Run from the repo root:
        .\build.ps1

    Requires (see PACKAGING.md section 0):
        - Python env with this project's dependencies + nuitka installed
        - MSVC Build Tools (C++ build tools workload)
        - Inno Setup 6 (ISCC.exe on PATH, or set $IsccPath below)
#>

param(
    [string]$PythonExe = "python",
    [string]$IsccPath = "ISCC.exe",
    [int]$MinWeightsSizeMB = 100
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$NirDir = Join-Path $RepoRoot "NIRcam-first"
$BuildDir = Join-Path $RepoRoot "build"
$DistDir = Join-Path $RepoRoot "dist"
$WeightsFile = Join-Path $RepoRoot "weights\supervised_global.pt"

function Fail($msg) {
    Write-Host "BUILD FAILED: $msg" -ForegroundColor Red
    exit 1
}

# --- 1. Version -----------------------------------------------------------
$versionFile = Join-Path $NirDir "version.py"
if (-not (Test-Path $versionFile)) {
    Fail "NIRcam-first/version.py not found. See PACKAGING.md section 9."
}
$versionLine = Select-String -Path $versionFile -Pattern 'VERSION\s*=\s*"([^"]+)"'
if (-not $versionLine) {
    Fail "Could not parse VERSION from $versionFile"
}
$Version = $versionLine.Matches[0].Groups[1].Value
Write-Host "Building FilterInspection v$Version" -ForegroundColor Cyan

# --- 2. Weights sanity check ------------------------------------------------
if (-not (Test-Path $WeightsFile)) {
    Fail "weights/supervised_global.pt not found. Copy the real checkpoint in first (see weights/README.md)."
}
$weightsSizeMB = (Get-Item $WeightsFile).Length / 1MB
Write-Host ("weights/supervised_global.pt size: {0:N1} MB" -f $weightsSizeMB)
if ($weightsSizeMB -lt $MinWeightsSizeMB) {
    Fail "weights/supervised_global.pt is only $([math]::Round($weightsSizeMB,1)) MB (< $MinWeightsSizeMB MB). " + `
         "This looks like the dummy test checkpoint -- swap in the real 274MB file before building a release. See PACKAGING.md section 4."
}

# --- 3. Clean previous build -------------------------------------------------
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
New-Item -ItemType Directory -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# --- 4. Nuitka: splash launcher (onefile) -----------------------------------
Write-Host "`n=== Building nircam_launcher.exe (onefile) ===" -ForegroundColor Cyan
& $PythonExe -m nuitka `
    --onefile `
    --windows-disable-console `
    --enable-plugin=tk-inter `
    --windows-icon-from-ico="$NirDir\assets\nircam_inspection.ico" `
    --include-data-file="$NirDir\assets\splash.png=assets/splash.png" `
    --output-dir="$BuildDir" `
    --output-filename=nircam_launcher.exe `
    "$NirDir\nircam_launcher.pyw"
if ($LASTEXITCODE -ne 0) { Fail "Nuitka failed building nircam_launcher.exe" }

# --- 5. Nuitka: main GUI (standalone folder) --------------------------------
Write-Host "`n=== Building BasicDemo.exe (standalone) ===" -ForegroundColor Cyan
& $PythonExe -m nuitka `
    --standalone `
    --enable-plugin=pyqt5 `
    --windows-icon-from-ico="$NirDir\assets\nircam_inspection.ico" `
    --include-data-file="$WeightsFile=weights/supervised_global.pt" `
    --output-dir="$BuildDir" `
    --output-filename=BasicDemo.exe `
    "$NirDir\BasicDemo.py"
if ($LASTEXITCODE -ne 0) { Fail "Nuitka failed building BasicDemo.exe" }

# --- 5b. Nuitka: fingerprint tool (human-facing, ships to vendor for
# post-install re-activation -- e.g. hardware changed after install and a
# fresh license.key is needed without rerunning the whole installer) -------
Write-Host "`n=== Building FingerprintTool.exe (onefile) ===" -ForegroundColor Cyan
& $PythonExe -m nuitka `
    --onefile `
    --output-dir="$BuildDir" `
    --output-filename=FingerprintTool.exe `
    "$RepoRoot\tools\license\print_fingerprint.py"
if ($LASTEXITCODE -ne 0) { Fail "Nuitka failed building FingerprintTool.exe" }

# --- 5c. Nuitka: installer-facing activation helper (no human interaction,
# called by installer/setup.iss's wizard page; see PACKAGING.md section 5) -
Write-Host "`n=== Building LicenseActivator.exe (onefile) ===" -ForegroundColor Cyan
& $PythonExe -m nuitka `
    --onefile `
    --output-dir="$BuildDir" `
    --output-filename=LicenseActivator.exe `
    "$RepoRoot\tools\license\license_installer_helper.py"
if ($LASTEXITCODE -ne 0) { Fail "Nuitka failed building LicenseActivator.exe" }

# --- 6. Inno Setup -----------------------------------------------------------
Write-Host "`n=== Building installer with Inno Setup ===" -ForegroundColor Cyan
$isccCmd = Get-Command $IsccPath -ErrorAction SilentlyContinue
if (-not $isccCmd) {
    Fail "ISCC.exe (Inno Setup compiler) not found on PATH. Install Inno Setup 6 or pass -IsccPath."
}
& $IsccPath "/DAppVersion=$Version" "/DBuildDir=$BuildDir" "$RepoRoot\installer\setup.iss"
if ($LASTEXITCODE -ne 0) { Fail "Inno Setup compilation failed" }

# --- 7. Done -----------------------------------------------------------------
$setupExe = Join-Path $DistDir "FilterInspection_Setup_v$Version.exe"
if (-not (Test-Path $setupExe)) {
    Fail "Expected installer not found at $setupExe"
}
$setupSizeMB = (Get-Item $setupExe).Length / 1MB
Write-Host "`nBUILD COMPLETE" -ForegroundColor Green
Write-Host ("  {0}" -f $setupExe)
Write-Host ("  {0:N1} MB" -f $setupSizeMB)
Write-Host "`nBefore handing this to the vendor: run the acceptance checklist in PACKAGING.md section 7 on a clean machine." -ForegroundColor Yellow
