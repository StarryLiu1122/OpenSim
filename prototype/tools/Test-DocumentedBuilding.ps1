[CmdletBinding()]
param([string]$Godot = '', [Parameter(Mandatory)][string]$OutputDirectory)
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$output = [IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output) { throw 'Use a new isolated directory.' }
New-Item -ItemType Directory -Path $output | Out-Null
$write = Join-Path $output 'original path'
$read = Join-Path $output 'relocated path'
New-Item -ItemType Directory -Path $write,$read | Out-Null
foreach($phase in @('write','read')) {
    $dir = if($phase -eq 'write'){$write}else{$read}
    if($phase -eq 'read') { Copy-Item -LiteralPath (Join-Path $write 'cabin.snapshot.json') -Destination $read }
    $log = Join-Path $dir 'engine'
    $null = Invoke-RegionLabCheck $engine @('--path',(Join-Path $prototypeRoot 'godot'),'--script','res://tests/documented_building.gd','--log-file',($log+'.log'),'--',('--output-dir='+$dir),('--mode='+$phase)) $log
    $report = Get-Content -LiteralPath (Join-Path $dir ('building-'+$phase+'.json')) -Raw | ConvertFrom-Json
    if(!$report.passed){throw "Building verification failed: $phase"}
}
Write-Output "Documented building and separate-process recovery passed: $output"
