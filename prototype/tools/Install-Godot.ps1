[CmdletBinding()]
param([string]$ArchivePath = '')
$ErrorActionPreference = 'Stop'
$prototypeRoot = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $prototypeRoot 'engine.lock.json') -Raw | ConvertFrom-Json
$toolsRoot = Join-Path $prototypeRoot '.tools'
$destination = Join-Path $toolsRoot ('godot-' + $lock.version)
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null

function Test-EngineFiles([string]$Directory) {
    foreach ($entry in $lock.executables.PSObject.Properties) {
        $file = Join-Path $Directory $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA512).Hash -ne $entry.Value) { return $false }
    }
    return $true
}

if (Test-EngineFiles $destination) {
    Write-Output "Verified existing Godot installation: $destination"
    exit 0
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $toolsRoot $lock.archive
    if (-not (Test-Path -LiteralPath $ArchivePath) -or (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA512).Hash -ne $lock.sha512) {
        Write-Output "Downloading official Godot $($lock.version) (about 77 MB)..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $lock.url -OutFile $ArchivePath -TimeoutSec 240
    }
} else {
    $ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
}
if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA512).Hash -ne $lock.sha512) {
    throw 'Archive SHA512 mismatch. Installation stopped before extraction.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $allowed = @($lock.executables.PSObject.Properties.Name)
    $names = @($archive.Entries | ForEach-Object { $_.FullName })
    if ($names.Count -ne $allowed.Count -or @($names | Select-Object -Unique).Count -ne $names.Count) { throw 'Unexpected archive layout.' }
    foreach ($name in $names) { if ($name -cnotin $allowed) { throw "Unexpected archive entry: $name" } }
} finally { $archive.Dispose() }

$staging = Join-Path $toolsRoot ('staging-' + [guid]::NewGuid().ToString())
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging
if (-not (Test-EngineFiles $staging)) { throw 'Extracted executable verification failed.' }
# Preserve an existing incomplete installation rather than overwriting user files.
if (Test-Path -LiteralPath $destination) {
    $resolvedTools = [IO.Path]::GetFullPath($toolsRoot) + [IO.Path]::DirectorySeparatorChar
    $resolvedTarget = [IO.Path]::GetFullPath($destination)
    if (-not $resolvedTarget.StartsWith($resolvedTools, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination escaped tool directory.' }
    $preserved = $destination + '.previous-' + [guid]::NewGuid().ToString()
    if (-not [IO.Path]::GetFullPath($preserved).StartsWith($resolvedTools, [StringComparison]::OrdinalIgnoreCase)) { throw 'Preserved path escaped tool directory.' }
    Move-Item -LiteralPath $destination -Destination $preserved
}
$resolvedTools = [IO.Path]::GetFullPath($toolsRoot) + [IO.Path]::DirectorySeparatorChar
foreach ($movePath in @($staging, $destination)) {
    if (-not [IO.Path]::GetFullPath($movePath).StartsWith($resolvedTools, [StringComparison]::OrdinalIgnoreCase)) { throw 'Move path escaped tool directory.' }
}
Move-Item -LiteralPath $staging -Destination $destination
$engine = Join-Path $destination 'Godot_v4.5.1-stable_win64_console.exe'
$version = (& $engine --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne $lock.version_output) { throw "Unexpected engine version: $version" }
Write-Output "Installed and verified: $engine"
