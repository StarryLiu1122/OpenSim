[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PrivateConfig,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [ValidateSet('Create','RestartLinked','RestartUnlinked')][string]$Phase = 'Create'
)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $PrivateConfig -Raw | ConvertFrom-Json
$uri = $config.url + '/fusion/v0/regions/' + $config.region_id + '/commands'
$headers = @{ Authorization = ('Bearer ' + $config.token) }
$trace = [guid]::NewGuid().ToString()
$epoch = ''
$checks = [Collections.Generic.List[object]]::new()
$exchange = [Collections.Generic.List[object]]::new()
$captures = [ordered]@{}
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($Phase -eq 'Create') {
    if (Test-Path -LiteralPath $evidence) { throw 'Create requires a new evidence directory.' }
    New-Item -ItemType Directory -Path $evidence | Out-Null
} elseif (-not (Test-Path -LiteralPath (Join-Path $evidence 'state.json'))) { throw 'Run Create first.' }
function Assert-Check([string]$Name, [bool]$Ok) {
    $checks.Add(@{ name=$Name; ok=$Ok })
    if (-not $Ok) { throw "Check failed: $Name" }
}
function Send-Command([object]$Command) {
    $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body ($Command | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 15
    $exchange.Add(@{ command=($Command | ConvertTo-Json -Depth 20 | ConvertFrom-Json); result=$result })
    return $result
}
function New-Command([string]$Operation, [hashtable]$Payload = @{}) {
    return [ordered]@{ fp_version='0.1'; request_id=[guid]::NewGuid().ToString(); trace_id=$trace; world_epoch=$script:epoch; operation=$Operation; expires_at=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o'); payload=$Payload }
}
function Invoke-CommandChecked([string]$Operation, [hashtable]$Payload = @{}) {
    $r = Send-Command (New-Command $Operation $Payload)
    Assert-Check "$Operation completed" ($r.state -eq 'completed')
    return $r.data
}
function Capture([string]$Step) {
    $s = Invoke-CommandChecked 'GetSnapshot'
    $captures[$Step] = $s
    return $s
}
function Find-Part([object]$Snapshot,[string]$Id) {
    return @($Snapshot.groups | ForEach-Object { $_.parts } | Where-Object { $_.id -eq $Id })[0]
}
function Near([object]$A, [object]$B) {
    if ($A.Count -ne $B.Count) { return $false }
    for ($i=0; $i -lt $A.Count; $i++) { if ([Math]::Abs([double]$A[$i]-[double]$B[$i]) -gt 0.0002) { return $false } }
    return $true
}
function Assert-SameWorld([object]$Before, [object]$After, [string]$Label) {
    Assert-Check "$Label group count" ($Before.groups.Count -eq $After.groups.Count)
    foreach ($g in $Before.groups) {
        $other = @($After.groups | Where-Object { $_.group_id -eq $g.group_id })
        Assert-Check "$Label group identity" ($other.Count -eq 1 -and $other[0].root_id -eq $g.root_id -and $other[0].parts.Count -eq $g.parts.Count)
        foreach ($part in $g.parts) {
            $p = Find-Part $After $part.id
            Assert-Check "$Label part identity and transform" ($null -ne $p -and $p.owner_id -eq $part.owner_id -and $p.link_number -eq $part.link_number -and (Near $p.world_position $part.world_position) -and (Near $p.local_position $part.local_position) -and (Near $p.world_rotation $part.world_rotation) -and (Near $p.size $part.size))
        }
    }
}
try {
    $caps = Send-Command (New-Command 'GetCapabilities')
    Assert-Check 'Capability handshake' ($caps.state -eq 'completed' -and $caps.data.authority -eq 'OpenSim')
    $epoch = $caps.world_epoch
    if ($Phase -eq 'Create') {
        $initial = Capture 'C00'
        Assert-Check 'Dedicated empty region' ($initial.groups.Count -eq 0)
        $root = Invoke-CommandChecked 'CreateBox' @{ name='V4-root'; position=@(120,128,2); size=@(1,1,1) }
        $child = Invoke-CommandChecked 'CreateBox' @{ name='V4-child'; position=@(122,128,2); size=@(1,1,1) }
        $rootId = $root.root_id; $childId = $child.root_id
        $c1 = Capture 'C01'
        Assert-Check 'C01 two independent parts' ($c1.groups.Count -eq 2)
        Invoke-CommandChecked 'Link' @{ root_id=$rootId; child_id=$childId } | Out-Null
        $c2 = Capture 'C02'
        Assert-Check 'C02 chosen root and group ID' ($c2.groups.Count -eq 1 -and $c2.groups[0].root_id -eq $rootId -and $c2.groups[0].group_id -eq $rootId)
        Assert-Check 'C02 child ID and local position' (Near (Find-Part $c2 $childId).local_position @(2,0,0))
        Invoke-CommandChecked 'Move' @{ group_id=$rootId; position=@(123,132,2) } | Out-Null
        $c3 = Capture 'C03'
        Assert-Check 'C03 group translation' (Near (Find-Part $c3 $childId).world_position @(125,132,2))
        Invoke-CommandChecked 'Move' @{ group_id=$rootId; position=@(120,128,2) } | Out-Null
        $half = [Math]::Sqrt(0.5)
        Invoke-CommandChecked 'Rotate' @{ group_id=$rootId; rotation=@(0,0,$half,$half) } | Out-Null
        $c4 = Capture 'C04'
        Assert-Check 'C04 positive Z rotation' (Near (Find-Part $c4 $childId).world_position @(120,130,2))
        Invoke-CommandChecked 'MoveMember' @{ group_id=$rootId; member_id=$childId; local_position=@(3,0,0) } | Out-Null
        Invoke-CommandChecked 'Scale' @{ group_id=$rootId; factor=2 } | Out-Null
        $c5 = Capture 'C05'
        Assert-Check 'C05 child edit and scale position' (Near (Find-Part $c5 $childId).world_position @(120,134,2))
        Assert-Check 'C05 scaled dimensions' (Near (Find-Part $c5 $childId).size @(2,2,2))
        $duplicateCommand = New-Command 'Duplicate' @{ group_id=$rootId; offset=@(10,0,0) }
        $duplicate = Send-Command $duplicateCommand
        Assert-Check 'C06 duplicate completed' ($duplicate.state -eq 'completed')
        $c6 = Capture 'C06'
        $copy = @($c6.groups | Where-Object { $_.group_id -ne $rootId })[0]
        Assert-Check 'C06 new group and member IDs' ($c6.groups.Count -eq 2 -and @($copy.parts | Where-Object { $_.id -in @($rootId,$childId) }).Count -eq 0)
        Assert-Check 'C06 duplicate rotation preserved' (Near $copy.rotation $c5.groups[0].rotation)
        $retry = Send-Command $duplicateCommand
        Assert-Check 'Same request returns same duplicate receipt' ($retry.data.group_id -eq $duplicate.data.group_id -and $retry.adapter_sequence -eq $duplicate.adapter_sequence)
        $queried = Invoke-CommandChecked 'GetReceipt' @{ request_id=$duplicateCommand.request_id }
        Assert-Check 'Receipt can be queried' ($queried.data.group_id -eq $duplicate.data.group_id)
        $duplicateCommand.payload.offset = @(11,0,0)
        $reused = Send-Command $duplicateCommand
        Assert-Check 'Reused ID with different content rejected' ($reused.error -eq 'REQUEST_REUSED')
        $negative = @(
            @{ op='Move'; p=@{group_id=$rootId;position=@(-1,128,2)}; error='OUT_OF_BOUNDS' },
            @{ op='Rotate'; p=@{group_id=$rootId;rotation=@(0,0,0,0)}; error='INVALID_ROTATION' },
            @{ op='Link'; p=@{root_id=$rootId;child_id=$rootId}; error='TWO_DISTINCT_SINGLE_PARTS_REQUIRED' },
            @{ op='Move'; p=@{group_id=$childId;position=@(120,128,2)}; error='ROOT_REQUIRED' },
            @{ op='Scale'; p=@{group_id=$rootId;factor=0}; error='INVALID_SCALE' },
            @{ op='MoveMember'; p=@{group_id=$rootId;member_id=$rootId;local_position=@(2,0,0)}; error='CHILD_REQUIRED' },
            @{ op='RunScript'; p=@{}; error='UNSUPPORTED_OPERATION' }
        )
        foreach ($case in $negative) {
            $r = Send-Command (New-Command $case.op $case.p)
            Assert-Check ('C09 reject ' + $case.error) ($r.state -eq 'rejected' -and $r.error -eq $case.error)
        }
        $expired = New-Command 'CreateBox' @{name='expired';position=@(10,10,2);size=@(1,1,1)}
        $expired.expires_at = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToString('o')
        Assert-Check 'Expired mutation rejected' ((Send-Command $expired).error -eq 'INVALID_DEADLINE')
        $wrongEpoch = New-Command 'Delete' @{group_id=$rootId}; $wrongEpoch.world_epoch=[guid]::NewGuid().ToString()
        Assert-Check 'Wrong epoch rejected' ((Send-Command $wrongEpoch).error -eq 'EPOCH_MISMATCH')
        $unauthorized = Invoke-WebRequest -Uri $uri -Method Post -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
        Assert-Check 'Unauthenticated request rejected' ($unauthorized.StatusCode -eq 401)
        $oversized = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body (' ' * 65537) -SkipHttpErrorCheck
        Assert-Check 'Oversized request rejected' ($oversized.StatusCode -eq 413)
        $badJson = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body '{' -SkipHttpErrorCheck
        Assert-Check 'Malformed JSON rejected' ($badJson.StatusCode -eq 400)
        $unchanged = Capture 'C09'
        Assert-SameWorld $c6 $unchanged 'Rejected mutations preserve world'
        Invoke-CommandChecked 'Backup' | Out-Null
        @{ epoch=$epoch; root_id=$rootId; child_id=$childId; copy_id=$copy.group_id; linked=$unchanged; old_command=$wrongEpoch } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence 'state.json') -Encoding UTF8
    } else {
        $saved = Get-Content -LiteralPath (Join-Path $evidence 'state.json') -Raw | ConvertFrom-Json
        Assert-Check 'Restart creates a new epoch' ($epoch -ne $saved.epoch)
        $current = Capture $(if ($Phase -eq 'RestartLinked') {'C07'} else {'C08-restart'})
        $old = $saved.old_command; $old.world_epoch=$saved.epoch; $old.expires_at=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o')
        Assert-Check 'Old generation mutation cannot replay' ((Send-Command $old).error -eq 'EPOCH_MISMATCH')
        if ($Phase -eq 'RestartLinked') {
            Assert-SameWorld $saved.linked $current 'C07 linked restart'
            Invoke-CommandChecked 'Unlink' @{group_id=$saved.root_id} | Out-Null
            $unlinked = Capture 'C08'
            Assert-Check 'C08 two independent original parts plus copy' ($unlinked.groups.Count -eq 3)
            foreach ($partId in @($saved.root_id,$saved.child_id)) {
                $before = Find-Part $current $partId; $after = Find-Part $unlinked $partId
                Assert-Check 'C08 ID and world transform preserved' ((Near $before.world_position $after.world_position) -and (Near $before.world_rotation $after.world_rotation) -and (Near $before.size $after.size))
            }
            Invoke-CommandChecked 'Backup' | Out-Null
            $saved | Add-Member -NotePropertyName unlinked -NotePropertyValue $unlinked -Force
            $saved.epoch=$epoch
            $saved | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence 'state.json') -Encoding UTF8
        } else { Assert-SameWorld $saved.unlinked $current 'C08 unlinked restart' }
    }
} catch {
    if (@($checks | Where-Object { -not $_.ok }).Count -eq 0) { $checks.Add(@{name='Execution completed without transport or script failure';ok=$false}) }
    throw
} finally {
    [ordered]@{ phase=$Phase; utc=[DateTimeOffset]::UtcNow.ToString('o'); passed=@($checks | Where-Object ok).Count; failed=@($checks | Where-Object { -not $_.ok }).Count; checks=$checks; captures=$captures; exchanges=$exchange } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $evidence ($Phase + '.json')) -Encoding UTF8
}
[ordered]@{ phase=$Phase; passed=$checks.Count; report=(Join-Path $evidence ($Phase + '.json')) } | ConvertTo-Json
