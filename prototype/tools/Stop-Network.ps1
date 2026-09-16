[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
$Directory=[IO.Path]::GetFullPath($Directory)
$record=Get-Content -LiteralPath (Join-Path $Directory 'processes.json') -Raw | ConvertFrom-Json
$config=Get-Content -LiteralPath (Join-Path $Directory 'private-config.json') -Raw | ConvertFrom-Json
foreach($entry in @(@{id=$record.gateway_pid;exe=$config.host_executable;started=$record.gateway_started},@{id=$record.server_pid;exe=$config.godot;started=$record.server_started})) {
    $process=Get-Process -Id $entry.id -ErrorAction SilentlyContinue
    if(!$process){continue}
    if([IO.Path]::GetFullPath($process.Path) -ne [IO.Path]::GetFullPath($entry.exe)){throw 'PID now belongs to a different executable; no process was stopped.'}
    if(!$entry.started -or $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$entry.started).UtcTicks){throw 'Process start time does not match this instance; no process was stopped.'}
    $process.Kill();$process.WaitForExit(10000)|Out-Null
}
Write-Output 'Instance processes stopped. Query unacknowledged commands after restart; committed SQLite transactions remain recoverable.'
