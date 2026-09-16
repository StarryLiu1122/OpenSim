[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('init','status','load','save','export','backup','import','gc')][string]$Operation,
    [Parameter(Mandatory)][string]$Root,
    [string]$StoreExecutable = '', [string]$Godot = '', [string]$Project = '',
    [string]$RegionId = '33333333-3333-4333-8333-333333333333',
    [string]$InputFile = '', [string]$OutputFile = '', [long]$ExpectedCommit = -1,
    [string]$RequestId = '', [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference='Stop'
if (!$StoreExecutable) { $StoreExecutable=Join-Path $PSScriptRoot 'RegionStore/bin/Release/net8.0/RegionStore.exe' }
if (!$Project) { $Project=Join-Path $PSScriptRoot '../prototype/godot' }
if (!$Godot) {
    . (Join-Path $PSScriptRoot '../prototype/tools/Common.ps1')
    $Godot=Get-RegionLabEngine ''
}
$reportPath=[IO.Path]::GetFullPath($Report)
if (Test-Path -LiteralPath $reportPath) { throw 'Report must be a new file.' }
if ($Operation -in @('save','import') -and !$RequestId) { throw 'Save/import requires an explicit RequestId; reuse it unchanged after an uncertain result.' }
$request=@{operation=$Operation;root=[IO.Path]::GetFullPath($Root);region_id=$RegionId;godot=[IO.Path]::GetFullPath($Godot);project=[IO.Path]::GetFullPath($Project)}
if ($InputFile) { $request.input=[IO.Path]::GetFullPath($InputFile) }
if ($OutputFile) { $request.output=[IO.Path]::GetFullPath($OutputFile) }
if ($Operation -in @('save','import')) { $request.expected_commit=$ExpectedCommit; $request.request_id=$RequestId }
New-Item -ItemType Directory -Path (Split-Path -Parent $reportPath) -Force | Out-Null
$inputPath=$reportPath+'.request.json'
if (Test-Path -LiteralPath $inputPath) { throw 'Request record already exists.' }
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath -Encoding utf8
& $StoreExecutable $inputPath $reportPath
if ($LASTEXITCODE) { throw "Storage operation failed; inspect $reportPath" }
Get-Content -LiteralPath $reportPath -Raw
