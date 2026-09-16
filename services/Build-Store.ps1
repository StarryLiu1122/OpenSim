[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory, [string]$PackageCache = '', [switch]$Offline)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Use a new output directory.' }
New-Item -ItemType Directory -Path $output | Out-Null
$env:DOTNET_CLI_HOME = Join-Path $output 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
if (!$PackageCache) { $PackageCache = Join-Path $output 'packages' }
$env:NUGET_PACKAGES = [IO.Path]::GetFullPath($PackageCache)
Push-Location $PSScriptRoot
try {
    if ((& dotnet --version) -ne '8.0.424') { throw 'SDK 8.0.424 is required by services/global.json.' }
    $restore = @('restore','RegionStore/RegionStore.csproj','--locked-mode','--nologo')
    if ($Offline) { $restore += @('--source',$env:NUGET_PACKAGES,'--ignore-failed-sources') }
    & dotnet @restore
    if ($LASTEXITCODE) { throw 'Locked dependency restore failed.' }
    $runtime = Join-Path $output 'runtime'
    & dotnet publish RegionStore/RegionStore.csproj -c Release --no-restore --self-contained false --nologo -o $runtime
    if ($LASTEXITCODE) { throw 'Storage publish failed.' }
    $entries = @(Get-ChildItem -LiteralPath $runtime -Recurse -File | Sort-Object FullName | ForEach-Object {
        @{path=[IO.Path]::GetRelativePath($runtime,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    })
    @{ok=$true;application_version='0.4.2';sdk='8.0.424';offline=[bool]$Offline;lock_sha256=(Get-FileHash RegionStore/packages.lock.json).Hash.ToLowerInvariant();files=$entries} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output 'build-report.json') -Encoding utf8
} finally { Pop-Location }
Write-Output "Storage runtime ready: $runtime"
