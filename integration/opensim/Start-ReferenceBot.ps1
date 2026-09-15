[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceDirectory, [Parameter(Mandatory=$true)][string]$Report, [ValidateRange(0,600)][int]$HoldSeconds = 300)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceDirectory)
$env:DOTNET_CLI_HOME = Join-Path $source '.dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$project = Join-Path $PSScriptRoot 'ReferenceBot\ReferenceBot.csproj'
Push-Location $PSScriptRoot
try {
    & dotnet build $project -c Release --nologo -v:minimal "-p:OpenSimBin=$source\bin"
    if ($LASTEXITCODE -ne 0) { throw 'Reference Bot build failed.' }
} finally { Pop-Location }
& dotnet (Join-Path $PSScriptRoot 'ReferenceBot\bin\Release\net8.0\ReferenceBot.dll') (Join-Path $source 'reference-private.json') $Report $HoldSeconds
if ($LASTEXITCODE -ne 0) { throw 'Reference Bot check failed; inspect its report.' }
