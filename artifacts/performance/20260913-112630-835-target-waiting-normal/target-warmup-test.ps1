# Offline orchestration, cleanup and bounded-drain boundaries; no Docker/HTTP/real sleeps.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/target-trial.ps1"
. "$PSScriptRoot/target-warmup-cleanup.ps1"
$directory=Join-Path ([IO.Path]::GetTempPath()) "target-warmup-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $directory | Out-Null
$calls=[Collections.Generic.List[string]]::new()
function Assert($ok,$message) { if (-not $ok) { throw $message } }
function Start-Sleep { param($Seconds,$Milliseconds) $calls.Add("sleep:$Seconds/$Milliseconds") }
$states=[Collections.Generic.Queue[object]]::new()
$cleanupSql=''
function Sql($statement) {
    if ($statement -like '*DO $*') { $script:cleanupSql=$statement; $calls.Add('delete'); return }
    if ($statement -eq 'SELECT count(*) FROM sales') { return '0' }
    if ($states.Count) { return ($states.Dequeue() | ConvertTo-Json -Compress) }
    return '{}'
}
$ids=@{redis='redis'}
function Invoke-Docker($Arguments) {
    if ($Arguments -contains '--scan') { $calls.Add('scan'); return 'goods:perf:key' }
    if ($Arguments -contains 'DEL') { $calls.Add('redis-delete'); return '1' }
    throw 'Unexpected Docker operation'
}
try {
    foreach ($state in @(
        @{successAccepted=0;successPending=0;successDeadlineViolations=0},
        @{successAccepted=1;successPending=0;successDeadlineViolations=0},
        @{successAccepted=1;successPending=1;successDeadlineViolations=1}
    )) {
        $states.Enqueue($state)
        $reason=Wait-TargetSuccessDrain $directory
        $expected=if ($state.successAccepted -eq 0) {'no_payment_work'} elseif ($state.successPending -eq 0) {'all_success_terminal'} else {'deadline_reached'}
        Assert ($reason -eq $expected) 'Drain reason incorrect'
    }
    $states.Enqueue(@{successAccepted=1;successPending=1;successDeadlineViolations=0;latestSuccessPendingDeadline=[DateTimeOffset]::UtcNow.AddSeconds(10).ToString('o')})
    $states.Enqueue(@{successAccepted=1;successPending=0;successDeadlineViolations=0})
    Assert ((Wait-TargetSuccessDrain $directory) -eq 'all_success_terminal') 'Drain did not wait for pending SUCCESS'
    Assert ($calls -contains 'sleep:/1000') 'Pending drain did not poll'
    $states.Enqueue(@{successAccepted=1;successPending=1;successDeadlineViolations=0;latestSuccessPendingDeadline=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')})
    Assert ((Wait-TargetSuccessDrain $directory) -eq 'deadline_reached') 'Drain exceeded actual deadline'
    Set-Content "$directory/result.json" '{"status":"failed"}'
    $calls.Clear(); $caught=$null
    try { Remove-TargetWarmup $directory } catch { $caught=$_ }
    Assert ($caught -and $calls.Count -eq 0) 'Failed warmup reached cleanup'
    Set-Content "$directory/result.json" '{"status":"passed"}'
    Set-Content "$directory/fixture.json" '{"sale":{"id":"00000000-0000-0000-0000-000000000001"}}'
    foreach ($invalid in @($null,0,-1,'272.5','bad')) {
        @{metrics=@{target_started=@{values=@{count=$invalid}}}} | ConvertTo-Json -Depth 5 | Set-Content "$directory/k6-summary.json"
        $calls.Clear(); $caught=$null
        try { Remove-TargetWarmup $directory } catch { $caught=$_ }
        Assert ($caught -and $calls.Count -eq 0) 'Invalid actual count reached cleanup'
    }
    Set-Content "$directory/k6-summary.json" '{"metrics":{"target_started":{"values":{"count":272}}}}'
    Remove-TargetWarmup $directory
    Assert (($calls -join ',') -eq 'delete,scan,redis-delete') 'Cleanup order must be committed DB delete, then Redis'
    Assert ($cleanupSql -like '*pg_advisory_xact_lock(74190321)*' -and $cleanupSql -like '*count(*) FROM sales)<>1*') 'Missing publisher/foreign-sale guard'
    Assert ($cleanupSql -notmatch 'TRUNCATE' -and $cleanupSql -match "DELETE FROM orders WHERE sale_id='00000000-0000-0000-0000-000000000001'") 'Cleanup not scoped to warmup sale'
    Assert (([regex]::Matches($cleanupSql,'<>272')).Count -eq 3 -and $cleanupSql -notmatch '270') 'Cleanup must check all orders, confirmations and attempts against actual arrivals'
    # Execute the actual orchestrator tail with trial/cleanup boundaries mocked.
    $text=Get-Content "$PSScriptRoot/target.ps1" -Raw
    $from=$text.IndexOf('    $warmupConfig=@{} + $config')
    $to=$text.IndexOf('} catch {',$from)
    $orchestrate=[scriptblock]::Create($text.Substring($from,$to-$from))
    function Invoke-TargetTrial($TrialConfig,$TrialDirectory) {
        $calls.Add($TrialConfig.scenario)
        if ($TrialConfig.scenario -eq 'priming') {
            Assert ($TrialConfig.iterations -eq 1 -and $TrialConfig.vus -eq 1) 'Priming must be one serial transaction'
            if ($failPriming) { throw 'priming failed' }
        }
        if ($TrialConfig.scenario -eq 'warmup') {
            Assert ($TrialConfig.stock -eq 400 -and $TrialConfig.users -eq 270 -and $TrialConfig.vus -eq 40) 'Wrong fixed warmup config'
            if ($failWarmup) { throw 'warmup failed' }
        }
    }
    function Remove-TargetWarmup($path) { $calls.Add('cleanup') }
    $config=@{stock=1000;users=50000;vus=100;scenario='worker'}; $runId='offline'
    $Scenario='worker'; $failWarmup=$false; $failPriming=$false; $calls.Clear(); & $orchestrate
    Assert (($calls -join ',') -eq 'priming,cleanup,warmup,cleanup,worker') 'Embedded warmup ordering changed'
    $failWarmup=$true; $calls.Clear(); $caught=$null
    try { & $orchestrate } catch { $caught=$_ }
    Assert ($caught -and ($calls -join ',') -eq 'priming,cleanup,warmup') 'Warmup failure reached measurement'
    $Scenario='warmup'; $failWarmup=$false; $calls.Clear(); & $orchestrate
    Assert (($calls -join ',') -eq 'priming,cleanup,warmup') 'Standalone warmup ordering changed'
    $failPriming=$true; $calls.Clear(); $caught=$null
    try { & $orchestrate } catch { $caught=$_ }
    Assert ($caught -and ($calls -join ',') -eq 'priming') 'Priming failure reached cleanup/warmup'
    'Offline priming/warmup/cleanup/drain checks passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($directory)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^target-warmup-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
