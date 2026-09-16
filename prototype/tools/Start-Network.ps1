[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference = 'Stop'
$Directory = [IO.Path]::GetFullPath($Directory)
$path = Join-Path $Directory 'private-config.json'
$config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$ready = Join-Path $config.storage 'server-ready.json'
if (Test-Path -LiteralPath $ready) {
    $old = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    $running = Get-Process -Id $old.pid -ErrorAction SilentlyContinue
    if ($running) { throw 'Previous server process still exists; inspect it before starting another writer.' }
    Remove-Item -LiteralPath $ready
}
$importLog=Join-Path $Directory 'project-import.log'
& $config.godot --headless --path $config.project --log-file $importLog --editor --import --quit | Out-Null
if($LASTEXITCODE -or ([IO.File]::ReadAllText($importLog) -match 'SCRIPT ERROR|Parse Error')){throw "Project import failed. Read $importLog"}
$args = @('--headless','--path',('"'+$config.project+'"'),'--log-file',('"'+(Join-Path $Directory 'authority.log')+'"'),'res://network/server.tscn','--',('"--network-config='+$path+'"'))
$server = Start-Process -FilePath $config.godot -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Directory 'authority.stdout.log') -RedirectStandardError (Join-Path $Directory 'authority.stderr.log')
$deadline = [DateTime]::UtcNow.AddSeconds(45)
while (!(Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline -and !$server.HasExited) { Start-Sleep -Milliseconds 100; $server.Refresh() }
if (!(Test-Path -LiteralPath $ready)) { if (!$server.HasExited) { $server.Kill() }; throw "Authority failed. Read $Directory/authority.log" }
$gateway = Start-Process -FilePath $config.host_executable -ArgumentList ('"'+$path+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Directory 'gateway.stdout.log') -RedirectStandardError (Join-Path $Directory 'gateway.stderr.log')
$gatewayReady=$false;$deadline=[DateTime]::UtcNow.AddSeconds(15)
while([DateTime]::UtcNow -lt $deadline -and !$gateway.HasExited) {
    try {$health=Invoke-RestMethod -Uri "http://127.0.0.1:$($config.http_port)/health" -TimeoutSec 1; $gatewayReady=$health.ok -and $health.role -eq 'region-gateway';if($gatewayReady){break}}catch{}
    Start-Sleep -Milliseconds 100;$gateway.Refresh()
}
if(!$gatewayReady){if(!$gateway.HasExited){$gateway.Kill()};if(!$server.HasExited){$server.Kill()};throw "Gateway failed. Read $Directory/gateway.stderr.log"}
@{server_pid=$server.Id;gateway_pid=$gateway.Id;server_started=$server.StartTime.ToUniversalTime().ToString('O');gateway_started=$gateway.StartTime.ToUniversalTime().ToString('O');instance=$Directory} | ConvertTo-Json | Set-Content (Join-Path $Directory 'processes.json') -Encoding utf8NoBOM
Write-Output "Authority $($server.Id), gateway $($gateway.Id). Open http://127.0.0.1:$($config.http_port)/ after exporting the Web client."
