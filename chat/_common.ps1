# Shared helpers for the Windows scripts. Dot-sourced, never run on its own.
#
# Written for Windows PowerShell 5.1, which is what `powershell -File` runs and
# what every Windows machine already has. That rules out the ternary and null
# coalescing operators, and it is why downloads go through WebClient below.

# 5.1 negotiates TLS 1.0 by default and every download host now refuses it.
# Harmless on PowerShell 7, which already defaults to the system setting.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-RemoteFile($Url, $OutFile) {
    # WebClient streams straight to disk. Invoke-WebRequest on 5.1 buffers the
    # whole response in memory first, which a 1.5GB installer does not survive.
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $OutFile)
    } catch {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
}

function Update-PathFromRegistry {
    # A fresh install writes PATH into the registry, but this process still holds
    # the copy it started with. Without this, a Python or Ollama we just installed
    # stays invisible until the user opens a new terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $merged  = (@($machine, $user) | Where-Object { $_ }) -join ';'
    # Only replace a PATH we actually managed to read. Assigning an empty string
    # here would strip the running process of pip, venv and everything else.
    if ($merged) { $env:Path = $merged }
}

# --- ollama ------------------------------------------------------------------
function Test-OllamaUp {
    try   { Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

function Find-Ollama {
    # PATH wins, so a copy the user installed themselves is preferred over ours.
    if ($env:CHALICE_OLLAMA -and (Test-Path $env:CHALICE_OLLAMA)) { return $env:CHALICE_OLLAMA }

    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($rel in @('Programs\Ollama\ollama.exe', 'Ollama\ollama.exe')) {
            $candidate = Join-Path $root $rel
            if (Test-Path $candidate) { return $candidate }
        }
    }
    return $null
}

function Start-OllamaServer($OllamaPath) {
    if (Test-OllamaUp) { return $true }
    Start-Process -FilePath $OllamaPath -ArgumentList 'serve' -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-OllamaUp) { return $true }
    }
    return (Test-OllamaUp)
}

# --- python ------------------------------------------------------------------
# Returned as an object because a full path can contain spaces, which a
# string-splitting caller would tear in half.
function New-PythonRef($Exe, $Pre) {
    return New-Object PSObject -Property @{ Exe = $Exe; Pre = @($Pre | Where-Object { $_ }) }
}

function Test-PythonRef($Ref) {
    $probe = @('-c', 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)')
    try {
        & $Ref.Exe @($Ref.Pre + $probe) 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Find-Python {
    # The launcher first: it knows about every version installed, whatever PATH says.
    foreach ($v in @('-3.13', '-3.12', '-3.11', '-3.10', '-3')) {
        if (Get-Command 'py' -ErrorAction SilentlyContinue) {
            $ref = New-PythonRef 'py' $v
            if (Test-PythonRef $ref) { return $ref }
        }
    }
    foreach ($name in @('python3', 'python')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) {
            $ref = New-PythonRef $name @()
            if (Test-PythonRef $ref) { return $ref }
        }
    }
    # A per-user install that has not reached PATH yet -- the usual state
    # immediately after installing without opening a new terminal.
    foreach ($root in @("$env:LOCALAPPDATA\Programs\Python", "$env:ProgramFiles\Python")) {
        if (-not (Test-Path $root)) { continue }
        $dirs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        foreach ($d in $dirs) {
            $exe = Join-Path $d.FullName 'python.exe'
            if (-not (Test-Path $exe)) { continue }
            $ref = New-PythonRef $exe @()
            if (Test-PythonRef $ref) { return $ref }
        }
    }
    return $null
}
