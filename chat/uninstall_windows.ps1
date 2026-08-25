# Remove what install_windows.ps1 created -- Windows (PowerShell).
#
#   powershell -ExecutionPolicy Bypass -File uninstall_windows.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

$Model = if ($env:CHALICE_MODEL) { $env:CHALICE_MODEL } else { 'qwen2.5-coder:3b' }

# The virtual environment is ours alone, so it goes without asking.
if (Test-Path '.venv') {
    Remove-Item -Recurse -Force '.venv'
    Write-Host '  Removed the Python virtual environment.' -ForegroundColor Green
} else {
    Write-Host '  No virtual environment to remove.' -ForegroundColor DarkGray
}

Get-ChildItem -Path . -Filter '__pycache__' -Recurse -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# The model is shared: something else on this machine may be using it, so ask.
$ollama = Find-Ollama
if ($ollama) {
    $installed = (& $ollama list) -join "`n"
    if ($installed -match [regex]::Escape($Model)) {
        Write-Host "`n  The language model $Model (about 1.9 GB) is still installed." -ForegroundColor Yellow
        Write-Host '  Other tools on this machine may be using it.'
        $reply = Read-Host '  Remove it? [y/N]'
        if ($reply -match '^[yY]') {
            & $ollama rm $Model
            Write-Host "  Removed $Model." -ForegroundColor Green
        } else {
            Write-Host '  Left in place.' -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n  Ollama itself was not removed -- uninstall it from Windows Settings if you want it gone.`n" -ForegroundColor DarkGray
