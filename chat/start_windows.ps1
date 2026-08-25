# Launch Chalice Chat -- Windows (PowerShell).
# Run install_windows.ps1 first.
#
#   powershell -ExecutionPolicy Bypass -File start_windows.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

$Port = if ($env:CHALICE_PORT) { $env:CHALICE_PORT } else { '8501' }
$VenvStreamlit = '.venv\Scripts\streamlit.exe'

if (-not (Test-Path $VenvStreamlit)) {
    Write-Host "`n  Not installed yet. Run this first:`n" -ForegroundColor Red
    Write-Host "      powershell -ExecutionPolicy Bypass -File install_windows.ps1`n"
    exit 1
}

# Starting Ollama here means the user never has to think about it. The binary is
# resolved rather than assumed to be on PATH: a per-user install is not visible
# to a terminal that was already open when it happened.
if (-not (Test-OllamaUp)) {
    $ollama = Find-Ollama
    if (-not $ollama) {
        Write-Host "`n  Ollama is not installed. Run this first:`n" -ForegroundColor Red
        Write-Host "      powershell -ExecutionPolicy Bypass -File install_windows.ps1`n"
        exit 1
    }
    Write-Host '  Starting Ollama...' -ForegroundColor DarkGray
    if (-not (Start-OllamaServer $ollama)) {
        Write-Host "`n  Ollama did not come up on http://localhost:11434." -ForegroundColor Red
        Write-Host "  Try starting it yourself: $ollama serve`n"
        exit 1
    }
}

Write-Host "`n  Chalice Chat -> http://localhost:$Port" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

& $VenvStreamlit run app.py `
    --server.port $Port `
    --server.address localhost `
    --server.headless false `
    --browser.gatherUsageStats false
