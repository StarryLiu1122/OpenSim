[CmdletBinding()]
param([string]$Godot = '', [switch]$Visual)
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$project = Join-Path $prototypeRoot 'godot'
$results = Join-Path $prototypeRoot ('test-results\run-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $results -Force | Out-Null
$base = @('--headless', '--path', $project)
$importLog = Invoke-RegionLabCheck $engine ($base + @('--editor', '--import', '--quit', '--log-file', (Join-Path $results 'import.log'))) (Join-Path $results 'import')
$nativeDir = Join-Path $results 'native'
$nativeLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tests/run_tests.gd', '--log-file', (Join-Path $results 'native.log'), '--', ('--output-dir=' + $nativeDir))) (Join-Path $results 'native')
$nativeReport = Get-Content -LiteralPath (Join-Path $nativeDir 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($nativeReport.failed -ne 0 -or $nativeReport.passed -lt 188) { throw 'Native tests did not complete.' }

$restartFile = Join-Path $results 'restart-world.json'
$writeLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tests/process_persistence.gd', '--log-file', (Join-Path $results 'write.log'), '--', '--write', ('--world-file=' + $restartFile))) (Join-Path $results 'write')
$readLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tests/process_persistence.gd', '--log-file', (Join-Path $results 'read.log'), '--', ('--world-file=' + $restartFile))) (Join-Path $results 'read')
foreach ($log in @($writeLog, $readLog)) {
    $resultLine = @($log -split "`r?`n" | Where-Object { $_ -match '^\{.*separate-process-persistence' })
    if ($resultLine.Count -ne 1 -or -not ($resultLine[0] | ConvertFrom-Json).ok) { throw 'Separate-process persistence evidence missing.' }
}

$assetFile = Join-Path $results 'asset-world.json'
$assetWrite = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tests/process_assets.gd', '--log-file', (Join-Path $results 'asset-write.log'), '--', '--write', ('--world-file=' + $assetFile))) (Join-Path $results 'asset-write')
$relocated = Join-Path $results 'relocated'
New-Item -ItemType Directory -Path $relocated -Force | Out-Null
$relocatedFile = Join-Path $relocated 'world.json'
Copy-Item -LiteralPath $assetFile -Destination $relocatedFile
Copy-Item -LiteralPath ($assetFile + '.assets') -Destination ($relocatedFile + '.assets') -Recurse
$assetRead = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tests/process_assets.gd', '--log-file', (Join-Path $results 'asset-read.log'), '--', ('--world-file=' + $relocatedFile))) (Join-Path $results 'asset-read')
foreach ($log in @($assetWrite, $assetRead)) {
    $line = @($log -split "`r?`n" | Where-Object { $_ -match '^\{.*separate-process-embedded-assets' })
    if ($line.Count -ne 1 -or -not ($line[0] | ConvertFrom-Json).ok) { throw 'Embedded asset process evidence missing.' }
}

$batchFile = Join-Path $results 'batch-world.json'
$batchReportPath = Join-Path $results 'batch-report.json'
$batchLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tools/world_cli.gd', '--log-file', (Join-Path $results 'batch.log'), '--', ('--world-file=' + $batchFile), ('--commands=' + (Join-Path $prototypeRoot 'fixtures\create-and-save.commands.json')), ('--output=' + $batchReportPath))) (Join-Path $results 'batch')
$batch = Get-Content -LiteralPath $batchReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $batch.ok -or $batch.results.Count -ne 3 -or $batch.results[2].payload.world.objects.Count -ne 9) { throw 'Batch adapter evidence is invalid.' }

$terrainBatchPath = Join-Path $results 'terrain-batch-report.json'
$terrainBatchLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tools/world_cli.gd', '--log-file', (Join-Path $results 'terrain-batch.log'), '--', ('--world-file=' + (Join-Path $results 'terrain-batch.json')), ('--commands=' + (Join-Path $prototypeRoot 'fixtures\sculpt-and-save.commands.json')), ('--output=' + $terrainBatchPath))) (Join-Path $results 'terrain-batch')
$terrainBatch = Get-Content -LiteralPath $terrainBatchPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $terrainBatch.ok -or $terrainBatch.results.Count -ne 5 -or $terrainBatch.results[4].payload.world.terrain.heights[1320] -ne 8) { throw 'Terrain batch adapter evidence is invalid.' }

$v3BatchPath = Join-Path $results 'v3-batch-report.json'
$v3BatchLog = Invoke-RegionLabCheck $engine ($base + @('--script', 'res://tools/world_cli.gd', '--log-file', (Join-Path $results 'v3-batch.log'), '--', ('--world-file=' + (Join-Path $results 'v3-batch.json')), ('--commands=' + (Join-Path $prototypeRoot 'fixtures\environment-and-door.commands.json')), ('--output=' + $v3BatchPath))) (Join-Path $results 'v3-batch')
$v3Batch = Get-Content -LiteralPath $v3BatchPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $v3Batch.ok -or $v3Batch.results.Count -ne 5) { throw 'V3 batch did not complete.' }
$v3World = $v3Batch.results[4].payload.world
$v3Door = @($v3World.objects | Where-Object { $_.id -eq '77777777-7777-4777-8777-777777777777' })
if ($v3World.environment.sun_hour -ne 20 -or $v3Door.Count -ne 1 -or -not $v3Door[0].state.active) { throw 'V3 environment and door batch state is invalid.' }

$visualCount = 0
if ($Visual) {
    $visualDir = Join-Path $results 'visual'
    New-Item -ItemType Directory -Path $visualDir -Force | Out-Null
    $visualLog = Invoke-RegionLabCheck $engine @('--path', $project, '--script', 'res://tests/verify_ui.gd', '--log-file', (Join-Path $visualDir 'engine.log'), '--', ('--world-file=' + (Join-Path $visualDir 'world.json')), ('--output-dir=' + $visualDir)) (Join-Path $results 'visual')
    $visualReport = Get-Content -LiteralPath (Join-Path $visualDir 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($visualReport.failed -ne 0 -or $visualReport.passed -lt 66) { throw 'UI verification did not complete.' }
    foreach ($name in @('overview.png', 'edited.png', 'terrain.png', 'night.png', 'interior.png', 'groups.png', 'imported-assets.png')) {
        if (-not (Test-Path -LiteralPath (Join-Path $visualDir $name))) { throw 'Rendered evidence missing.' }
    }
    $visualCount = $visualReport.passed
}
$summary = [ordered]@{
    ok = $true
    engine = (& $engine --version | Out-String).Trim()
    native_passed = $nativeReport.passed
    separate_process_persistence = $true
    separate_process_content_assets = $true
    offline_batch_adapter = $true
    terrain_batch_adapter = $true
    environment_behavior_batch_adapter = $true
    application_version = ((Get-Content -LiteralPath (Join-Path $project 'project.godot') | Select-String '^config/version="([^"]+)"$').Matches.Groups[1].Value)
    visual_passed = $visualCount
    visual_requested = [bool]$Visual
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'summary.json') -Encoding UTF8
Write-Output "All requested checks passed. Reports: $results"
