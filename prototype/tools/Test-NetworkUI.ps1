[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$Store,
    [Parameter(Mandatory)][string]$HostExecutable,
    [Parameter(Mandatory)][string]$Directory,
    [int]$Port = 19920
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$Directory = [IO.Path]::GetFullPath($Directory)
if (Test-Path -LiteralPath $Directory) { throw 'Use a new isolated UI acceptance directory.' }
New-Item -ItemType Directory -Path $Directory | Out-Null
$engine = Get-RegionLabEngine $Godot
$instance = Join-Path $Directory 'instance'
$output = Join-Path $Directory 'screenshots'
& (Join-Path $PSScriptRoot 'Initialize-Network.ps1') -Directory $instance -Godot $engine -Store $Store -HostExecutable $HostExecutable -Port $Port -WithBuilding
try {
    & (Join-Path $PSScriptRoot 'Start-Network.ps1') -Directory $instance
    $arguments = @('--path', (Join-Path $prototypeRoot 'godot'), '--max-fps', '60', '--log-file', (Join-Path $Directory 'ui.log'), '--script', 'res://tests/network_ui_test.gd', '--', ('--network-config=' + (Join-Path $instance 'private-config.json')), ('--output-dir=' + $output))
    $null = Invoke-RegionLabCheck $engine $arguments (Join-Path $Directory 'ui') 90
    $report = Get-Content -LiteralPath (Join-Path $output 'report.json') -Raw | ConvertFrom-Json
    if ($report.failed -ne 0) { throw 'Network UI checks failed.' }
    Write-Output "Network UI: $($report.passed) passed. Evidence: $output"
} finally {
    if (Test-Path -LiteralPath (Join-Path $instance 'processes.json')) {
        & (Join-Path $PSScriptRoot 'Stop-Network.ps1') -Directory $instance
    }
}
