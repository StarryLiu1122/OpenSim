[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PrivateConfig, [Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Report) { throw 'A new report path is required.' }
$c = Get-Content -LiteralPath $PrivateConfig -Raw | ConvertFrom-Json
$uri = $c.url + '/fusion/v0/regions/' + $c.region_id + '/commands'
$headers = @{Authorization=('Bearer '+$c.token)}
function New-Request([string]$Epoch) { return [ordered]@{fp_version='0.1';request_id=[guid]::NewGuid().ToString();trace_id=[guid]::NewGuid().ToString();world_epoch=$Epoch;operation='GetSnapshot';expires_at=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o');payload=@{}} }
$handshake=New-Request ''; $handshake.operation='GetCapabilities'
$cap=Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body ($handshake | ConvertTo-Json)
$cases=@(
    @{name='uppercase request ID'; edit={param($q) $q.request_id='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'};status=400;error='INVALID_ENVELOPE'},
    @{name='zero request ID'; edit={param($q) $q.request_id='00000000-0000-0000-0000-000000000000'};status=400;error='INVALID_ENVELOPE'},
    @{name='unexpected subject'; edit={param($q) $q.issued_by=$c.owner_id};status=400;error='INVALID_FIELDS'},
    @{name='unsupported FP'; edit={param($q) $q.fp_version='1'};status=400;error='INVALID_ENVELOPE'},
    @{name='deadline without timezone'; edit={param($q) $q.expires_at='2030-01-01T00:00:00'};status=400;error='INVALID_ENVELOPE'},
    @{name='string payload'; edit={param($q) $q.payload='data'};status=400;error='INVALID_ENVELOPE'},
    @{name='unknown operation'; edit={param($q) $q.operation='RunScript'};status=200;error='UNSUPPORTED_OPERATION'},
    @{name='caller cannot select owner'; edit={param($q) $q.operation='CreateBox';$q.payload=@{name='forged';position=@(10,10,2);size=@(1,1,1);owner_id=[guid]::NewGuid().ToString()}};status=200;error='INVALID_FIELDS'},
    @{name='null vector'; edit={param($q) $q.operation='CreateBox';$q.payload=@{name='invalid';position=$null;size=@(1,1,1)}};status=200;error='INVALID_VECTOR'}
)
$results=@()
foreach ($case in $cases) {
    $request=New-Request $cap.world_epoch; & $case.edit $request
    $response=Invoke-WebRequest -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body ($request | ConvertTo-Json -Depth 10) -SkipHttpErrorCheck
    $data=$response.Content | ConvertFrom-Json
    $results+=@{name=$case.name;status=[int]$response.StatusCode;error=$data.error;ok=($response.StatusCode -eq $case.status -and $data.error -eq $case.error)}
}
$q=New-Request $cap.world_epoch
$json=($q|ConvertTo-Json -Depth 10 -Compress) -replace '"payload":\{\}', '"payload":{},"payload":{}'
$duplicate=Invoke-WebRequest -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body $json -SkipHttpErrorCheck
$results+=@{name='duplicate property';status=[int]$duplicate.StatusCode;ok=($duplicate.StatusCode -eq 400)}
$wrongToken=Invoke-WebRequest -Uri $uri -Headers @{Authorization='Bearer invalid'} -Method Post -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
$results+=@{name='invalid bearer token';status=[int]$wrongToken.StatusCode;ok=($wrongToken.StatusCode -eq 401)}
$get=Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -SkipHttpErrorCheck
$results+=@{name='unsupported HTTP method';status=[int]$get.StatusCode;ok=($get.StatusCode -eq 405)}
$failed=@($results | Where-Object { -not $_.ok }).Count
@{passed=($results.Count-$failed);failed=$failed;results=$results} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Report -Encoding UTF8
if ($failed) { throw 'Live protocol rejection checks failed.' }
Write-Output "$($results.Count) live protocol rejection checks passed."
