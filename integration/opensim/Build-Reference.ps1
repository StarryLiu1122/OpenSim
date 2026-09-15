[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reference.lock.json') -Raw | ConvertFrom-Json
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ('integration\runtime\reference-' + [guid]::NewGuid().ToString('N')) }
$target = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $target) { throw 'Build destination must be a new directory.' }
$tree = (& git -C $repo rev-parse ($lock.import_commit + '^{tree}')).Trim()
if ($LASTEXITCODE -ne 0 -or $tree -ne $lock.git_tree) { throw 'Fixed imported source tree does not match the lock.' }
New-Item -ItemType Directory -Path $target | Out-Null
$archive = Join-Path $target 'upstream.zip'
& git -C $repo archive --format=zip -o $archive $lock.import_commit
if ($LASTEXITCODE -ne 0) { throw 'Source export failed.' }
$source = Join-Path $target 'source'
Expand-Archive -LiteralPath $archive -DestinationPath $source
$env:DOTNET_CLI_HOME = Join-Path $target 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $target 'nuget'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
@{ sdk = @{ version = $lock.sdk_version; rollForward = 'disable' } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source 'global.json') -Encoding UTF8
Push-Location $source
try {
    Copy-Item -LiteralPath 'bin\System.Drawing.Common.dll.win' -Destination 'bin\System.Drawing.Common.dll'
    & dotnet bin\prebuild.dll /target vs2022 /targetframework net8_0 /excludedir '= obj | bin' /file prebuild.xml *> (Join-Path $target 'prebuild.log')
    if ($LASTEXITCODE -ne 0) { throw 'Prebuild failed; inspect prebuild.log.' }
    & dotnet build --configuration Release OpenSim.sln --nologo -v:minimal *> (Join-Path $target 'build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Build failed; inspect build.log.' }
    $sdk = (& dotnet --version).Trim()
    $assembly = Join-Path $source 'bin\OpenSim.dll'
    $report = [ordered]@{ ok = $true; upstream_commit = $lock.upstream_commit; imported_tree = $tree; sdk = $sdk; configuration = 'Release'; opensim_sha256 = (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash.ToLower(); source = $source }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'build-report.json') -Encoding UTF8
    $report | ConvertTo-Json
} finally { Pop-Location }
