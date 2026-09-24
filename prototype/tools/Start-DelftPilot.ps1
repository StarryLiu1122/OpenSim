[CmdletBinding()]
param(
    [string]$Godot = '',
    [string]$Store = '',
    [string]$HostExecutable = '',
    [string]$Directory = '',
    [string]$Manifest = '',
    [string]$Label = 'Delft',
    [int]$Port = 20810
)
$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$Directory) { $Directory = Join-Path $prototypeRoot 'runtime/delft-julianalaan' }
$Directory = [IO.Path]::GetFullPath($Directory)
if (!$Manifest) { $Manifest = Join-Path $prototypeRoot 'fixtures/geodata/delft-julianalaan/manifest.json' }
$Manifest = [IO.Path]::GetFullPath($Manifest)
if (!(Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Missing city manifest: $Manifest" }
$world = Join-Path $Directory 'world.json'
$instance = Join-Path $Directory 'network'
$configPath = Join-Path $instance 'private-config.json'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $savedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $Godot = $savedConfig.godot
    $Store = $savedConfig.store
    $HostExecutable = $savedConfig.host_executable
}
if (!$Godot) {
    $Godot = Join-Path $prototypeRoot '.tools/godot-4.5.1/Godot_v4.5.1-stable_win64_console.exe'
    if (!(Test-Path -LiteralPath $Godot)) {
        $Godot = Join-Path $prototypeRoot '../../opensim-github-publish/prototype/.tools/godot-4.5.1/Godot_v4.5.1-stable_win64_console.exe'
    }
}
if (!$Store) { $Store = Join-Path $prototypeRoot '../services/RegionStore/bin/Release/net8.0/RegionStore.exe' }
if (!$HostExecutable) { $HostExecutable = Join-Path $prototypeRoot '../services/RegionHost/bin/Release/net8.0/RegionHost.exe' }
foreach ($executable in @($Godot, $Store, $HostExecutable)) {
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Missing runtime executable: $executable. Install Godot or build the services first." }
}
if (!(Test-Path -LiteralPath $world -PathType Leaf)) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    & $Godot --headless --path (Join-Path $prototypeRoot 'godot') --log-file (Join-Path $Directory 'build.log') --script res://tools/build_city_pilot.gd -- ('--manifest=' + $Manifest) ('--world-file=' + $world) ('--report=' + (Join-Path $Directory 'build-report.json'))
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $world -PathType Leaf)) { throw "Could not build the $Label world." }
}
if (!(Test-Path -LiteralPath $configPath)) {
    & (Join-Path $PSScriptRoot 'Initialize-Network.ps1') -Directory $instance -Godot $Godot -Store $Store -HostExecutable $HostExecutable -SeedWorld $world -Port $Port
}
$processFile = Join-Path $instance 'processes.json'
$running = $false
if (Test-Path -LiteralPath $processFile) {
    $processes = Get-Content -LiteralPath $processFile -Raw | ConvertFrom-Json
    $server = Get-Process -Id $processes.server_pid -ErrorAction SilentlyContinue
    $gateway = Get-Process -Id $processes.gateway_pid -ErrorAction SilentlyContinue
    if ($server -and $gateway) {
        try {
            $running = [IO.Path]::GetFullPath($server.Path) -eq [IO.Path]::GetFullPath($Godot) -and
                [IO.Path]::GetFullPath($gateway.Path) -eq [IO.Path]::GetFullPath($HostExecutable) -and
                $server.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$processes.server_started).UtcTicks -and
                $gateway.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$processes.gateway_started).UtcTicks
        } catch { $running = $false }
    }
}
if (!$running) { & (Join-Path $PSScriptRoot 'Start-Network.ps1') -Directory $instance }
& (Join-Path $PSScriptRoot 'Start-NetworkClient.ps1') -Directory $instance -Profile editor-a
Write-Output "$Label pilot: $world"
