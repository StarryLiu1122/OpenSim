[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceDirectory)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $source 'reference-private.json'))) { throw 'An initialized isolated reference directory is required.' }
$env:DOTNET_CLI_HOME = Join-Path $source '.dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
Push-Location (Join-Path $source 'bin')
try {
    & dotnet OpenSim.dll -console=basic
    if ($LASTEXITCODE -ne 0) { throw 'Reference server exited with an error.' }
} finally { Pop-Location }
