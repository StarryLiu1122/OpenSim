[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$StoreExecutable,
    [Parameter(Mandatory)][string]$FixtureSnapshot,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$Godot = ''
)
$ErrorActionPreference='Stop'
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidence) { throw 'Use a new evidence directory.' }
New-Item -ItemType Directory -Path $evidence | Out-Null
$fixture=Get-Content -LiteralPath $FixtureSnapshot -Raw | ConvertFrom-Json
$world=$fixture.world_json | ConvertFrom-Json
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script=Join-Path $repo 'prototype/tools/Start-RegionLab.ps1'
$image=Join-Path $evidence 'restored-desktop.png'
# Exercise the public launcher in a separate PowerShell process, including paths with spaces.
$launchArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Database',$Database,'-StoreExecutable',$StoreExecutable,'-Screenshot',$image)
if ($Godot) { $launchArgs += @('-Godot',$Godot) }
& powershell.exe @launchArgs > (Join-Path $evidence 'stdout.txt') 2> (Join-Path $evidence 'stderr.txt')
if ($LASTEXITCODE) { throw 'Database desktop startup failed.' }
$actual=Get-Content -LiteralPath ($image+'.json') -Raw | ConvertFrom-Json
$checks=@(
    @{name='public launcher renders a database-backed world';passed=($actual.ok -and (Test-Path -LiteralPath $image))},
    @{name='database path survives PowerShell argument boundaries';passed=([IO.Path]::GetFullPath($actual.repository_path) -eq (Join-Path ([IO.Path]::GetFullPath($Database)) 'worlds.sqlite3'))},
    @{name='restored world is marked saved';passed=(!$actual.dirty)},
    @{name='restored objects and groups match the fixture';passed=($actual.objects -eq $world.objects.Count -and $actual.groups -eq $world.groups.Count)},
    @{name='restored world revision matches the fixture';passed=($actual.world_revision -eq $world.revision)},
    @{name='restored mesh IDs match the fixture';passed=((@($actual.mesh_asset_ids | Sort-Object) -join ',') -eq (@($world.assets | Where-Object kind -eq 'mesh' | ForEach-Object id | Sort-Object) -join ','))}
)
$passed=@($checks | Where-Object { !$_.passed }).Count -eq 0
@{test='database-desktop-public-launcher';passed=$passed;checks=$checks} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'report.json') -Encoding utf8
if (!$passed) { throw 'Desktop storage acceptance failed; inspect report.json.' }
Write-Output ('Desktop database checks passed: '+$checks.Count)
