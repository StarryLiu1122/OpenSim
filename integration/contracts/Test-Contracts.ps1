[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Report) { throw 'A new report path is required.' }
$schema = Join-Path $PSScriptRoot 'reference-command.schema.json'
$cases = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reference-command.examples.json') -Raw | ConvertFrom-Json).cases
$results = @()
foreach ($case in $cases) {
    $valid = Test-Json -Json ($case.command | ConvertTo-Json -Depth 15 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue
    $results += @{name=$case.name; expected=$case.valid; actual=[bool]$valid; ok=([bool]$valid -eq $case.valid)}
}
$failed = @($results | Where-Object { -not $_.ok }).Count
@{ scope='JSON Schema structural examples only'; passed=($results.Count-$failed); failed=$failed; results=$results } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Report -Encoding UTF8
if ($failed) { throw 'Contract examples failed.' }
Write-Output "$($results.Count) contract examples passed."
