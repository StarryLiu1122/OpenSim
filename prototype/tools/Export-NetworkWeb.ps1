[CmdletBinding()]
param([Parameter(Mandatory)][string]$Godot,[Parameter(Mandatory)][string]$Template,[Parameter(Mandatory)][string]$Destination,[string]$PreviousExport='')
$ErrorActionPreference='Stop'
$Godot=[IO.Path]::GetFullPath($Godot); $Template=[IO.Path]::GetFullPath($Template); $Destination=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Use a new isolated export directory.' }
if ((& $Godot --version) -ne '4.5.1.stable.official.f62fdbde1') { throw 'Godot 4.5.1 standard required.' }
$webLock=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../integration/web/web.lock.json') -Raw|ConvertFrom-Json
if((Get-FileHash -LiteralPath $Template).Hash.ToLowerInvariant() -ne $webLock.release_template_sha256){throw 'The fixed official single-thread release template is required.'}
New-Item -ItemType Directory -Path $Destination | Out-Null
$engine=Join-Path $Destination 'engine'; New-Item -ItemType Directory -Path $engine | Out-Null
Get-ChildItem -LiteralPath (Split-Path -Parent $Godot) -Filter 'Godot_v4.5.1-stable_win64*.exe' | Copy-Item -Destination $engine
[IO.File]::WriteAllText((Join-Path $engine '_sc_'),'')
$Godot=Join-Path $engine (Split-Path -Leaf $Godot)
$project=Join-Path $Destination 'project'; New-Item -ItemType Directory -Path $project | Out-Null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../godot') -Force | Where-Object Name -ne '.godot' | Copy-Item -Destination $project -Recurse
$configuration=[IO.File]::ReadAllText((Join-Path $project 'project.godot')).Replace('res://main.tscn','res://network/client.tscn').Replace('OpenSimRegionLab','RegionLabNetworkWeb')
$configuration=$configuration.Replace('anti_aliasing/quality/msaa_3d=2',"anti_aliasing/quality/msaa_3d=0`nshading/overrides/force_vertex_shading=true`nshading/overrides/force_lambert_over_burley=true")
[IO.File]::WriteAllText((Join-Path $project 'project.godot'),$configuration)
$preset=@"
[preset.0]
name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="tests/*,tools/*,network/server.gd,network/server.tscn,network/storage_job.gd"
export_path=""
[preset.0.options]
custom_template/release="$($Template.Replace('\','/'))"
variant/extensions_support=false
variant/thread_support=false
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
"@
[IO.File]::WriteAllText((Join-Path $project 'export_presets.cfg'),$preset)
$web=Join-Path $Destination 'web'; New-Item -ItemType Directory -Path $web | Out-Null
& $Godot --headless --path $project --log-file (Join-Path $Destination 'import.log') --editor --import --quit
if ($LASTEXITCODE) { throw 'Clean project import failed.' }
& $Godot --headless --path $project --log-file (Join-Path $Destination 'export.log') --export-release Web (Join-Path $web 'index.html')
if ($LASTEXITCODE) { throw 'Web release export failed.' }
$htmlPath=Join-Path $web 'index.html'
$bridge=@'
<input id="region-file" type="file" accept=".glb" hidden />
<script>
const picker=document.getElementById('region-file');
picker.addEventListener('cancel',()=>{window.regionLabFileEvent='已取消选择，世界未更改';});
picker.addEventListener('change',async()=>{
  const file=picker.files[0];
  if(!file){window.regionLabFileEvent='已取消选择，世界未更改';return;}
  if(file.size>2097152){window.regionLabFileEvent='文件超过 2 MiB 限制';picker.value='';return;}
  const bytes=new Uint8Array(await file.arrayBuffer());let raw='';
  for(let offset=0;offset<bytes.length;offset+=8192)raw+=String.fromCharCode(...bytes.subarray(offset,offset+8192));
  window.regionLabFile={name:file.name.slice(0,160),bytes:btoa(raw)};picker.value='';
});
document.addEventListener('visibilitychange',()=>{
  if(!document.hidden&&window.regionLabActions)window.regionLabActions.push({type:'resync'});
});
</script>
'@
[IO.File]::WriteAllText($htmlPath,[IO.File]::ReadAllText($htmlPath).Replace('</body>',$bridge+'</body>'),[Text.UTF8Encoding]::new($false))
foreach($file in Get-ChildItem -LiteralPath $web -File | Where-Object Extension -in '.js','.wasm','.pck','.html') {
    foreach($encoding in @('br','gz')) {
        # Reuse only byte-identical compressed content after decompressing and
        # hashing it. This avoids recompressing the fixed 38 MB engine each run.
        if ($PreviousExport) {
            $cached=Join-Path $PreviousExport ('web/'+$file.Name+'.'+$encoding)
            if (Test-Path -LiteralPath $cached) {
                $source=[IO.File]::OpenRead($cached)
                $decoder=if($encoding -eq 'br'){[IO.Compression.BrotliStream]::new($source,[IO.Compression.CompressionMode]::Decompress)}else{[IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)}
                $hash=[Security.Cryptography.SHA256]::Create()
                try{$same=[Convert]::ToHexString($hash.ComputeHash($decoder)) -eq (Get-FileHash -LiteralPath $file.FullName).Hash}finally{$hash.Dispose();$decoder.Dispose();$source.Dispose()}
                if($same){Copy-Item -LiteralPath $cached -Destination ($file.FullName+'.'+$encoding);continue}
            }
        }
        $input=[IO.File]::OpenRead($file.FullName); $output=[IO.File]::Create($file.FullName+'.'+$encoding)
        $compressor=if($encoding -eq 'br'){[IO.Compression.BrotliStream]::new($output,[IO.Compression.CompressionLevel]::SmallestSize,$false)}else{[IO.Compression.GZipStream]::new($output,[IO.Compression.CompressionLevel]::SmallestSize,$false)}
        try{$input.CopyTo($compressor)}finally{$compressor.Dispose();$output.Dispose();$input.Dispose()}
    }
}
$files=@(Get-ChildItem -LiteralPath $web -File | Sort-Object Name | ForEach-Object {@{path=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
@{engine='4.5.1.stable.official.f62fdbde1';application='0.5.1';profile='WebGL2 / Jolt / single thread / release';template_sha256=(Get-FileHash -LiteralPath $Template).Hash.ToLowerInvariant();files=$files} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Destination 'export-manifest.json') -Encoding utf8NoBOM
Write-Output "Web client: $web"
