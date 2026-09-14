[CmdletBinding()]
param([string]$Godot = '', [string]$WorldFile = '', [switch]$Editor, [string]$Screenshot = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
$engine = Get-RegionLabEngine $Godot
$arguments = @('--path', (Join-Path $prototypeRoot 'godot'))
if ($Editor) { $arguments += '--editor' }
$userArguments = @()
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
