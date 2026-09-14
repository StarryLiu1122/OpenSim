$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot

function Get-RegionLabEngine([string]$Requested = '') {
    $candidate = $Requested
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:GODOT_EXE }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Join-Path $prototypeRoot '.tools\godot-4.5.1\Godot_v4.5.1-stable_win64_console.exe'
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Godot not found. Run tools\Install-Godot.ps1, or pass -Godot with the official console executable path.'
    }
    $candidate = (Resolve-Path -LiteralPath $candidate).Path
    $version = (& $candidate --version | Out-String).Trim()
    $lock = Get-Content -LiteralPath (Join-Path $prototypeRoot 'engine.lock.json') -Raw | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $version -ne $lock.version_output) {
        throw "Expected $($lock.version_output); got $version"
    }
    return $candidate
}

function Invoke-RegionLabCheck([string]$Engine, [string[]]$Arguments, [string]$LogBase, [int]$TimeoutSeconds = 60) {
    # Start-Process on Windows requires explicit quoting for paths containing spaces.
    $quoted = @($Arguments | ForEach-Object {
        if ($_.Contains('"') -or $_.Contains("`n")) { throw 'Unexpected quote/newline in process argument.' }
        '"' + $_ + '"'
    })
    $child = Start-Process -FilePath $Engine -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput ($LogBase + '.stdout.txt') -RedirectStandardError ($LogBase + '.stderr.txt')
    # Windows PowerShell 5.1 must retain the handle before the process exits.
    $null = $child.Handle
    if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
        & taskkill.exe /PID $child.Id /T /F | Out-Null
        throw "Godot timed out: $LogBase"
    }
    $child.WaitForExit()
    $stdout = Get-Content -LiteralPath ($LogBase + '.stdout.txt') -Raw -Encoding UTF8
    $stderr = Get-Content -LiteralPath ($LogBase + '.stderr.txt') -Raw -Encoding UTF8
    $combined = [string]$stdout + "`n" + [string]$stderr
    Write-Host $combined
    if ($child.ExitCode -ne 0 -or $combined -match '(?m)^(SCRIPT ERROR:|ERROR:)') {
        throw "Godot check failed (exit $($child.ExitCode)): $LogBase"
    }
    return $combined
}
