[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceDirectory, [ValidateRange(1024,65532)][int]$Port = 19100, [switch]$EnableFusion)
$ErrorActionPreference = 'Stop'
$bin = Join-Path ([IO.Path]::GetFullPath($SourceDirectory)) 'bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'OpenSim.dll'))) { throw 'Build the fixed reference first.' }
if (Test-Path -LiteralPath (Join-Path $bin 'OpenSim.ini')) { throw 'Refusing to overwrite an existing reference configuration.' }
$regionId = [guid]::NewGuid().ToString()
$ownerId = [guid]::NewGuid().ToString()
$password = [guid]::NewGuid().ToString('N')
$token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$privatePort = $Port + 3
Copy-Item -LiteralPath (Join-Path $bin 'config-include\StandaloneCommon.ini.example') -Destination (Join-Path $bin 'config-include\StandaloneCommon.ini')
Copy-Item -LiteralPath (Join-Path $bin 'config-include\FlotsamCache.ini.example') -Destination (Join-Path $bin 'config-include\FlotsamCache.ini')
New-Item -ItemType Directory -Path (Join-Path $bin 'Regions') -Force | Out-Null
@"
[Const]
BaseHostname = 127.0.0.1
BaseURL = http://127.0.0.1
PublicPort = $Port
PrivatePort = $privatePort
PrivURL = http://127.0.0.1
[Startup]
ConsoleHistoryFileEnabled = false
physics = BulletSim
DefaultScriptEngine = YEngine
[Network]
http_listener_port = $Port
[Architecture]
Include-Architecture = config-include/Standalone.ini
[Estates]
DefaultEstateName = V4 Reference Estate
DefaultEstateOwnerName = V4 Owner
DefaultEstateOwnerUUID = $ownerId
DefaultEstateOwnerEMail = v4@example.invalid
DefaultEstateOwnerPassword = $password
[Fusion]
Enabled = $($EnableFusion.IsPresent.ToString().ToLower())
Token = $token
Owner = $ownerId
DataDirectory = fusion-data
"@ | Set-Content -LiteralPath (Join-Path $bin 'OpenSim.ini') -Encoding UTF8
@"
[V4 Reference]
RegionUUID = $regionId
Location = 1000,1000
InternalAddress = 127.0.0.1
InternalPort = $Port
AllowAlternatePorts = False
ExternalHostName = 127.0.0.1
SizeX = 256
SizeY = 256
"@ | Set-Content -LiteralPath (Join-Path $bin 'Regions\V4.ini') -Encoding UTF8
'terrain fill 0' | Set-Content -LiteralPath (Join-Path $bin 'startup_commands.txt') -Encoding ASCII
$config = [ordered]@{ url = "http://127.0.0.1:$Port"; region_id = $regionId; owner_id = $ownerId; first_name = 'V4'; last_name = 'Owner'; password = $password; token = $token }
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $SourceDirectory 'reference-private.json') -Encoding UTF8
[ordered]@{ bin = $bin; url = $config.url; region_id = $regionId; private_config = (Join-Path $SourceDirectory 'reference-private.json') } | ConvertTo-Json
