[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OriginalEvidence, [Parameter(Mandatory=$true)][string]$ModernEvidence, [Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Report) { throw 'A new comparison report is required.' }
$checks = [Collections.Generic.List[object]]::new()
function Near($A, $B) {
    if ($A.Count -ne $B.Count) { return $false }
    for ($i=0; $i -lt $A.Count; $i++) { if ([Math]::Abs([double]$A[$i]-[double]$B[$i]) -gt 0.0002) { return $false } }
    return $true
}
foreach ($phase in @('Create','RestartLinked','RestartUnlinked')) {
    $original = Get-Content -LiteralPath (Join-Path $OriginalEvidence ($phase + '.json')) -Raw | ConvertFrom-Json
    $modern = Get-Content -LiteralPath (Join-Path $ModernEvidence ($phase + '.json')) -Raw | ConvertFrom-Json
    if ($original.failed -ne 0 -or -not $modern.ok) { throw 'Input test failed.' }
    foreach ($entry in $modern.captures.PSObject.Properties) {
        $step = $entry.Name
        $a = @($original.captures.$step.groups | ForEach-Object { $_.parts } | Sort-Object name,@{Expression={($_.world_position | ForEach-Object { [Math]::Round($_,3) }) -join ','}})
        $b = @($entry.Value.resolved | Sort-Object name,@{Expression={($_.position | ForEach-Object { [Math]::Round($_,3) }) -join ','}})
        $checks.Add(@{step=$step;field='part_count';ok=($a.Count -eq $b.Count)})
        if ($a.Count -ne $b.Count) { continue }
        for ($i=0; $i -lt $a.Count; $i++) {
            $checks.Add(@{step=$step;part=$a[$i].name;field='name';ok=($a[$i].name -eq $b[$i].name)})
            $checks.Add(@{step=$step;part=$a[$i].name;field='position';ok=(Near $a[$i].world_position $b[$i].position)})
            $checks.Add(@{step=$step;part=$a[$i].name;field='size';ok=(Near $a[$i].size $b[$i].size)})
            $checks.Add(@{step=$step;part=$a[$i].name;field='rotation';ok=(Near $a[$i].world_rotation $b[$i].rotation)})
        }
    }
}
$failures = @($checks | Where-Object { -not $_.ok })
@{ tolerance=0.0002; passed=($checks.Count-$failures.Count); failed=$failures.Count; scope='world-space static box transforms; identity policies compared separately'; checks=$checks } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Report -Encoding UTF8
if ($failures.Count) { $failures | Format-Table; throw 'Original/modern transform comparison failed.' }
@{ passed=$checks.Count; report=$Report } | ConvertTo-Json
