[CmdletBinding()]
param([Parameter(Mandatory)][string]$ClientRepository, [Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'client.lock.json') -Raw | ConvertFrom-Json
$destination = [IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $destination){throw 'Use a new client build directory.'}
$commit = (& git -C $ClientRepository rev-parse $lock.commit).Trim()
if($LASTEXITCODE -or $commit -ne $lock.commit){throw 'Pinned client source unavailable.'}
New-Item -ItemType Directory -Path $destination | Out-Null
& git -C $ClientRepository archive --format=zip -o (Join-Path $destination 'source.zip') $lock.commit
if($LASTEXITCODE){throw 'Client source export failed.'}
$source = Join-Path $destination 'source'
Expand-Archive -LiteralPath (Join-Path $destination 'source.zip') -DestinationPath $source
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'global.json') -Destination $source
$env:DOTNET_CLI_HOME=Join-Path $destination '.dotnet-home'
$env:NUGET_PACKAGES=Join-Path $destination '.nuget'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
Push-Location $source
try {
    # An enclosing workspace may itself be a Git checkout. Establish the exact
    # patch root so git apply cannot silently skip paths below another repository.
    & git init --quiet
    if($LASTEXITCODE){throw 'Cannot establish isolated client patch root.'}
    & git apply --check (Join-Path $PSScriptRoot $lock.patch)
    if($LASTEXITCODE){throw 'Client patch does not match locked source.'}
    & git apply (Join-Path $PSScriptRoot $lock.patch)
    if($LASTEXITCODE){throw 'Client patch failed.'}
    $pipeline = [IO.File]::ReadAllText((Join-Path $source 'OpenMetaverse/TexturePipeline.cs'))
    if($pipeline.Contains('downloadMaster.Abort()') -or !$pipeline.Contains('shutdown.WaitOne(500)')){throw 'Client patch postcondition failed.'}
    Copy-Item -LiteralPath 'bin/System.Drawing.Common.dll.win' -Destination 'bin/System.Drawing.Common.dll'
    & dotnet bin/prebuild.dll /target vs2022 /targetframework net8_0 /file prebuildCoreLib.xml *> (Join-Path $destination 'prebuild.log')
    if($LASTEXITCODE){throw 'Client project generation failed.'}
    & dotnet build OpenMetaverse/OpenMetaverse.csproj -c Release --nologo -v:minimal *> (Join-Path $destination 'build.log')
    if($LASTEXITCODE){throw 'Client build failed. Inspect build.log.'}
    $dlls = Get-ChildItem -LiteralPath 'bin' -Filter '*.dll' | ForEach-Object { @{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} }
    @{passed=$true;commit=$lock.commit;sdk=(& dotnet --version);patch_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $lock.patch)).Hash.ToLowerInvariant();assemblies=@($dlls)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'build-report.json') -Encoding utf8
} finally {Pop-Location}
Write-Output "Patched client built: $source/bin"
