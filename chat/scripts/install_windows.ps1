# Chalice Chat installer -- Windows (PowerShell).
#
# The bash scripts cover macOS, Linux, and Windows under WSL or Git Bash. This is
# the native Windows path, for a reviewer who has neither.
#
#   powershell -ExecutionPolicy Bypass -File scripts\install_windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install_windows.ps1 -Yes
#
# The ExecutionPolicy flag is needed because Windows blocks unsigned scripts by
# default; it applies to this invocation only and changes nothing permanently.
#
# Python and Ollama are installed for you if they are missing. Both go in per
# user, so neither triggers an administrator prompt. -Yes skips the questions.

param([switch]$Yes)

$ErrorActionPreference = 'Stop'
# This script lives in scripts\ but operates on the app root one level up,
# where the virtual environment, requirements.txt and app.py live.
. (Join-Path $PSScriptRoot '_common.ps1')
Set-Location -Path (Split-Path $PSScriptRoot -Parent)

$Model      = if ($env:CHALICE_MODEL) { $env:CHALICE_MODEL } else { 'qwen2.5-coder:3b' }
$Venv       = '.venv'
$VenvPython = Join-Path $Venv 'Scripts\python.exe'
$PythonVersion = '3.12.10'   # pinned for the python.org fallback only

function Step($n, $text) { Write-Host "`n[$n/5] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "      $text" -ForegroundColor Green }
function Info($text)     { Write-Host "      $text" -ForegroundColor DarkGray }
function Fail($text)     { Write-Host "`n  $text`n" -ForegroundColor Red; exit 1 }

function Confirm-Step($question) {
    if ($Yes) { return $true }
    $reply = Read-Host "  $question [y/N]"
    return ($reply -match '^[yY]')
}

function Install-Python {
    # winget first: it is the supported route and handles PATH properly.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info 'Installing Python 3.12 via winget...'
        try {
            & winget install --id Python.Python.3.12 --exact --source winget --scope user `
                --accept-package-agreements --accept-source-agreements --disable-interactivity
        } catch {
            Info "winget failed: $($_.Exception.Message)"
        }
        Update-PathFromRegistry
        if (Find-Python) { return }
        Info 'winget did not produce a usable Python; falling back to python.org.'
    }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $url  = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-$arch.exe"
    $out  = Join-Path $env:TEMP "python-$PythonVersion-$arch.exe"

    Info "Downloading Python $PythonVersion ($arch, about 25MB)..."
    try { Get-RemoteFile $url $out } catch { Fail "Downloading Python failed: $($_.Exception.Message)" }

    Info 'Running the installer (per user, no administrator prompt)...'
    # PrependPath puts it on PATH for future terminals; this one is refreshed below.
    $proc = Start-Process -FilePath $out -Wait -PassThru -ArgumentList @(
        '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1', 'Include_test=0'
    )
    Remove-Item $out -Force -ErrorAction SilentlyContinue

    # 3010 is "installed, wants a reboot" -- the install itself succeeded.
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Fail "The Python installer exited with code $($proc.ExitCode)."
    }
    Update-PathFromRegistry
}

function Install-Ollama {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info 'Installing Ollama via winget...'
        try {
            & winget install --id Ollama.Ollama --exact --source winget `
                --accept-package-agreements --accept-source-agreements --disable-interactivity
        } catch {
            Info "winget failed: $($_.Exception.Message)"
        }
        Update-PathFromRegistry
        if (Find-Ollama) { return }
        Info 'winget did not produce a usable Ollama; falling back to the direct download.'
    }

    $out = Join-Path $env:TEMP 'OllamaSetup.exe'
    Info 'Downloading the Ollama installer (about 1.5GB) -- this is the slow part...'
    try { Get-RemoteFile 'https://ollama.com/download/OllamaSetup.exe' $out }
    catch { Fail "Downloading Ollama failed: $($_.Exception.Message)" }

    Info 'Running it silently...'
    # Inno Setup flags; verified against the installer this URL serves.
    $proc = Start-Process -FilePath $out -Wait -PassThru `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Remove-Item $out -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Fail "The Ollama installer exited with code $($proc.ExitCode)."
    }
    Update-PathFromRegistry

    # Inno Setup can return before the files have finished landing.
    for ($i = 0; $i -lt 60; $i++) {
        if (Find-Ollama) { break }
        Start-Sleep -Seconds 2
    }
}

# 1 ------------------------------------------------------------------- python
Step 1 'Checking Python'
$python = Find-Python
if (-not $python) {
    Write-Host "`n  Python 3.9+ was not found. It is needed to run the app." -ForegroundColor Yellow
    Info 'It installs for this user only, so there is no administrator prompt.'
    if (-not (Confirm-Step 'Install Python 3.12 now?')) {
        Fail "Python 3.9+ is required. Install it from https://python.org (tick 'Add Python to PATH') and re-run."
    }
    Install-Python
    $python = Find-Python
    if (-not $python) {
        Fail "Python was installed but cannot be found. Close this window, open a new PowerShell, and re-run this script."
    }
}
$pythonVersionText = (& $python.Exe @($python.Pre + @('--version')) 2>&1) -join ' '
Ok "Python found ($pythonVersionText)"

# 2 --------------------------------------------------------------------- venv
Step 2 'Creating virtual environment'
if (-not (Test-Path $Venv)) {
    & $python.Exe @($python.Pre + @('-m', 'venv', $Venv))
    if ($LASTEXITCODE -ne 0) { Fail "Could not create a virtual environment in $Venv" }
}
if (-not (Test-Path $VenvPython)) { Fail "The virtual environment looks incomplete -- no python at $VenvPython" }
Ok 'Virtual environment ready'

# 3 ----------------------------------------------------------------- packages
Step 3 'Installing Python packages'
& $VenvPython -m pip install --quiet --upgrade pip 2>$null | Out-Null
& $VenvPython -m pip install --quiet -r requirements.txt
if ($LASTEXITCODE -ne 0) {
    Fail "Installing Python packages failed. Re-run without --quiet to see why:`n    $VenvPython -m pip install -r requirements.txt"
}
Ok 'Python packages installed'

# 4 ------------------------------------------------------------------- ollama
Step 4 'Checking Ollama'
$ollama = Find-Ollama
if (-not $ollama) {
    Write-Host "`n  Ollama is not installed. It runs the language model on this machine." -ForegroundColor Yellow
    Info 'About 1.5GB, installed for this user only.'
    if (-not (Confirm-Step 'Install Ollama now?')) {
        Fail 'Ollama is required. Install it from https://ollama.com/download and re-run.'
    }
    Install-Ollama
    $ollama = Find-Ollama
    if (-not $ollama) {
        Fail "Ollama was installed but cannot be found. Close this window, open a new PowerShell, and re-run this script.`n  Or set CHALICE_OLLAMA to the full path of ollama.exe."
    }
}
if (-not (Start-OllamaServer $ollama)) {
    Fail "Ollama is installed at $ollama but is not responding on http://localhost:11434.`n  Start it manually with: $ollama serve"
}
Ok 'Ollama running'

# 5 -------------------------------------------------------------------- model
Step 5 "Downloading the language model ($Model, about 1.9 GB)"
$installed = (& $ollama list) -join "`n"
if ($installed -match [regex]::Escape($Model)) {
    Ok 'Model already present'
} else {
    Info 'This is the one large download. Progress is shown by Ollama.'
    & $ollama pull $Model
    if ($LASTEXITCODE -ne 0) { Fail "Downloading $Model failed. Check your connection and re-run." }
    Ok 'Model downloaded'
}

# ------------------------------------------------------------------ database
if (-not (Test-Path 'data\chalice.duckdb')) {
    Write-Host "`n  Note: no database found at data\chalice.duckdb." -ForegroundColor Yellow
    Write-Host '  This bundle should ship with one; the app will not start without it.'
}

Write-Host "`n  Installed. Start it with:`n" -ForegroundColor Green
Write-Host "      powershell -ExecutionPolicy Bypass -File scripts\start_windows.ps1`n"
