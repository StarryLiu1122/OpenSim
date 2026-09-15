[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceDirectory)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceDirectory)
$bin = Join-Path $source 'bin'
if (-not (Test-Path -LiteralPath (Join-Path $source 'reference-private.json'))) { throw 'Initialize a dedicated reference instance first.' }
$env:DOTNET_CLI_HOME = Join-Path $source '.dotnet-home'
$env:NUGET_PACKAGES = Join-Path $source '.nuget'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$project = Join-Path $PSScriptRoot 'FusionRegionModule\FusionRegionModule.csproj'
Push-Location $PSScriptRoot
try {
    & dotnet build $project --configuration Release --nologo -v:minimal "-p:OpenSimBin=$bin"
    if ($LASTEXITCODE -ne 0) { throw 'Fusion module build failed.' }
} finally { Pop-Location }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FusionRegionModule\bin\Release\net8.0\RegionLab.Fusion.dll') -Destination $bin
$ini = Join-Path $bin 'OpenSim.ini'
$text = Get-Content -LiteralPath $ini -Raw
if ($text -notmatch '(?m)^\[Fusion\]') { throw 'Missing isolated Fusion configuration.' }
$text = [regex]::Replace($text, '(?ms)^\[Fusion\][^\[]*', {
    param($section)
    [regex]::Replace($section.Value, '(?m)^Enabled = false[ \t]*\r?$', 'Enabled = true')
})
Set-Content -LiteralPath $ini -Value $text -Encoding UTF8
Write-Output 'Module installed. Start the isolated reference instance from its bin directory.'
