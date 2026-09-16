[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $target){throw 'Use a new template directory.'}
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'web.lock.json') -Raw | ConvertFrom-Json
if((Get-Item -LiteralPath $Archive).Length -ne $lock.bytes -or (Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant() -ne $lock.sha256){throw 'Official template archive checksum mismatch.'}
New-Item -ItemType Directory -Path $target | Out-Null
$zip=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Archive))
try {
    foreach($name in $lock.templates){
        $entry=$zip.GetEntry('templates/'+$name)
        if(!$entry){throw "Missing template $name"}
        $source=$entry.Open(); $output=[IO.File]::Create((Join-Path $target $name))
        try{$source.CopyTo($output)}finally{$output.Dispose();$source.Dispose()}
    }
} finally {$zip.Dispose()}
Write-Output 'Pinned Web debug templates extracted.'
