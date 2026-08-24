# Chalice Chat installer -- Windows (PowerShell).
#
# The bash scripts cover macOS, Linux, and Windows under WSL or Git Bash. This is
# the native Windows path, for a reviewer who has neither.
#
#   powershell -ExecutionPolicy Bypass -File install_windows.ps1
#
# The ExecutionPolicy flag is needed because Windows blocks unsigned scripts by
# default; it applies to this invocation only and changes nothing permanently.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$Model = if ($env:CHALICE_MODEL) { $env:CHALICE_MODEL } else { 'qwen2.5-coder:3b' }
$Venv  = '.venv'
$VenvPython = Join-Path $Venv 'Scripts\python.exe'

function Step($n, $text) { Write-Host "`n[$n/5] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "      $text" -ForegroundColor Green }
function Fail($text)     { Write-Host "`n  $text`n" -ForegroundColor Red; exit 1 }

function Test-Ollama {
    try   { Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

# 1 ------------------------------------------------------------------- python
Step 1 'Checking Python'
$python = $null
foreach ($candidate in @('py -3.12', 'py -3.11', 'py -3.10', 'py -3', 'python')) {
    $parts = $candidate.Split(' ')
    $exe   = $parts[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $args = @()
    if ($parts.Count -gt 1) { $args += $parts[1] }
    $args += @('-c', 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)')
    & $exe @args 2>$null
    if ($LASTEXITCODE -eq 0) { $python = $candidate; break }
}
if (-not $python) {
    Fail "Python 3.9+ is required but was not found. Install it from https://python.org (tick 'Add Python to PATH') and re-run."
}
Ok "Python found ($python)"

# 2 --------------------------------------------------------------------- venv
Step 2 'Creating virtual environment'
if (-not (Test-Path $Venv)) {
    $parts = $python.Split(' ')
    $exe   = $parts[0]
    $args  = @()
    if ($parts.Count -gt 1) { $args += $parts[1] }
    $args += @('-m', 'venv', $Venv)
    & $exe @args
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
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "`n  Ollama is not installed. It runs the language model locally." -ForegroundColor Yellow
    Fail 'Install it from https://ollama.com/download, then re-run this script.'
}
if (-not (Test-Ollama)) {
    Write-Host '      Starting Ollama...' -ForegroundColor DarkGray
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Ollama) { break } }
}
if (-not (Test-Ollama)) { Fail 'Ollama is installed but not responding on http://localhost:11434.' }
Ok 'Ollama running'

# 5 -------------------------------------------------------------------- model
Step 5 "Downloading the language model ($Model, about 1.9 GB)"
$installed = (& ollama list) -join "`n"
if ($installed -match [regex]::Escape($Model)) {
    Ok 'Model already present'
} else {
    Write-Host '      This is the one large download. Progress is shown by Ollama.' -ForegroundColor DarkGray
    & ollama pull $Model
    if ($LASTEXITCODE -ne 0) { Fail "Downloading $Model failed. Check your connection and re-run." }
    Ok 'Model downloaded'
}

# ------------------------------------------------------------------ database
if (-not (Test-Path 'data\chalice.duckdb')) {
    Write-Host "`n  Note: no database found at data\chalice.duckdb." -ForegroundColor Yellow
    Write-Host '  This bundle should ship with one; the app will not start without it.'
}

Write-Host "`n  Installed. Start it with:`n" -ForegroundColor Green
Write-Host "      powershell -ExecutionPolicy Bypass -File start_windows.ps1`n"
