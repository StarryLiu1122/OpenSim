[CmdletBinding()]
param(
    [string]$Godot = '',
    [string]$Store = '',
    [string]$HostExecutable = '',
    [string]$Directory = '',
    [string]$Manifest = '',
    [string]$Input = '',
    [string]$AsOf = '2026-09-25T08:10:00Z',
    [string]$ModelId = 'synthetic-water-demo',
    [string]$ModelVersion = '0.1.0',
    [int]$Port = 20860,
    [switch]$NoClient
)
$ErrorActionPreference = 'Stop'
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $prototypeRoot '..'))
if (!$Directory) { $Directory = Join-Path $prototypeRoot 'runtime/world-model-helsinki-250m' }
if (!$Manifest) { $Manifest = Join-Path $prototypeRoot 'fixtures/geodata/helsinki-kamppi-250m/manifest.json' }
if (!$Input) { $Input = Join-Path $prototypeRoot 'fixtures/world-model/helsinki-synthetic-water.json' }
$Directory = [IO.Path]::GetFullPath($Directory)
$Manifest = [IO.Path]::GetFullPath($Manifest)
$Input = [IO.Path]::GetFullPath($Input)
foreach ($source in @($Manifest, $Input)) {
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing demo input: $source" }
}
if ($Port -lt 1024 -or $Port -gt 65533) { throw 'Port must allow three adjacent nonprivileged ports.' }
$manifestHash = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant()
$inputHash = (Get-FileHash -LiteralPath $Input -Algorithm SHA256).Hash.ToLowerInvariant()
$sentinel = Join-Path $Directory 'world-model-demo.json'
if (Test-Path -LiteralPath $Directory) {
    if (!(Test-Path -LiteralPath $sentinel -PathType Leaf)) {
        throw "The target directory already exists but is not this demo: $Directory. Choose a fresh -Directory."
    }
    $saved = Get-Content -LiteralPath $sentinel -Raw | ConvertFrom-Json
    $savedAsOf = ([DateTimeOffset]$saved.as_of).ToUnixTimeMilliseconds()
    $requestedAsOf = ([DateTimeOffset]$AsOf).ToUnixTimeMilliseconds()
    if ($saved.format -ne 'region-lab.world-model-demo' -or $saved.manifest_sha256 -ne $manifestHash -or
        $saved.input_sha256 -ne $inputHash -or $saved.model_id -ne $ModelId -or
        $saved.model_version -ne $ModelVersion -or $savedAsOf -ne $requestedAsOf -or [int]$saved.port -ne $Port) {
        throw 'This demo directory belongs to different inputs or settings. Choose a fresh -Directory.'
    }
} else {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $identity = @{format='region-lab.world-model-demo'; version=1; manifest_sha256=$manifestHash;
        input_sha256=$inputHash; model_id=$ModelId; model_version=$ModelVersion; as_of=$AsOf; port=$Port}
    [IO.File]::WriteAllText($sentinel, ($identity | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}
$world = Join-Path $Directory 'world.json'
$instance = Join-Path $Directory 'network'
$configPath = Join-Path $instance 'private-config.json'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $Godot = $config.godot
    $Store = $config.store
    $HostExecutable = $config.host_executable
    if ([int]$config.port -ne $Port) { throw 'Existing instance port disagrees with this demo directory.' }
}
if (!$Godot) {
    $Godot = Join-Path $prototypeRoot '.tools/godot-4.5.1/Godot_v4.5.1-stable_win64_console.exe'
    & (Join-Path $PSScriptRoot 'Install-Godot.ps1')
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $Godot -PathType Leaf)) {
        throw 'Could not install the pinned Godot version. See Install-Godot.ps1 output.'
    }
}
if (!$Store) { $Store = Join-Path $repositoryRoot 'services/RegionStore/bin/Release/net8.0/RegionStore.exe' }
if (!$HostExecutable) {
    $hostBuildDir = Join-Path $Directory 'binaries/RegionHost'
    $HostExecutable = Join-Path $hostBuildDir 'RegionHost.exe'
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
    & $dotnet publish (Join-Path $repositoryRoot 'services/RegionHost/RegionHost.csproj') -c Release --no-restore "-p:OutputPath=$hostBuildDir" -o $hostBuildDir
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $HostExecutable -PathType Leaf)) {
        throw 'Could not publish RegionHost into this demo instance. Build the services per README and retry.'
    }
}
foreach ($executable in @($Godot, $Store, $HostExecutable)) {
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Missing runtime executable: $executable. Build the services and install Godot first." }
}
$python = (Get-Command python -ErrorAction Stop).Source
$node = (Get-Command node -ErrorAction Stop).Source

if (!(Test-Path -LiteralPath $world -PathType Leaf)) {
    & $Godot --headless --path (Join-Path $prototypeRoot 'godot') --log-file (Join-Path $Directory 'build.log') --script res://tools/build_city_pilot.gd -- ('--manifest=' + $Manifest) ('--world-file=' + $world) ('--report=' + (Join-Path $Directory 'build-report.json'))
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $world -PathType Leaf)) { throw 'Could not build the Helsinki seed world. See build.log.' }
}
if (!(Test-Path -LiteralPath $configPath -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'Initialize-Network.ps1') -Directory $instance -Godot $Godot -Store $Store -HostExecutable $HostExecutable -SeedWorld $world -Port $Port
    if (!(Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Could not initialize the isolated network instance.' }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $agentBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($agentBytes) } finally { $rng.Dispose() }
    $agentToken = [BitConverter]::ToString($agentBytes).Replace('-', '').ToLowerInvariant()
    $config.principals += [pscustomobject]@{id=[guid]::NewGuid().ToString(); name='world-model-agent';
        actor=[guid]::NewGuid().ToString(); role='agent'; token=$agentToken;
        expires_at_ms=[DateTimeOffset]::UtcNow.AddDays(7).ToUnixTimeMilliseconds()}
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$agent = @($config.principals | Where-Object { $_.role -eq 'agent' -and $_.name -eq 'world-model-agent' })
if ($agent.Count -ne 1 -or !$agent[0].token -or !$config.principals[0].token) {
    throw 'The private instance configuration lacks the owner or demo agent. Inspect it before restarting.'
}
$owner = $config.principals[0]
$minimumExpiryMs = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeMilliseconds()
if ([long]$owner.expires_at_ms -le $minimumExpiryMs -or [long]$agent[0].expires_at_ms -le $minimumExpiryMs) {
    throw 'This demo instance has owner or agent credentials that expire within five minutes or have expired. Use a fresh -Directory to create a new isolated instance; the existing world is preserved.'
}

$normalized = Join-Path $Directory 'normalized-observation.json'
if (Test-Path -LiteralPath $normalized -PathType Leaf) {
    $mapped = Get-Content -LiteralPath $normalized -Raw | ConvertFrom-Json
    if ($mapped.manifest_sha256 -ne $manifestHash -or $mapped.input_sha256 -ne $inputHash -or
        $mapped.model_id -ne $ModelId -or $mapped.model_version -ne $ModelVersion) {
        throw 'Existing normalized observation does not match these inputs. Choose a fresh -Directory.'
    }
} else {
    & $python (Join-Path $PSScriptRoot 'Map-WorldModelObservation.py') $Manifest $Input $normalized "--as-of=$AsOf" "--model-id=$ModelId" "--model-version=$ModelVersion"
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $normalized -PathType Leaf)) { throw 'World-model observation mapping failed.' }
}

$processFile = Join-Path $instance 'processes.json'
$running = $false
if (Test-Path -LiteralPath $processFile -PathType Leaf) {
    $record = Get-Content -LiteralPath $processFile -Raw | ConvertFrom-Json
    $serverProcess = Get-Process -Id $record.server_pid -ErrorAction SilentlyContinue
    $gatewayProcess = Get-Process -Id $record.gateway_pid -ErrorAction SilentlyContinue
    if ($serverProcess -and $gatewayProcess) {
        try {
            $running = [IO.Path]::GetFullPath($serverProcess.Path) -eq [IO.Path]::GetFullPath($Godot) -and
                [IO.Path]::GetFullPath($gatewayProcess.Path) -eq [IO.Path]::GetFullPath($HostExecutable) -and
                $serverProcess.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$record.server_started).UtcTicks -and
                $gatewayProcess.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$record.gateway_started).UtcTicks
        } catch { $running = $false }
    }
    if (!$running -and ($serverProcess -or $gatewayProcess)) {
        throw 'Recorded service process identity is incomplete or mismatched. Inspect this instance before starting another writer.'
    }
}
if ($running) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($config.http_port)/health" -TimeoutSec 3
        if (!$health.ok -or $health.role -ne 'region-gateway') { throw 'Gateway health response is invalid.' }
    } catch { throw 'Recorded processes exist but the gateway is unhealthy. Inspect this instance before retrying.' }
} else {
    & (Join-Path $PSScriptRoot 'Start-Network.ps1') -Directory $instance
}

$previousOwner = [Environment]::GetEnvironmentVariable('REGION_LAB_TOKEN', 'Process')
$previousAgent = [Environment]::GetEnvironmentVariable('REGION_LAB_AGENT_TOKEN', 'Process')
try {
    [Environment]::SetEnvironmentVariable('REGION_LAB_TOKEN', [string]$config.principals[0].token, 'Process')
    [Environment]::SetEnvironmentVariable('REGION_LAB_AGENT_TOKEN', [string]$agent[0].token, 'Process')
    & $node (Join-Path $repositoryRoot 'services/WorldModelExperiment.cjs') "--observation=$normalized" "--manifest=$Manifest" "--input=$Input" "--url=ws://127.0.0.1:$($config.http_port)/ws" "--output=$(Join-Path $Directory 'experiment')"
    if ($LASTEXITCODE -ne 0) { throw 'World-model experiment failed. Inspect experiment/experiment.json and events.jsonl.' }
} finally {
    [Environment]::SetEnvironmentVariable('REGION_LAB_TOKEN', $previousOwner, 'Process')
    [Environment]::SetEnvironmentVariable('REGION_LAB_AGENT_TOKEN', $previousAgent, 'Process')
}

if (!$NoClient) {
    $clientRecordPath = Join-Path $Directory 'demo-client.json'
    $clientRunning = $false
    if (Test-Path -LiteralPath $clientRecordPath -PathType Leaf) {
        $clientRecord = Get-Content -LiteralPath $clientRecordPath -Raw | ConvertFrom-Json
        $clientProcess = Get-Process -Id $clientRecord.pid -ErrorAction SilentlyContinue
        if ($clientProcess) {
            try {
                $clientRunning = [IO.Path]::GetFullPath($clientProcess.Path) -eq [IO.Path]::GetFullPath($clientRecord.executable) -and
                    $clientProcess.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$clientRecord.started).UtcTicks
            } catch { $clientRunning = $false }
        }
    }
    if (!$clientRunning) {
        $messages = @( & (Join-Path $PSScriptRoot 'Start-NetworkClient.ps1') -Directory $instance -Profile editor-a )
        $line = $messages | Where-Object { $_ -match 'Client editor-a launched as process ([0-9]+)' } | Select-Object -First 1
        if (!$line) { throw 'The desktop client did not report its process ID.' }
        $clientPid = [int]([regex]::Match($line, 'process ([0-9]+)').Groups[1].Value)
        $clientProcess = Get-Process -Id $clientPid -ErrorAction Stop
        $clientRecord = @{pid=$clientPid; executable=$clientProcess.Path; started=$clientProcess.StartTime.ToUniversalTime().ToString('O')}
        [IO.File]::WriteAllText($clientRecordPath, ($clientRecord | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-Output $line
    } else { Write-Output "Desktop client already open: PID $($clientRecord.pid)" }
}
Write-Output "World-model experiment ready: $Directory"
Write-Output 'Data label: historical synthetic water prediction; markers are visual observations, not a flood simulation.'
