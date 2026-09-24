[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$Store,
    [Parameter(Mandatory)][string]$HostExecutable,
    [string]$WebDirectory = '',
    [int]$Port = 19550,
    [switch]$WithBuilding,
    [string]$SeedWorld = ''
)
$ErrorActionPreference = 'Stop'
$Directory = [IO.Path]::GetFullPath($Directory)
if (Test-Path -LiteralPath $Directory) { throw 'Use a new isolated instance directory.' }
if ($Port -lt 1024 -or $Port -gt 65533) { throw 'Port must allow three adjacent nonprivileged ports.' }
if ($WithBuilding -and $SeedWorld) { throw 'Choose either WithBuilding or SeedWorld.' }
if ($SeedWorld -and !(Test-Path -LiteralPath $SeedWorld -PathType Leaf)) { throw 'SeedWorld snapshot does not exist.' }
foreach ($file in @($Godot, $Store, $HostExecutable)) { if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing executable: $file" } }
New-Item -ItemType Directory -Path $Directory | Out-Null
$storage = Join-Path $Directory 'storage'
New-Item -ItemType Directory -Path $storage | Out-Null
if (!$WebDirectory) { $WebDirectory = Join-Path $Directory 'web'; New-Item -ItemType Directory -Path $WebDirectory | Out-Null }
& $HostExecutable --certificate $Directory
if ($LASTEXITCODE) { throw 'Local certificate creation failed.' }
$owner = '11111111-1111-4111-8111-111111111111'
$principals = @()
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
foreach ($name in @('editor-a','editor-b','observer','guest')) {
    $tokenBytes = New-Object byte[] 32
    $rng.GetBytes($tokenBytes)
    $token = [BitConverter]::ToString($tokenBytes).Replace('-','').ToLowerInvariant()
    $principals += @{id=[guid]::NewGuid().ToString();name=$name;actor=$(if($name -eq 'guest'){[guid]::NewGuid().ToString()}else{$owner});role=$(if($name -eq 'observer'){'observer'}else{'editor'});token=$token;expires_at_ms=[DateTimeOffset]::UtcNow.AddDays(7).ToUnixTimeMilliseconds()}
}
$rng.Dispose()
$config = @{storage=$storage;store=[IO.Path]::GetFullPath($Store);godot=[IO.Path]::GetFullPath($Godot);host_executable=[IO.Path]::GetFullPath($HostExecutable);project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../godot'));port=$Port;http_port=$Port+1;https_port=$Port+2;web_root=[IO.Path]::GetFullPath($WebDirectory);certificate=(Join-Path $Directory 'localhost.pfx');principals=$principals;private_objects=@{}}
if ($WithBuilding) { $config.seed_asset=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../fixtures/buildings/pioneer-log-cabin/pioneer-log-cabin.glb')) }
if ($SeedWorld) { $config.seed_world=[IO.Path]::GetFullPath($SeedWorld) }
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Directory 'private-config.json'), ($config | ConvertTo-Json -Depth 10), $utf8)
[IO.File]::WriteAllText((Join-Path $Directory 'instance.json'), (@{instance=$Directory;http="http://127.0.0.1:$($Port+1)/";https="https://localhost:$($Port+2)/";protocol='0.3';world_format=3;database_schema=7} | ConvertTo-Json), $utf8)
Write-Output "Instance initialized: $Directory. Credentials are in private-config.json; do not publish this file."
