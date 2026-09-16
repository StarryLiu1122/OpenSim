[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$GodotArchive,[Parameter(Mandatory)][string]$StoreBuildDirectory)
$ErrorActionPreference='Stop'
$destinationPath=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw 'Use a new package directory.' }
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build=[IO.Path]::GetFullPath($StoreBuildDirectory)
$report=Get-Content -LiteralPath (Join-Path $build 'build-report.json') -Raw | ConvertFrom-Json
if (!$report.ok -or $report.application_version -ne '0.4.2') { throw 'Verified V4 storage build required.' }
foreach($entry in $report.files) {
    if ((Get-FileHash -LiteralPath (Join-Path $build ('runtime/'+$entry.path))).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Storage runtime hash mismatch.' }
}
$lock=Get-Content -LiteralPath (Join-Path $repo 'prototype/engine.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $GodotArchive -Algorithm SHA512).Hash.ToLowerInvariant() -ne $lock.sha512) { throw 'Godot archive mismatch.' }
New-Item -ItemType Directory -Path $destinationPath | Out-Null
# Explicit roots: no worlds, hidden tools, imported caches, test-results or credentials.
foreach($relative in @('prototype/godot','prototype/fixtures','prototype/tools','prototype/docs','services','docs','integration')) {
    $from=Join-Path $repo $relative
    foreach($file in Get-ChildItem -LiteralPath $from -Recurse -File) {
        $inside=[IO.Path]::GetRelativePath($from,$file.FullName)
        if ($inside -match '(^|[\\/])(\.godot|__pycache__|bin|obj|runtime)([\\/]|$)') { continue }
        $target=Join-Path $destinationPath ($relative+'/'+$inside)
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
foreach($relative in @('README.md','LICENSE.txt','prototype/Start.cmd','prototype/Install.cmd','prototype/README.md','prototype/engine.lock.json','services/README.md','services/THIRD-PARTY-NOTICES.md','services/Invoke-Store.ps1','services/Install-Offline.ps1','services/RegionStore/packages.lock.json')) {
    $target=Join-Path $destinationPath $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination $target
}
$runtime=Join-Path $destinationPath 'services/RegionStore/bin/Release/net8.0'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Copy-Item -Path (Join-Path $build 'runtime/*') -Destination $runtime -Recurse
New-Item -ItemType Directory -Path (Join-Path $destinationPath 'archives') | Out-Null
Copy-Item -LiteralPath $GodotArchive -Destination (Join-Path $destinationPath ('archives/'+$lock.archive))
$files=@(Get-ChildItem -LiteralPath $destinationPath -Recurse -File | Sort-Object FullName | ForEach-Object {
    @{path=[IO.Path]::GetRelativePath($destinationPath,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
})
@{version='0.4.2';platform='Windows x64';requires='.NET 8 runtime preinstalled for SQLite; JSON mode only needs bundled Godot';files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destinationPath 'package-manifest.json') -Encoding utf8
Write-Output "Offline package prepared: $destinationPath"
