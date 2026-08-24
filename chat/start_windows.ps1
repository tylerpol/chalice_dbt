# Launch Chalice Chat -- Windows (PowerShell).
# Run install_windows.ps1 first.
#
#   powershell -ExecutionPolicy Bypass -File start_windows.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$Port = if ($env:CHALICE_PORT) { $env:CHALICE_PORT } else { '8501' }
$VenvStreamlit = '.venv\Scripts\streamlit.exe'

if (-not (Test-Path $VenvStreamlit)) {
    Write-Host "`n  Not installed yet. Run this first:`n" -ForegroundColor Red
    Write-Host "      powershell -ExecutionPolicy Bypass -File install_windows.ps1`n"
    exit 1
}

function Test-Ollama {
    try   { Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

# Starting Ollama here means the user never has to think about it.
if (-not (Test-Ollama)) {
    Write-Host '  Starting Ollama...' -ForegroundColor DarkGray
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Ollama) { break } }
}

Write-Host "`n  Chalice Chat -> http://localhost:$Port" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

& $VenvStreamlit run app.py `
    --server.port $Port `
    --server.address localhost `
    --server.headless false `
    --browser.gatherUsageStats false
