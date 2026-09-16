[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][string]$Directory,
    [string]$PackageCache='',
    [switch]$Offline,
    [string]$Python='python',
    [string]$Node='node',
    [int]$Port=19750
)
$ErrorActionPreference='Stop'
$Directory=[IO.Path]::GetFullPath($Directory)
if(Test-Path -LiteralPath $Directory){throw 'A new isolated acceptance directory is required.'}
New-Item -ItemType Directory -Path $Directory|Out-Null
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Godot=[IO.Path]::GetFullPath($Godot)
Push-Location $repo
try {
    & ./services/Build-Store.ps1 -OutputDirectory "$Directory/store" -PackageCache $PackageCache -Offline:$Offline
    & ./services/Build-Host.ps1 -OutputDirectory "$Directory/host" -Offline:$Offline
    $store="$Directory/store/runtime/RegionStore.exe";$gateway="$Directory/host/runtime/RegionHost.exe"
    & $Python -X utf8 ./services/Test-Store.py --store $store --godot $Godot --project ./prototype/godot --output "$Directory/store-tests"
    if($LASTEXITCODE){throw 'Storage checks failed.'}
    & ./prototype/tools/Test-RegionLab.ps1 -Godot $Godot -Visual
    & $Godot --headless --path ./prototype/godot --log-file "$Directory/network-data.log" --script res://tests/network_data_test.gd -- "--output=$Directory/network-data.json"
    if($LASTEXITCODE){throw 'Network data checks failed.'}
    & ./prototype/tools/Initialize-Network.ps1 -Directory "$Directory/native-instance" -Godot $Godot -Store $store -HostExecutable $gateway -Port $Port -WithBuilding
    & $Node ./services/Test-Network.cjs "--config=$Directory/native-instance/private-config.json" "--output=$Directory/native-network" "--python=$Python" --visual=true
    if($LASTEXITCODE){throw 'Native network checks failed.'}
    & ./prototype/tools/Export-NetworkWeb.ps1 -Godot $Godot -Template $Template -Destination "$Directory/export"
    & ./prototype/tools/Initialize-Network.ps1 -Directory "$Directory/web-instance" -Godot $Godot -Store $store -HostExecutable $gateway -WebDirectory "$Directory/export/web" -Port ($Port+10) -WithBuilding
    & $Node ./integration/web/test-network.cjs "--config=$Directory/web-instance/private-config.json" "--output=$Directory/web-tests" --runs=5 "--fixture=$repo/prototype/fixtures/meshes/bench.glb"
    if($LASTEXITCODE){throw 'Browser functionality or cold-load budget failed. Inspect web-tests/report.json.'}
} finally {Pop-Location}
Write-Output "V5 acceptance passed: $Directory"
