[CmdletBinding()]
param([Parameter(Mandatory)][string]$Report,[string]$ExperimentDirectory='')
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $Report){throw 'Use a new report path.'}
$results=[Collections.Generic.List[object]]::new()
function Check-Document([string]$Name,[string]$Schema,[object]$Value,[bool]$Expected=$true){
    $valid=Test-Json -Json ($Value|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path $PSScriptRoot ('fp-v02-'+$Schema+'.schema.json')) -ErrorAction SilentlyContinue
    $results.Add(@{name=$Name;schema=$Schema;expected=$Expected;actual=[bool]$valid;passed=([bool]$valid -eq $Expected)})
}
$examples=Get-Content (Join-Path $PSScriptRoot 'fp-v02.examples.json') -Raw | ConvertFrom-Json
foreach($case in $examples.cases){Check-Document $case.name $case.schema $case.value $case.valid}
if($ExperimentDirectory){
    $exchange=Get-Content (Join-Path $ExperimentDirectory 'commands-and-receipts.json') -Raw | ConvertFrom-Json
    $index=0
    foreach($record in $exchange){
        $index++
        # Deliberately malformed requests and transport errors are covered by the live suite.
        if($record.receipt.state -eq 'completed' -or $record.receipt.state -eq 'pending') {Check-Document "runtime request $index" 'command' $record.request}
        if($record.receipt.fp_version){Check-Document "runtime receipt $index" 'receipt' $record.receipt}
    }
    Check-Document 'runtime initial state' 'snapshot' (Get-Content (Join-Path $ExperimentDirectory 'initial-state.json') -Raw|ConvertFrom-Json)
    $events=Get-Content (Join-Path $ExperimentDirectory 'events.json') -Raw|ConvertFrom-Json
    foreach($event in $events){Check-Document ('runtime event '+$event.seq) 'event' $event}
}
$failed=@($results | Where-Object {!$_.passed}).Count
@{scope='FP 0.2 structural fixtures and supplied real runtime records; runtime semantic checks remain separate';passed=$results.Count-$failed;failed=$failed;checks=@($results)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Report -Encoding utf8
if($failed){throw "$failed FP contract checks failed; inspect $Report"}
Write-Output "$($results.Count) FP contract checks passed."
