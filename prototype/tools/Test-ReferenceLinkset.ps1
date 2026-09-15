[CmdletBinding()]
param([string]$Godot = '', [Parameter(Mandatory=$true)][string]$OutputDirectory)
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'A new output directory is required.' }
New-Item -ItemType Directory -Path $output | Out-Null
foreach ($phase in @('Create','RestartLinked','RestartUnlinked')) {
    $log = Join-Path $output $phase
    $null = Invoke-RegionLabCheck $engine @('--headless', '--path', (Join-Path $prototypeRoot 'godot'), '--script', 'res://tests/reference_linkset.gd', '--log-file', ($log + '.log'), '--', ('--output-dir=' + $output), ('--phase=' + $phase)) $log
    $report = Get-Content -LiteralPath ($log + '.json') -Raw | ConvertFrom-Json
    if (-not $report.ok) { throw "Reference linkset phase failed: $phase" }
}
Write-Output "Three independent engine phases passed: $output"
