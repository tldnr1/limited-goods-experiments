# Offline evidence tests. No database, HTTP, Docker, or k6 calls.
$ErrorActionPreference='Stop'
$directory=Join-Path ([IO.Path]::GetTempPath()) "target-review-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $directory | Out-Null
$checks=0
function Json($value,$name) { $value | ConvertTo-Json -Depth 20 | Set-Content "$directory/$name" }
function Verify($expected) {
    $script:checks++
    & "$PSScriptRoot/target-review.ps1" -Directory $directory | Out-Null
    $result=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if ($result.status -ne $expected) { throw "Expected $expected, got $($result | ConvertTo-Json -Depth 6)" }
}
function Boundary($value,$name,$time) {
    Json @{metric='hikaricp_connections_timeout_total';boundaryRequestedAt=$time;timestamp=$time+1;
        series=@('reservation:8080','payment:8080','worker:8080','mock-pg:8080' | ForEach-Object { @{instance=$_;pool='HikariPool-1';value=$value;scrapedAt=$time+0.5} })} $name
}
try {
    Boundary 0 'boundary-before.json' 1799999998
    Boundary 0 'boundary-after.json' 1800000061
    Json @{scenario='worker';variant='normal';mockPgDelayMs=0;rps=40;durationSeconds=60} 'config.json'
    Json @{status='collected';measurementStart=1800000000;arrivalEnd=1800000060} 'phases.json'
    $state=@{at='2027-01-15T08:00:01Z';inventoryViolations=0;userLimitViolations=0;holdViolations=0;duplicateSuccess=0;waitingDbConnections=0;confirmed=2400;succeeded=2400;pending=0;failed=0;oldestPendingSeconds=0;successAccepted=2400;successConfirmed=2400;successPending=0;successDeadlineViolations=0;terminalEvidenceMissing=0}
    Json $state 'after-db.json'; Json $state 'before-db.json'
    $state | ConvertTo-Json -Compress | Set-Content "$directory/db-samples.jsonl"
    $state.at='2027-01-15T08:00:50Z'
    $state | ConvertTo-Json -Compress | Add-Content "$directory/db-samples.jsonl"
    $metrics=@{}
    foreach ($name in @('target_started','target_finished','target_payment_accepted')) { $metrics[$name]=@{values=@{count=2400}} }
    $metrics.target_payment_accepted_ms=@{thresholds=@{'p(95)<=1000'=@{ok=$true}}}
    $metrics['target_unexpected{endpoint:payment_accept}']=@{thresholds=@{'rate==0'=@{ok=$true}}}
    $metrics.target_payment_rejected=@{thresholds=@{'rate==0'=@{ok=$true}}}
    $metrics.target_unexpected=@{thresholds=@{'rate<=0.001'=@{ok=$true}}}
    $metrics.dropped_iterations=@{thresholds=@{'count==0'=@{ok=$true}}}
    Json @{metrics=$metrics} 'k6-summary.json'
    Set-Content "$directory/k6-exit.txt" '0'
    foreach ($name in @('redis-samples.jsonl','resources.jsonl','timeline.json')) { Set-Content "$directory/$name" '{}' }
    $container=@{Id='app';Name='worker';RestartCount=0;State=@{Running=$true;OOMKilled=$false}}
    Json @($container) 'before-containers.json'; Json @($container) 'after-containers.json'
    $series=@(1..6 | ForEach-Object { @{metric=@{__name__='up';instance="app$_"};values=@(@(1800000000,'1'),@(1800000060,'1'))} })
    $series+=@(1..6 | ForEach-Object { @{metric=@{__name__='process_start_time_seconds';instance="app$_"};values=@(@(1800000000,'1700000000'),@(1800000060,'1700000000'))} })
    $series+=@(1..4 | ForEach-Object { @{metric=@{__name__='hikaricp_connections_timeout_total';instance="pool$_"};values=@(@(1800000000,'0'),@(1800000060,'0'))} })
    Json @{status='success';data=@{result=$series}} 'prometheus.json'
    Verify 'requires_review' # Even complete evidence must not auto-declare capacity success.
    $state.confirmed=2404; $state.succeeded=2404
    Json $state 'after-db.json'
    Verify 'failed'
    $mismatch=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if (-not ($mismatch.issues -like '*HTTP/DB payment count mismatch*') -or
        ($mismatch.issues -like '*remain pending*')) { throw 'Response loss was misreported as unfinished Worker jobs' }
    $state.confirmed=2400; $state.succeeded=2400; Json $state 'after-db.json'
    $paymentThreshold=$metrics.target_payment_accepted_ms
    $metrics.Remove('target_payment_accepted_ms')
    Json @{metrics=$metrics} 'k6-summary.json'
    Verify 'failed'
    $metrics.target_payment_accepted_ms=$paymentThreshold
    $metrics.dropped_iterations.thresholds=@{}
    Json @{metrics=$metrics} 'k6-summary.json'
    Verify 'failed'
    $metrics.dropped_iterations.thresholds=@{'count==0'=@{ok=$true}}
    Json @{metrics=$metrics} 'k6-summary.json'
    $state.pending=1
    Json $state 'after-db.json'
    Verify 'failed'
    $state.pending=0; Json $state 'after-db.json'
    $metrics.target_payment_accepted_ms.thresholds.'p(95)<=1000'.ok=$false
    Json @{metrics=$metrics} 'k6-summary.json'
    Verify 'failed'
    $metrics.target_payment_accepted_ms.thresholds.'p(95)<=1000'.ok=$true
    Json @{metrics=$metrics} 'k6-summary.json'
    # A-F: range remains flat throughout; only explicit boundary is authoritative.
    $series[-1].values[0][1]='1'; $series[-1].values[-1][1]='1'
    Json @{status='success';data=@{result=$series}} 'prometheus.json'
    foreach ($case in @(@(0,0,'requires_review'),@(0,1,'failed'),@(3,3,'requires_review'),@(3,4,'failed'),@(3,2,'failed'))) {
        Boundary $case[0] 'boundary-before.json' 1799999998
        Boundary $case[1] 'boundary-after.json' 1800000061
        Verify $case[2]
        if ($case[2] -eq 'failed') {
            $latest=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
            if (-not ($latest.issues -like '*Hikari timeout boundary delta*')) { throw 'Boundary regression did not detect delta' }
        }
    }
    Boundary 0 'boundary-before.json' 1799999998
    Boundary 0 'boundary-after.json' 1800000061
    $boundary=Get-Content "$directory/boundary-after.json" -Raw | ConvertFrom-Json
    $boundary.series[0].pool='replacement-pool'; Json $boundary 'boundary-after.json'; Verify 'failed'
    $boundary.series[0].pool='HikariPool-1'; $boundary.series=$boundary.series[0..2]
    Json $boundary 'boundary-after.json'; Verify 'failed'
    Boundary 0 'boundary-after.json' 1800000061
    # A wider diagnostic range must not override this trial's stable boundary.
    $series[-1].values[-1][1]='2'
    Json @{status='success';data=@{result=$series}} 'prometheus.json'
    Verify 'requires_review'
    Remove-Item -LiteralPath "$directory/boundary-after.json"
    Verify 'failed'
    Boundary 0 'boundary-after.json' 1800000061
    $metrics.target_payment_ms=@{values=@{'p(95)'=9000}}
    Json @{metrics=$metrics} 'k6-summary.json'
    Verify 'requires_review'
    $state.successDeadlineViolations=1
    Json $state 'after-db.json'
    Verify 'failed'
    $state.successDeadlineViolations=0; $state.successPending=1
    Json $state 'after-db.json'
    Verify 'failed'
    $state.successPending=0; Json $state 'after-db.json'
    $latest=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if ($latest.manualReview -match '32/s required|40/s normal target') { throw 'Legacy Worker contract remains' }
    # Sale opens 100 seconds BEFORE measurement; a measurement-relative check would incorrectly pass.
    Json @{scenario='business';variant='normal';mockPgDelayMs=0;users=2400;stock=1} 'config.json'
    Json @{status='collected';saleStart=1799999900;measurementStart=1800000000;arrivalEnd=1800000060} 'phases.json'
    $metrics.target_held=@{values=@{count=1}}
    $metrics.target_purchase_accepted_ms=@{thresholds=@{'p(99)<=1000'=@{ok=$true}}}
    foreach ($endpoint in @('waiting_join','waiting_poll')) {
        $metrics["target_latency{endpoint:$endpoint}"]=@{thresholds=@{'p(99)<=1000'=@{ok=$true}}}
        $metrics["target_unexpected{endpoint:$endpoint}"]=@{thresholds=@{'rate==0'=@{ok=$true}}}
    }
    Json @{metrics=$metrics} 'k6-summary.json'
    $state.orders=1; Json $state 'after-db.json'
    Json @{orders=@(@{created_at='2027-01-15T08:00:01Z'});payments=@(@{status='SUCCEEDED';terminal_at='2027-01-15T08:00:30Z'})} 'timeline.json'
    Verify 'failed'
    $latest=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if (-not ($latest.issues -like '*saleStart +60*') -or -not ($latest.issues -like '*saleStart +120*')) { throw 'Business ignored saleStart' }
    Json @{status='collected';saleStart=1800000000;measurementStart=1800000000;arrivalEnd=1800000060} 'phases.json'
    Verify 'requires_review'
    $latest=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if (-not ($latest.manualReview -like '*Scaled flow/harness validation*')) { throw 'Scaled run claimed 50k SLO' }
    foreach ($count in @(2400,2401,2402,2403,2404,2399)) {
        $metrics.target_started.values.count=$count; $metrics.target_finished.values.count=$count
        Json @{metrics=$metrics} 'k6-summary.json'
        Verify $(if ($count -ge 2400 -and $count -le 2403) {'requires_review'} else {'failed'})
    }
    Json @{scenario='business';variant='abandon';mockPgDelayMs=0;users=2400;stock=1} 'config.json'
    foreach ($count in @(2405,2406)) {
        $metrics.target_started.values.count=$count; $metrics.target_finished.values.count=$count
        Json @{metrics=$metrics} 'k6-summary.json'
        Verify $(if ($count -eq 2405) {'requires_review'} else {'failed'})
    }
    Json @{scenario='isolation';variant='normal';mockPgDelayMs=0;rps=20;paymentRps=20;durationSeconds=60} 'config.json'
    foreach ($count in @(2402,2403)) {
        $metrics.target_started.values.count=$count; $metrics.target_finished.values.count=$count
        Json @{metrics=$metrics} 'k6-summary.json'
        Verify $(if ($count -eq 2402) {'requires_review'} else {'failed'})
    }
    # Warmup validates safety/durability, not capacity latency. Accumulated stable counters are allowed.
    Json @{scenario='warmup';variant='normal';mockPgDelayMs=0;users=270} 'config.json'
    foreach ($name in @('target_started','target_finished','target_payment_accepted','target_held')) { $metrics[$name]=@{values=@{count=270}} }
    $metrics=@{target_started=$metrics.target_started;target_finished=$metrics.target_finished;target_payment_accepted=$metrics.target_payment_accepted;
        target_held=$metrics.target_held;target_unexpected=@{thresholds=@{'rate==0'=@{ok=$true}}};
        target_payment_rejected=@{thresholds=@{'rate==0'=@{ok=$true}}};dropped_iterations=@{thresholds=@{'count==0'=@{ok=$true}}}}
    Json @{metrics=$metrics} 'k6-summary.json'
    $state.orders=270; $state.attempts=270; $state.confirmed=270; $state.succeeded=270; $state.successAccepted=270; $state.successConfirmed=270
    Json $state 'after-db.json'
    Set-Content "$directory/raw.json" '{"type":"Point","metric":"target_latency","data":{"value":2000,"tags":{"stage":"warmup_3"}}}'
    Add-Content "$directory/raw.json" '{"type":"Point","metric":"target_latency","data":{"value":3000,"tags":{"stage":"warmup_4"}}}'
    $series[-1].values[0][1]='2'; $series[-1].values[-1][1]='2'
    Json @{status='success';data=@{result=$series}} 'prometheus.json'
    Verify 'passed'
    Boundary 1 'boundary-after.json' 1800000061
    Verify 'failed' # Warmup receives the identical hard delta check.
    Boundary 3 'boundary-before.json' 1799999998
    Boundary 3 'boundary-after.json' 1800000061
    Verify 'passed'
    # Actual arrivals, including the observed 272, must all reach durable confirmation.
    foreach ($count in @(269,270,271,272,273,274,275)) {
        foreach ($name in @('target_started','target_finished','target_payment_accepted','target_held')) { $metrics[$name].values.count=$count }
        foreach ($field in @('orders','attempts','confirmed','succeeded','successAccepted','successConfirmed')) { $state[$field]=$count }
        Json @{metrics=$metrics} 'k6-summary.json'; Json $state 'after-db.json'
        Verify $(if ($count -ge 270 -and $count -le 274) {'passed'} else {'failed'})
    }
    foreach ($name in @('target_started','target_finished','target_payment_accepted','target_held')) { $metrics[$name].values.count=272 }
    foreach ($field in @('orders','attempts','confirmed','succeeded','successAccepted','successConfirmed')) { $state[$field]=272 }
    Json @{metrics=$metrics} 'k6-summary.json'; Json $state 'after-db.json'
    foreach ($name in @('target_finished','target_held','target_payment_accepted')) {
        $metrics[$name].values.count=271; Json @{metrics=$metrics} 'k6-summary.json'; Verify 'failed'
        $metrics[$name].values.count=272
    }
    Json @{metrics=$metrics} 'k6-summary.json'
    foreach ($field in @('orders','attempts','confirmed','succeeded','successAccepted','successConfirmed')) {
        $state[$field]=271; Json $state 'after-db.json'; Verify 'failed'; $state[$field]=272
    }
    Json $state 'after-db.json'
    $metrics.dropped_iterations.thresholds.'count==0'.ok=$false
    Json @{metrics=$metrics} 'k6-summary.json'; Verify 'failed'
    $metrics.dropped_iterations.thresholds.'count==0'.ok=$true
    Json @{metrics=$metrics} 'k6-summary.json'
    Boundary 4 'boundary-after.json' 1800000061
    Verify 'failed' # Extra legitimate arrivals never excuse a Hikari timeout.
    Boundary 3 'boundary-after.json' 1800000061
    $metrics.target_unexpected.thresholds.'rate==0'.ok=$false
    Json @{metrics=$metrics} 'k6-summary.json'
    Verify 'failed'
    # 20260912 warmup: valid arrival count, but real acceptance/Hikari failures remain failures.
    $metrics.target_payment_accepted.values.count=254
    foreach ($field in @('attempts','confirmed','succeeded','successAccepted','successConfirmed')) { $state[$field]=258 }
    Json @{metrics=$metrics} 'k6-summary.json'; Json $state 'after-db.json'
    Boundary 0 'boundary-before.json' 1799999998
    Boundary 18 'boundary-after.json' 1800000061
    Verify 'failed'
    $latest=Get-Content "$directory/result.json" -Raw | ConvertFrom-Json
    if (($latest.issues -like '*Actual arrivals differ*') -or
        -not ($latest.issues -like '*every actual arrival*') -or
        -not ($latest.issues -like '*Hikari timeout boundary delta*')) { throw 'Observed 272-arrival failure was misclassified' }
    Remove-Item -LiteralPath "$directory/prometheus.json"
    Verify 'failed'
    "$checks offline result-review checks passed."
} finally {
    # Delete only this test's newly created, resolved temporary directory.
    $resolved=[IO.Path]::GetFullPath($directory)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^target-review-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
