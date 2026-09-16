[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$Templates,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$Godot = [IO.Path]::GetFullPath($Godot)
$Templates = [IO.Path]::GetFullPath($Templates)
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Use a new isolated destination.' }
New-Item -ItemType Directory -Path $Destination | Out-Null
$isolatedEngine = Join-Path $Destination 'engine'
New-Item -ItemType Directory -Path $isolatedEngine | Out-Null
Get-ChildItem -LiteralPath (Split-Path -Parent $Godot) -Filter 'Godot_v4.5.1-stable_win64*.exe' | Copy-Item -Destination $isolatedEngine
[IO.File]::WriteAllText((Join-Path $isolatedEngine '_sc_'), '')
$Godot = Join-Path $isolatedEngine (Split-Path -Leaf $Godot)
$project = Join-Path $Destination 'project'
$prototype = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../prototype'))
New-Item -ItemType Directory -Path $project | Out-Null
Get-ChildItem -LiteralPath (Join-Path $prototype 'godot') -Force | Where-Object Name -ne '.godot' | Copy-Item -Destination $project -Recurse
New-Item -ItemType Directory -Path (Join-Path $project 'probe-fixtures') | Out-Null
Copy-Item -LiteralPath (Join-Path $prototype 'fixtures/meshes/pavilion.glb') -Destination (Join-Path $project 'probe-fixtures/pavilion.bytes')
$base = [IO.File]::ReadAllText((Join-Path $project 'project.godot')).Replace('res://main.tscn','res://tests/web_probe.tscn').Replace('OpenSimRegionLab','RegionLabIsolatedWebProbe')
foreach ($profile in @('jolt-single','jolt-threads','godot-single')) {
    $threaded = $profile -eq 'jolt-threads'
    $configuration = if ($profile -eq 'godot-single') { $base.Replace('Jolt Physics','GodotPhysics3D') } else { $base }
    [IO.File]::WriteAllText((Join-Path $project 'project.godot'), $configuration)
    $template = Join-Path $Templates $(if($threaded){'web_debug.zip'}else{'web_nothreads_debug.zip'})
    if (!(Test-Path -LiteralPath $template)) { throw "Missing template $template" }
    $preset = @"
[preset.0]
name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter="*.bytes"
exclude_filter=""
export_path=""

[preset.0.options]
custom_template/debug="$($template.Replace('\','/'))"
variant/extensions_support=false
variant/thread_support=$($threaded.ToString().ToLowerInvariant())
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
"@
    [IO.File]::WriteAllText((Join-Path $project 'export_presets.cfg'), $preset)
    $out = Join-Path $Destination $profile
    New-Item -ItemType Directory -Path $out | Out-Null
    & $Godot --headless --path $project --log-file (Join-Path $out 'import.log') --editor --import
    if ($LASTEXITCODE) { throw "Import failed: $profile" }
    & $Godot --headless --path $project --log-file (Join-Path $out 'export.log') --export-debug Web (Join-Path $out 'index.html')
    if ($LASTEXITCODE) { throw "Export failed: $profile" }
    $html = [IO.File]::ReadAllText((Join-Path $out 'index.html'))
    $picker = '<input id="probe-file" type="file" accept=".glb" style="position:fixed;right:12px;top:12px;z-index:9999" /><script>document.getElementById("probe-file").onchange=async(e)=>{const b=new Uint8Array(await e.target.files[0].arrayBuffer());if(b.length>2097152)throw Error("FILE_LIMIT");let s="";for(const v of b)s+=String.fromCharCode(v);window.regionLabSelected=btoa(s);};</script>'
    [IO.File]::WriteAllText((Join-Path $out 'index.html'), $html.Replace('</body>', $picker + '</body>'))
}
$files = Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object FullName -NotMatch '[\\/](project|engine)[\\/]' | ForEach-Object {
    @{path=[IO.Path]::GetRelativePath($Destination,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
@{engine='4.5.1.stable';files=@($files)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'export-manifest.json') -Encoding utf8
