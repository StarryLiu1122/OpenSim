[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory,[ValidateSet('editor-a','editor-b','observer','guest')][string]$Profile='editor-a')
$ErrorActionPreference='Stop'
$Directory=[IO.Path]::GetFullPath($Directory)
$path=Join-Path $Directory 'private-config.json'
$config=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$log=Join-Path $Directory ('client-'+$Profile+'-'+[guid]::NewGuid().ToString('N')+'.log')
$executable=$config.godot.Replace('_console.exe','.exe')
if(!(Test-Path -LiteralPath $executable)){$executable=$config.godot}
$arguments=@('--path',('"'+$config.project+'"'),'--log-file',('"'+$log+'"'),'res://network/client.tscn','--',('"--network-config='+$path+'"'),('--profile='+$Profile))
$client=Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -WindowStyle Normal
Write-Output "Client $Profile launched as process $($client.Id). Log: $log"
