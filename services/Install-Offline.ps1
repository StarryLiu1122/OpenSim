[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$package=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest=Get-Content -LiteralPath (Join-Path $package 'package-manifest.json') -Raw | ConvertFrom-Json
foreach($entry in $manifest.files) {
    $path=[IO.Path]::GetFullPath((Join-Path $package $entry.path))
    if (!$path.StartsWith($package+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package path.' }
    if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $entry.sha256) { throw "Package checksum mismatch: $($entry.path)" }
}
if (!((& dotnet --list-runtimes | Out-String) -match 'Microsoft.NETCore.App 8\.')) { throw '.NET 8 runtime is required for this SQLite package.' }
if ($manifest.network -and !((& dotnet --list-runtimes | Out-String) -match 'Microsoft.AspNetCore.App 8\.')) { throw 'ASP.NET Core 8 runtime is required for the network package.' }
& (Join-Path $package 'prototype/tools/Install-Godot.ps1') -ArchivePath (Join-Path $package 'archives/Godot_v4.5.1-stable_win64.exe.zip')
if ($LASTEXITCODE) { throw 'Offline Godot installation failed.' }
Write-Output "Verified $($manifest.files.Count) packaged files. Offline installation complete."
