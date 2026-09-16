[CmdletBinding()]
param([string]$Godot = '', [string]$WorldFile = '', [switch]$Editor, [string]$Screenshot = '', [string]$Database = '', [string]$StoreExecutable = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$arguments = @('--path', (Join-Path $prototypeRoot 'godot'))
if ($Editor) { $arguments += '--editor' }
$userArguments = @()
if ($Database) {
    if ($WorldFile) { throw 'Choose either WorldFile or Database.' }
    if (!$StoreExecutable) { $StoreExecutable = Join-Path $prototypeRoot '../services/RegionStore/bin/Release/net8.0/RegionStore.exe' }
    if (!(Test-Path -LiteralPath $StoreExecutable -PathType Leaf)) { throw 'Build/install RegionStore before selecting Database storage.' }
    $userArguments += @(('--database=' + [IO.Path]::GetFullPath($Database)), ('--store-exe=' + [IO.Path]::GetFullPath($StoreExecutable)))
}
if (-not [string]::IsNullOrWhiteSpace($WorldFile)) {
    $userArguments += '--world-file=' + [IO.Path]::GetFullPath($WorldFile)
}
if (-not [string]::IsNullOrWhiteSpace($Screenshot)) {
    if ($Editor) { throw 'Screenshot verification runs the project, not the editor.' }
    $imagePath = [IO.Path]::GetFullPath($Screenshot)
    New-Item -ItemType Directory -Path (Split-Path -Parent $imagePath) -Force | Out-Null
    $userArguments += @('--verify-render', ('--screenshot=' + $imagePath))
}
if ($userArguments.Count -gt 0) { $arguments += @('--') + $userArguments }
& $engine @arguments
exit $LASTEXITCODE
