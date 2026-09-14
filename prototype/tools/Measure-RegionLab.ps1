[CmdletBinding()]
param([string]$Godot = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$project = Join-Path $prototypeRoot 'godot'
$results = Join-Path $prototypeRoot ('test-results\benchmark-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $results -Force | Out-Null
$log = Invoke-RegionLabCheck $engine @('--path', $project, '--script', 'res://tools/benchmark.gd', '--log-file', (Join-Path $results 'engine.log'), '--', ('--output-dir=' + $results)) (Join-Path $results 'run')
$report = Get-Content -LiteralPath (Join-Path $results 'benchmark.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($report.cases.Count -ne 2) { throw 'Benchmark did not complete both workloads.' }
foreach ($case in $report.cases) {
    if ($case.frame_intervals_ms.Count -lt 180 -or $case.sample_duration_ms -lt 3000 -or -not $case.screenshot_ok -or $case.frame_p95_ms -le 0) { throw 'Benchmark evidence is incomplete.' }
}
Write-Output "Benchmark reports: $results"
