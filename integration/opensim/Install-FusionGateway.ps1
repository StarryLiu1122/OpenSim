[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceDirectory,[Parameter(Mandatory)][string]$ClientBuildDirectory)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath($SourceDirectory)
$client=[IO.Path]::GetFullPath($ClientBuildDirectory)
$report=Get-Content -LiteralPath (Join-Path $client 'build-report.json') -Raw | ConvertFrom-Json
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'client.lock.json') -Raw | ConvertFrom-Json
if(!$report.passed -or $report.commit -ne $lock.commit){throw 'A verified pinned client build is required.'}
$pipeline=Get-Content -LiteralPath (Join-Path $client 'source/OpenMetaverse/TexturePipeline.cs') -Raw
if($pipeline.Contains('downloadMaster.Abort()') -or !$pipeline.Contains('shutdown.WaitOne(500)')){throw 'Required client patch is absent.'}
foreach($entry in $report.assemblies){
    if((Get-FileHash -LiteralPath (Join-Path $client ('source/bin/'+$entry.name))).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Client dependency checksum mismatch.'}
}
& (Join-Path $PSScriptRoot 'Install-FusionModule.ps1') -SourceDirectory $source
$clientBin=Join-Path $source 'fusion-client'
New-Item -ItemType Directory -Path $clientBin -Force | Out-Null
Copy-Item -Path (Join-Path $client 'source/bin/*.dll') -Destination $clientBin
Push-Location $PSScriptRoot
try {
    & dotnet build ReferenceBot/ReferenceBot.csproj -c Release --nologo -v:minimal "-p:OpenSimBin=$source/bin" "-p:ClientBin=$clientBin"
    if($LASTEXITCODE){throw 'Gateway Bot build failed.'}
} finally {Pop-Location}
$botDirectory=Join-Path $source 'fusion-bot'
New-Item -ItemType Directory -Path $botDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'ReferenceBot/bin/Release/net8.0/*') -Destination $botDirectory -Recurse -Force
$privatePath=Join-Path $source 'reference-private.json'
$private=Get-Content -LiteralPath $privatePath -Raw | ConvertFrom-Json -AsHashtable
foreach($key in @('observer_token','secondary_token')){if(!$private.ContainsKey($key)){$private[$key]=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')}}
if(!$private.ContainsKey('secondary_owner')){$private.secondary_owner=[guid]::NewGuid().ToString()}
$private | ConvertTo-Json | Set-Content -LiteralPath $privatePath -Encoding utf8
$ini=Join-Path $source 'bin/OpenSim.ini'
$text=[IO.File]::ReadAllText($ini)
$settings=[ordered]@{
    ObserverToken=$private.observer_token; SecondaryToken=$private.secondary_token; SecondaryOwner=$private.secondary_owner;
    BotDll=(Join-Path $botDirectory 'ReferenceBot.dll'); BotConfiguration=$privatePath; DotnetPath=(Get-Command dotnet).Source
}
foreach($key in $settings.Keys){
    $text=[regex]::Replace($text,"(?m)^$key = .*\r?\n",'')
    $text=$text.TrimEnd()+"`n$key = $($settings[$key])`n"
}
[IO.File]::WriteAllText($ini,$text.Replace("`r`n","`n"))
Write-Output 'Gateway and private test subjects installed. Restart this isolated reference instance.'
