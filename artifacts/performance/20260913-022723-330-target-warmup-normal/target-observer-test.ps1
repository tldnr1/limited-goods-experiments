#requires -Version 7.0
# Real Start-Job/process boundary; Docker is mocked and PATH is cleared in each child.
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "target-observer-$([Guid]::NewGuid().ToString('N'))"
$job=$null
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
$initialize={
    $env:PATH=''
    function docker {
        $arguments=@($args)
        $global:LASTEXITCODE=0
        if ($arguments[0] -eq 'exec' -and $arguments -contains 'psql') {
            if ($arguments[2] -eq 'fail-postgres') { $global:LASTEXITCODE=23; return }
            if ($arguments[2] -eq 'invalid-json') { return '{' }
            if ($arguments[2] -ne 'id-postgres' -or ($input | Out-String) -notlike '*inventoryViolations*') {
                throw 'SQL input or PostgreSQL argument was lost'
            }
            # PostgreSQL json_agg can include physical newlines between array elements.
            return @('{"inventoryViolations":0,"inventory":[{"total":1000},',' {"total":301}]}')
        }
        if ($arguments[0] -eq 'stats') {
            if ($arguments.Count -ne 15 -or $arguments[4] -ne 'id-api1' -or $arguments[-1] -ne 'id-prometheus') {
                throw 'Container array was flattened or lost across Start-Job'
            }
            return $arguments[4..14] | ForEach-Object { @{Name=$_} | ConvertTo-Json -Compress }
        }
        if ($arguments[0] -eq 'ps' -and $arguments[2] -in @('name=^/goods-target-k6$','name=^/goods-target-warmup-k6$')) { return }
        if ($arguments[0] -eq 'exec' -and $arguments[1] -eq 'id-redis') {
            switch ($arguments[3]) {
                'INFO' { return 'redis_version:offline' }
                'EVAL' { return '{"queue":0,"ready":0,"live":0,"stale":0}' }
                'GET' {
                    if ($arguments[4] -ne 'goods:perf:catalog:offline-sale') { throw 'Fixture path or sale ID was lost' }
                    return '1:AVAILABLE'
                }
            }
        }
        throw "Unexpected Docker command: $($arguments -join ' ')"
    }
    function Start-Sleep {
        param($Seconds)
        $expected=if ((Split-Path $Directory -Leaf) -match '^(business|warmup)-') {1} else {5}
        if ($Seconds -ne $expected) { throw 'Sampling interval was lost' }
        # End after one sample without sleeping or running load.
        Set-Content -LiteralPath "$Directory/stop-observer" 'offline-stop'
    }
}
function Start-Job {
    param($FilePath,$ScriptBlock,$ArgumentList)
    # Exercise the production launch command with a real job, but never real Docker.
    Microsoft.PowerShell.Core\Start-Job @PSBoundParameters -InitializationScript $initialize -WorkingDirectory "$testRoot/unrelated"
}
function Invoke-Case([string]$Scenario,[string]$Failure='') {
    $caseDirectory=Join-Path $testRoot "results 한글 space/$Scenario-$Failure"
    New-Item -ItemType Directory -Path $caseDirectory -Force | Out-Null
    Set-Content -LiteralPath "$caseDirectory/fixture.json" '{"sale":{"id":"offline-sale"}}'
    $caseIds=[ordered]@{}
    foreach ($service in @('api1','api2','reservation','payment','worker','mock-pg','nginx','checkout-nginx','postgres','redis','prometheus')) {
        $caseIds[$service]="id-$service"
    }
    if ($Failure -eq 'docker') { $caseIds.postgres='fail-postgres' }
    if ($Failure -eq 'json') { $caseIds.postgres='invalid-json' }
    $script:job=& "$testRoot/repo 한글 space/ops/performance/launch.ps1" -directory $caseDirectory -ids $caseIds -Scenario $Scenario
    try {
        $null=Wait-Job $job -Timeout 20
        if ($job.State -eq 'Running') { throw 'Offline observer timed out' }
        $null=Receive-Job $job -ErrorAction SilentlyContinue
        if ($Failure) {
            Assert ($job.State -eq 'Failed') "$Failure did not fail the child job"
            Assert (-not (Test-Path -LiteralPath "$caseDirectory/observer-ready")) 'Failed sample signalled readiness'
            $errorText=Get-Content -LiteralPath "$caseDirectory/observer-error.txt" -Raw
            $expectedError=switch ($Failure) { 'sql' {'*target-state.sql*'} 'json' {'*JSON*'} default {'*DB sampling failed*'} }
            Assert ($errorText -like $expectedError) 'Failure evidence missing'
        } else {
            Assert ($job.State -eq 'Completed') "Child job failed: $(Get-Content -LiteralPath "$caseDirectory/observer-error.txt" -Raw -ErrorAction SilentlyContinue)"
            foreach ($name in @('observer-ready','db-samples.jsonl','resources.jsonl','redis-samples.jsonl')) {
                Assert (Test-Path -LiteralPath "$caseDirectory/$name") "Missing observer output: $name"
            }
            Assert (-not (Test-Path -LiteralPath "$caseDirectory/observer-error.txt")) 'Unexpected observer error'
            $dbLines=@(Get-Content -LiteralPath "$caseDirectory/db-samples.jsonl")
            Assert ($dbLines.Count -eq 1) 'One DB sample must occupy exactly one JSONL line'
            $dbSample=$dbLines[0] | ConvertFrom-Json
            Assert ($dbSample.inventory.Count -eq 2 -and $dbSample.inventory[1].total -eq 301) 'Nested inventory was lost'
            $resources=Get-Content -LiteralPath "$caseDirectory/resources.jsonl" -Raw | ConvertFrom-Json
            Assert ($resources.containers.Count -eq 11) 'Not all container IDs reached the child'
            $redisSample=Get-Content -LiteralPath "$caseDirectory/redis-samples.jsonl" -Raw | ConvertFrom-Json
            Assert ($redisSample.catalog -eq '1:AVAILABLE') 'Fixture/catalog sample missing'
        }
    } finally {
        if ($job.State -eq 'Running') { Stop-Job $job }
        Remove-Job $job
        $script:job=$null
    }
}
try {
    $scriptDirectory=Join-Path $testRoot 'repo 한글 space/ops/performance'
    New-Item -ItemType Directory -Path $scriptDirectory,"$testRoot/unrelated" -Force | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot/target-observe.ps1","$PSScriptRoot/target-state.sql" -Destination $scriptDirectory
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/target-trial.ps1",[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'Target parse error'
    $launch=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Job'},$true))
    Assert ($launch.Count -eq 1) 'Expected one Target observer launch'
    # Use the actual production expression from a relocated script, not a duplicate launcher.
    Set-Content -LiteralPath "$scriptDirectory/launch.ps1" -Value ('param($directory,$ids,$Scenario)' + "`n" + '$generatorName=if ($Scenario -eq ''warmup'') {''goods-target-warmup-k6''} else {''goods-target-k6''}' + "`n" + $launch[0].Extent.Text)
    Push-Location "$testRoot/unrelated"
    try {
        foreach ($scenario in @('warmup','worker','waiting','reservation','isolation','business')) { Invoke-Case $scenario }
        Invoke-Case 'worker' 'docker'
        Invoke-Case 'worker' 'json'
        Remove-Item -LiteralPath "$scriptDirectory/target-state.sql"
        Invoke-Case 'worker' 'sql'
    } finally { Pop-Location }
    '9 observer process checks passed (real Start-Job; mocked Docker; no HTTP, k6, or sleeps).'
} finally {
    if ($job) { Stop-Job $job; Remove-Job $job }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^target-observer-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
