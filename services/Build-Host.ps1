[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory, [switch]$Offline)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Use a new output directory.' }
New-Item -ItemType Directory -Path $output | Out-Null
$env:DOTNET_CLI_HOME = Join-Path $output 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
Push-Location $PSScriptRoot
try {
    if ((& dotnet --version) -ne '8.0.424') { throw 'SDK 8.0.424 required.' }
    $restore = @('restore','RegionHost/RegionHost.csproj','--nologo','--locked-mode')
    if ($Offline) { $restore += @('--source', $output, '--ignore-failed-sources') }
    & dotnet @restore
    if ($LASTEXITCODE) { throw 'Host restore failed.' }
    & dotnet publish RegionHost/RegionHost.csproj -c Release --no-restore --self-contained false --nologo -o (Join-Path $output 'runtime')
    if ($LASTEXITCODE) { throw 'Host publish failed.' }
} finally { Pop-Location }
$entries=@(Get-ChildItem -LiteralPath (Join-Path $output 'runtime') -Recurse -File | ForEach-Object {@{path=[IO.Path]::GetRelativePath((Join-Path $output 'runtime'),$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
@{ok=$true;application_version='0.5.1';sdk='8.0.424';offline=[bool]$Offline;files=$entries}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $output 'build-report.json') -Encoding utf8NoBOM
