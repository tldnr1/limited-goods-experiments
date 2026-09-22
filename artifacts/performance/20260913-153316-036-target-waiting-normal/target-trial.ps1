. "$PSScriptRoot/target-hikari.ps1"

function Get-TargetScriptPath([string]$Scenario) {
    switch ($Scenario) {
        'waiting' { 'waiting-v2/unused-ready.js' }
        'waiting-join' { 'waiting-v2/join.js' }
        default { "$Scenario.js" }
    }
}

function Wait-TargetSuccessDrain([string]$directory,[int]$InitialDelaySeconds=30) {
    # Keep the baseline observation window, then bound SUCCESS drain by actual DB deadlines.
    if ($InitialDelaySeconds -gt 0) { Start-Sleep -Seconds $InitialDelaySeconds }
    $drainDeadline=$null
    do {
        if (Test-Path "$directory/observer-error.txt") { throw 'Observer failed during drain' }
        $state=Sql (Get-Content "$PSScriptRoot/target-state.sql" -Raw) | ConvertFrom-Json
        if ($state.successDeadlineViolations -gt 0) { return 'deadline_reached' }
        if ($state.successAccepted -eq 0) { return 'no_payment_work' }
        if ($state.successPending -eq 0) { return 'all_success_terminal' }
        if (-not $state.latestSuccessPendingDeadline) { throw 'Missing SUCCESS pending deadline' }
        if ($null -eq $drainDeadline) { $drainDeadline=[DateTimeOffset]$state.latestSuccessPendingDeadline }
        $remaining=($drainDeadline-[DateTimeOffset]::UtcNow).TotalSeconds
        if ($remaining -le 0) { return 'deadline_reached' }
        if ($remaining -gt 71) { throw 'SUCCESS deadline exceeds the 70-second contract' }
        Start-Sleep -Milliseconds ([int][Math]::Min(1000,[Math]::Max(1,$remaining*1000)))
    } while ($true)
}

# One priming, warmup or measured trial; lifecycle/reset is owned by target.ps1.
function Invoke-TargetTrial([hashtable]$TrialConfig,[string]$TrialDirectory) {
    $directory=$TrialDirectory
    $Scenario=$TrialConfig.scenario; $Variant=$TrialConfig.variant
    $scriptPath=Get-TargetScriptPath $Scenario
    $TrialConfig.scriptPath=$scriptPath
    $Stock=$TrialConfig.stock; $DurationSeconds=$TrialConfig.durationSeconds
    $Rps=$TrialConfig.rps; $PaymentRps=$TrialConfig.paymentRps; $runId=$TrialConfig.runId
    $observer=$null; $loadStarted=$null; $loadExit=$null
    $generatorName=if ($Scenario -in @('priming','warmup')) {'goods-target-warmup-k6'} else {'goods-target-k6'}
    New-Item -ItemType Directory -Force $directory | Out-Null
    Save-Json $TrialConfig "$directory/config.json"
    Copy-Item (Join-Path $root 'k6/target') -Destination "$directory/scripts" -Recurse
    try {
    Save-Json (Invoke-Docker (@('inspect')+@($ids.Values)) | ConvertFrom-Json) "$directory/before-containers.json"
    $previous=if ($Scenario -eq 'warmup' -and $TrialConfig.primed) {"$directory/priming"}
        elseif ($Scenario -notin @('priming','warmup')) {"$directory/warmup"} else {$null}
    if ($previous) {
        if (-not (Test-Path "$previous/cleanup-completed.txt")) { throw 'Preparation cleanup missing; next trial prohibited' }
        $warmed=@(Get-Content "$previous/after-containers.json" -Raw | ConvertFrom-Json)
        $current=@(Get-Content "$directory/before-containers.json" -Raw | ConvertFrom-Json)
        foreach ($prior in $warmed) {
            $same=@($current | Where-Object Id -eq $prior.Id)
            if ($same.Count -ne 1 -or $same[0].RestartCount -ne $prior.RestartCount -or $same[0].State.StartedAt -ne $prior.State.StartedAt) {
                throw 'Container restarted/replaced after preparation; next trial prohibited'
            }
        }
    }
    # Fixture sales and held orders are setup, excluded from the measured arrival window.
    $saleBody=@{name="target-$runId";opensAt=[DateTimeOffset]::UtcNow.AddSeconds($(if ($Scenario -eq 'business') {30} else {-10})).ToString('o');items=@(@{name='goods';price=10000;total=$Stock;perUserLimit=1})}
    $sale=Invoke-RestMethod 'http://127.0.0.1:8082/api/sales' -Method Post -ContentType 'application/json' -Body ($saleBody | ConvertTo-Json -Depth 5) -TimeoutSec 5
    $orders=@()
    if ($Scenario -in @('worker','isolation')) {
        $count=($DurationSeconds * $(if ($Scenario -eq 'worker') { $Rps } else { $PaymentRps }))+1
        if ($count -gt 1000000) { throw 'Payment fixture exceeds maximum stock' }
        $saleBody.name="payment-$runId"; $saleBody.items[0].total=$count
        $paymentSale=Invoke-RestMethod 'http://127.0.0.1:8082/api/sales' -Method Post -ContentType 'application/json' -Body ($saleBody | ConvertTo-Json -Depth 5) -TimeoutSec 5
        $saleId=[Guid]$paymentSale.id; $itemId=[Guid]$paymentSale.items[0].id
        # State-consistent setup only. All measured payment acceptance still goes through Payment API.
        $seedSql=@"
BEGIN;
CREATE TEMP TABLE fixture_orders AS SELECT gen_random_uuid() id,n FROM generate_series(0,$($count-1)) n;
INSERT INTO orders SELECT id,'fixture-'||n,'$saleId','purchase','$saleId' || ':' || '$itemId' || '=1','PAYMENT_PENDING',10000,now() FROM fixture_orders;
INSERT INTO order_items SELECT gen_random_uuid(),id,'$itemId',1,10000 FROM fixture_orders;
INSERT INTO reservations SELECT id,'ACTIVE',now()+interval '300 seconds',NULL FROM fixture_orders;
UPDATE sale_items SET available=0,held=total WHERE id='$itemId';
SELECT json_agg(json_build_object('id',id,'user','fixture-'||n) ORDER BY n) FROM fixture_orders;
COMMIT;
"@
        $orders=@(Sql $seedSql | ConvertFrom-Json)
    }
    Save-Json @{sale=$sale} "$directory/fixture.json"
    ConvertTo-Json -InputObject @($orders) -Depth 5 | Set-Content "$directory/orders.json" -Encoding utf8
    # Bounded readiness check, not a workload: projection must exist before measurement.
    $projected=$false
    for ($i=0;$i -lt 10;$i++) {
        $value=Invoke-Docker @('exec',$ids.redis,'redis-cli','GET',"goods:perf:catalog:$($sale.id)")
        if ($value -match ':AVAILABLE$') { $projected=$true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $projected) { throw 'Sale projection not ready' }
    Sql (Get-Content "$PSScriptRoot/target-state.sql" -Raw) | Set-Content "$directory/before-db.json"
    $observationStart=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # -FilePath runs script text without its file context. Invoke the absolute path in the child instead.
    $observer=Start-Job -ScriptBlock {
        param([string]$ObserverPath,[hashtable]$ObserverParameters)
        & $ObserverPath @ObserverParameters
    } -ArgumentList "$PSScriptRoot/target-observe.ps1",@{
        Directory=$directory;Postgres=$ids.postgres;Redis=$ids.redis;Containers=@($ids.Values)
        IntervalSeconds=$(if ($Scenario -in @('business','warmup','priming')) { 1 } else { 5 });GeneratorName=$generatorName
    }
    for ($i=0;$i -lt 20 -and -not (Test-Path "$directory/observer-ready");$i++) {
        if ($observer.State -eq 'Failed' -or (Test-Path "$directory/observer-error.txt")) { throw 'Observer startup failed' }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path "$directory/observer-ready")) { throw 'Observer readiness timed out' }
    $network=@((Invoke-Docker @('inspect',$ids.nginx) | ConvertFrom-Json))[0].NetworkSettings.Networks.PSObject.Properties.Name | Select-Object -First 1
    Save-TargetHikariBoundary "$directory/boundary-before.json"
    $loadStarted=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-Json @{observationStart=$observationStart;dockerStart=$loadStarted;status='running'} "$directory/phases.json"
    $arguments=@('run','--rm','--name',$generatorName,'--network',$network,'--cpus','1.5','--memory','1g',
        '--mount',"type=bind,source=$directory/scripts,target=/scripts,readonly",
        '--mount',"type=bind,source=$directory,target=/results",
        '-e','TARGET_CONFIG=/results/config.json','-e','TARGET_FIXTURE=/results/fixture.json','-e','TARGET_ORDERS=/results/orders.json',
        'grafana/k6:0.54.0','run','--out','json=/results/raw.json',"/scripts/$scriptPath")
    Write-Output "실제 부하: $Scenario / $Variant. 자동 상승/재실행 없음. 결과: $directory"
    & docker @arguments 2>&1 | Tee-Object "$directory/k6.log"
    $loadExit=$LASTEXITCODE
    Set-Content "$directory/k6-exit.txt" $loadExit
    $loadFinished=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $drainReason=if ($Scenario -eq 'priming') { Wait-TargetSuccessDrain $directory -InitialDelaySeconds 0 } else { Wait-TargetSuccessDrain $directory }
    Save-TargetHikariBoundary "$directory/boundary-after.json"
    $match=Select-String -Path "$directory/k6.log" -Pattern 'TARGET_MEASUREMENT_START=(\d+)' | Select-Object -First 1
    if (-not $match) { throw 'k6 measurement boundary missing' }
    $measurementStart=[double]$match.Matches[0].Groups[1].Value / 1000
    if ($Scenario -eq 'priming') { $DurationSeconds=$loadFinished-$measurementStart }
    Save-Json @{observationStart=$observationStart;measurementStart=$measurementStart;saleStart=$([DateTimeOffset]::Parse($sale.opensAt).ToUnixTimeMilliseconds()/1000);arrivalEnd=$measurementStart+$(if ($Scenario -eq 'business') { if ($Variant -eq 'abandon') {360} else {60} } else {$DurationSeconds});drainReason=$drainReason;loadFinished=$loadFinished;drainEnd=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();status='collected'} "$directory/phases.json"
    } catch {
        $_ | Out-String | Set-Content "$directory/error.txt"
        throw
    } finally {
        # Only this trial owns this k6 name; stop it on cancellation before collecting evidence.
        if ($loadStarted -and $null -eq $loadExit) {
            try { Invoke-Docker @('rm','-f',$generatorName) | Out-Null }
            catch { $_ | Out-String | Add-Content "$directory/collection-errors.txt" }
        }
        if ($observer) {
            Set-Content "$directory/stop-observer" 'stop'
            $null=Wait-Job $observer -Timeout 20
            if ($observer.State -in @('Failed','Stopped')) { Add-Content "$directory/collection-errors.txt" "Observer ended unexpectedly: $($observer.State)" }
            if ($observer.State -eq 'Running') { Stop-Job $observer; Add-Content "$directory/collection-errors.txt" 'Observer did not stop cleanly' }
            Receive-Job $observer -ErrorAction Continue 2>&1 | Out-File "$directory/observer.log"
            Remove-Job $observer
        }
        # Preserve each independent piece of evidence even after a run/collection failure.
        $collectors=@{
            'after-db.json'={ Sql (Get-Content "$PSScriptRoot/target-state.sql" -Raw) };
            'timeline.json'={ Sql (Get-Content "$PSScriptRoot/target-timeline.sql" -Raw) };
            'after-containers.json'={ Invoke-Docker (@('inspect')+@($ids.Values)) };
            'redis-slowlog.txt'={ Invoke-Docker @('exec',$ids.redis,'redis-cli','SLOWLOG','GET','128') };
            'services.log'={ Invoke-Docker ($compose+@('logs','--no-color','--since',$(if ($loadStarted) {$loadStarted} else {[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}))) }
        }
        foreach ($entry in $collectors.GetEnumerator()) {
            try { & $entry.Value | Set-Content "$directory/$($entry.Key)" }
            catch { $_ | Out-String | Add-Content "$directory/collection-errors.txt" }
        }
        if ($loadStarted) {
            try {
                $query=[Uri]::EscapeDataString('{job="target",__name__=~"up|goods_.*|hikaricp_.*|process_.*|jvm_.*|http_server_requests_.*"}')
                $end=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                Invoke-WebRequest "http://127.0.0.1:9090/api/v1/query_range?query=$query&start=$observationStart&end=$end&step=1" -TimeoutSec 60 -OutFile "$directory/prometheus.json"
            } catch { $_ | Out-String | Add-Content "$directory/collection-errors.txt" }
            try { & "$PSScriptRoot/target-review.ps1" -Directory $directory }
            catch { $_ | Out-String | Add-Content "$directory/collection-errors.txt" }
        }
    }
if ($loadExit -ne 0 -or (Test-Path "$directory/error.txt") -or (Test-Path "$directory/collection-errors.txt")) { throw "실행/수집 실패. $directory 자료를 확인하세요." }
if ((Get-Content "$directory/result.json" -Raw | ConvertFrom-Json).status -eq 'failed') { throw "자동 검사 실패. $directory/result.json을 확인하세요." }
Write-Output "수집 완료. result.json의 자동 검사와 수동 판정을 함께 확인하세요: $directory"

}
