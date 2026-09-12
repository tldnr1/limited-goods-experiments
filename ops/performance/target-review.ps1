# Offline review only; never calls Docker, HTTP, k6, or changes the database.
param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/target-hikari.ps1"
$issues=[System.Collections.Generic.List[string]]::new()
$review=[System.Collections.Generic.List[string]]::new()
$capacity=$null
$warmupWindows=@()
$alignment=$null
function Read-Json([string]$Name) { Get-Content (Join-Path $Directory $Name) -Raw | ConvertFrom-Json }
function Require([bool]$Condition,[string]$Message) { if (-not $Condition) { $issues.Add($Message) } }
try {
    foreach ($name in @('boundary-before.json','boundary-after.json','config.json','phases.json','k6-summary.json','k6-exit.txt','before-db.json','after-db.json','db-samples.jsonl','redis-samples.jsonl','resources.jsonl','prometheus.json','before-containers.json','after-containers.json','timeline.json')) {
        Require (Test-Path "$Directory/$name") "Missing evidence: $name"
    }
    foreach ($name in @('error.txt','collection-errors.txt','observer-error.txt')) { Require (-not (Test-Path "$Directory/$name")) "Run/collection error: $name" }
    if ($issues.Count -eq 0) {
        $config=Read-Json 'config.json'; $summary=Read-Json 'k6-summary.json'; $state=Read-Json 'after-db.json'; $phases=Read-Json 'phases.json'
        Require ((Get-Content "$Directory/k6-exit.txt") -eq '0') 'k6 exited nonzero'
        Require ($phases.status -eq 'collected') 'Measurement did not finish'
        foreach ($field in @('inventoryViolations','userLimitViolations','holdViolations','duplicateSuccess','waitingDbConnections','successDeadlineViolations','terminalEvidenceMissing')) {
            Require ($null -ne $state.$field -and $state.$field -eq 0) "$field must be zero"
        }
        $normal=$config.variant -eq 'normal' -and $config.mockPgDelayMs -eq 0
        Require ($null -ne $config.mockPgDelayMs) 'Missing MockPgDelayMs environment evidence'
        $warmup=$config.scenario -eq 'warmup'
        $priming=$config.scenario -eq 'priming'
        $preparation=$warmup -or $priming
        $requiredThresholds=@{dropped_iterations='count==0'}
        if ($priming) { $requiredThresholds.Remove('dropped_iterations') }
        if ($preparation) { $requiredThresholds.target_unexpected='rate==0' }
        elseif ($normal) { $requiredThresholds.target_unexpected='rate<=0.001' }
        if ($normal -and -not $preparation) {
            if ($config.scenario -in @('worker','isolation','business')) {
                $requiredThresholds.target_payment_accepted_ms='p(95)<=1000'
                $requiredThresholds['target_unexpected{endpoint:payment_accept}']='rate==0'
            }
            if ($config.scenario -in @('reservation','business')) { $requiredThresholds.target_purchase_accepted_ms='p(99)<=1000' }
            if ($config.scenario -in @('waiting','business')) {
                foreach ($endpoint in @('waiting_join','waiting_poll')) {
                    $requiredThresholds["target_latency{endpoint:$endpoint}"]='p(99)<=1000'
                    $requiredThresholds["target_unexpected{endpoint:$endpoint}"]='rate==0'
                }
            }
        }
        if ($config.scenario -in @('priming','warmup','worker','isolation')) { $requiredThresholds.target_payment_rejected='rate==0' }
        if ($config.scenario -eq 'business' -and $config.variant -ne 'late-payment') { $requiredThresholds.target_payment_rejected='rate==0' }
        foreach ($entry in $requiredThresholds.GetEnumerator()) {
            Require ($summary.metrics.($entry.Key).thresholds.($entry.Value).ok -eq $true) "Missing/failed threshold: $($entry.Key): $($entry.Value)"
        }
        foreach ($metric in $summary.metrics.PSObject.Properties) {
            if ($metric.Name -ne 'target_payment_ms' -and $metric.Value.thresholds) {
                foreach ($threshold in $metric.Value.thresholds.PSObject.Properties) { Require ($threshold.Value.ok -eq $true) "$($metric.Name): $($threshold.Name)" }
            }
        }
        $started=$summary.metrics.target_started.values.count
        $finished=$summary.metrics.target_finished.values.count
        Require ($null -ne $started -and $started -gt 0 -and $started -eq $finished) 'Missing/interrupted browser/payment iterations'
        $expected=if ($priming) {$config.iterations} elseif ($warmup) {
            if ($config.warmupStages) { ($config.warmupStages | ForEach-Object { $_.rate*$_.durationSeconds } | Measure-Object -Sum).Sum }
            else { $config.users } # Historical artifacts recorded planned users before stages were saved.
        } elseif ($config.scenario -eq 'business') { $config.users+$(if ($config.variant -eq 'abandon') {$config.stock} else {0}) }
            elseif ($config.scenario -eq 'isolation') { ($config.rps+$config.paymentRps)*$config.durationSeconds }
            else { $config.rps*$config.durationSeconds }
        # constant-arrival-rate can include one extra arrival at each scenario boundary.
        # Retain the lower bound and dropped=0; never hide missing work behind a percentage tolerance.
        $tolerance=if ($priming) {0} elseif ($warmup) {if ($config.warmupStages) {@($config.warmupStages).Count} else {4}}
            elseif ($config.scenario -eq 'business') {if ($config.variant -eq 'abandon') {4} else {3}} elseif ($config.scenario -eq 'isolation') {2} else {1}
        Require ($null -ne $expected -and $expected -gt 0) 'Missing configured arrival count'
        Require ($started -ge $expected -and $started -le $expected+$tolerance) "Actual arrivals differ from configured workload: expected=$expected..$($expected+$tolerance), started=$started"
        $held=$summary.metrics.target_held.values.count
        $accepted=$summary.metrics.target_payment_accepted.values.count
        if ($config.scenario -in @('priming','warmup','worker','isolation')) {
            Require ($accepted -gt 0) 'No payment acceptance observed by client'
            Require ($state.confirmed -eq $accepted -and $state.succeeded -eq $accepted) "HTTP/DB payment count mismatch: accepted=$accepted, confirmed=$($state.confirmed), succeeded=$($state.succeeded). Check response loss/retries."
            Require ($state.pending -eq 0 -and $state.failed -eq 0) 'Payment attempts remain pending or failed after drain'
        }
        if ($config.scenario -in @('priming','warmup','reservation','business')) { Require ($held -gt 0 -and $state.orders -eq $held) 'No purchases or HTTP/DB order count mismatch' }
        Require ($null -ne $state.successAccepted -and $null -ne $state.successConfirmed -and $null -ne $state.successPending) 'Missing SUCCESS deadline state'
        Require ($state.successPending -eq 0) 'SUCCESS pending remains after bounded drain'
        Require ($state.successAccepted -eq $state.successConfirmed) 'Accepted SUCCESS did not become CONFIRMED'
        if ($preparation) {
            Require ($held -eq $started -and $accepted -eq $started -and $state.orders -eq $started -and $state.attempts -eq $started -and $state.confirmed -eq $started) "Preparation must durably confirm every actual arrival: started=$started, held=$held, accepted=$accepted, orders=$($state.orders), attempts=$($state.attempts), confirmed=$($state.confirmed)"
            Require (Test-Path "$Directory/raw.json") 'Missing preparation raw evidence'
        }
        if ($warmup -and $config.primed) {
            Require (Test-Path "$Directory/priming/cleanup-completed.txt") 'Priming cleanup missing'
            $prime=Read-Json 'priming/result.json'
            Require ($prime.status -eq 'passed') 'Priming failed; warmup cannot pass'
        }
        if ($config.scenario -eq 'waiting') { Require ($state.orders -eq 0 -and $state.attempts -eq 0) 'Waiting created durable orders/payments' }
        $samples=@(Get-Content "$Directory/db-samples.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
        Require ($samples.Count -ge $(if ($priming) {1} else {2})) 'Insufficient DB samples'
        foreach ($sample in $samples) {
            foreach ($field in @('inventoryViolations','userLimitViolations','holdViolations','duplicateSuccess','waitingDbConnections','successDeadlineViolations','terminalEvidenceMissing')) { Require ($null -ne $sample.$field -and $sample.$field -eq 0) "Observed/missing $field at $($sample.at)" }
        }
        $window=@($samples | Where-Object {
            $t=([DateTimeOffset]$_.at).ToUnixTimeMilliseconds()/1000
            $t -ge $phases.measurementStart -and $t -le $phases.arrivalEnd
        })
        if ($window.Count -ge 2) {
            $first=$window[0]; $last=$window[-1]
            $seconds=([DateTimeOffset]$last.at-[DateTimeOffset]$first.at).TotalSeconds
            $capacity=@{sampleSeconds=$seconds;confirmedPerSecond=($last.confirmed-$first.confirmed)/$seconds;acceptedPerSecond=($last.attempts-$first.attempts)/$seconds;backlogSlope=($last.pending-$first.pending)/$seconds;maxPending=($window.pending | Measure-Object -Maximum).Maximum;maxOldestSeconds=($window.oldestPendingSeconds | Measure-Object -Maximum).Maximum}
        } else { $review.Add('Supply window has fewer than two samples; no capacity estimate.') }
        if ($config.scenario -eq 'business') {
            Require ($null -ne $phases.saleStart) 'Business saleStart missing'
            $alignment=$phases.measurementStart-$phases.saleStart
            $review.Add("Business measurementStart minus saleStart: $alignment seconds; inspect harness alignment independently of service latency.")
            if ($normal) {
                $timeline=Read-Json 'timeline.json'
                $heldBy60=@($timeline.orders | Where-Object { ([DateTimeOffset]$_.created_at).ToUnixTimeMilliseconds()/1000 -le $phases.saleStart+60 }).Count
                $confirmedBy120=@($timeline.payments | Where-Object { $_.status -eq 'SUCCEEDED' -and $_.terminal_at -and
                    ([DateTimeOffset]$_.terminal_at).ToUnixTimeMilliseconds()/1000 -le $phases.saleStart+120 }).Count
                Require ($heldBy60 -ge $config.stock) 'Initial stock not fully held by saleStart +60 seconds'
                Require ($confirmedBy120 -ge [Math]::Ceiling($config.stock*0.95)) '95% stock not CONFIRMED by saleStart +120 seconds'
            }
            if ($config.users -ne 50000 -or $config.stock -ne 1000) { $review.Add('Scaled flow/harness validation: cannot claim the 50,000-user / 1,000-stock SLO.') }
        }
        if ($warmup -and (Test-Path "$Directory/raw.json")) {
            $raw=@(Get-Content "$Directory/raw.json" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'Point' -and $_.metric -eq 'target_latency' })
            foreach ($stage in @(3,4)) {
                $values=@($raw | Where-Object { $_.data.tags.stage -eq "warmup_$stage" } | ForEach-Object { [double]$_.data.value } | Sort-Object)
                $from=$phases.measurementStart+($stage-1)*10; $to=$from+10
                $backlog=@($samples | Where-Object { $t=([DateTimeOffset]$_.at).ToUnixTimeMilliseconds()/1000; $t -ge $from -and $t -lt $to })
                $warmupWindows+=@{stage="warmup_$stage";httpSamples=$values.Count;p95=$(if ($values.Count) {$values[[Math]::Ceiling($values.Count*0.95)-1]} else {$null});p99=$(if ($values.Count) {$values[[Math]::Ceiling($values.Count*0.99)-1]} else {$null});backlog=@($backlog | Select-Object at,pending,oldestPendingSeconds)}
            }
        }
        $before=@(Read-Json 'before-containers.json'); $after=@(Read-Json 'after-containers.json')
        foreach ($container in $before) {
            $current=@($after | Where-Object Id -eq $container.Id)
            Require ($current.Count -eq 1 -and $current[0].RestartCount -eq $container.RestartCount -and -not $current[0].State.OOMKilled -and $current[0].State.Running) "Container changed/restarted/stopped/OOM: $($container.Name)"
        }
        $prom=Read-Json 'prometheus.json'
        Require ($prom.status -eq 'success') 'Prometheus query failed'
        $up=@($prom.data.result | Where-Object { $_.metric.__name__ -eq 'up' })
        Require ($up.Count -eq 6) 'Missing Prometheus targets'
        $hikariBefore=Read-Json 'boundary-before.json'; $hikariAfter=Read-Json 'boundary-after.json'
        $beforeMap=Get-TargetHikariMap $hikariBefore; $afterMap=Get-TargetHikariMap $hikariAfter
        Require ($hikariAfter.boundaryRequestedAt -ge $hikariBefore.timestamp) 'Hikari boundary order invalid'
        foreach ($key in $beforeMap.Keys) {
            Require ($afterMap.ContainsKey($key)) "Hikari series mismatch: $key"
            if ($afterMap.ContainsKey($key)) {
                $delta=$afterMap[$key].value-$beforeMap[$key].value
                Require ($delta -eq 0) "Hikari timeout boundary delta must be zero (increase/reset): $key delta=$delta"
            }
        }
        $starts=@($prom.data.result | Where-Object { $_.metric.__name__ -eq 'process_start_time_seconds' })
        Require ($starts.Count -eq 6) 'Missing process evidence'
        foreach ($series in $prom.data.result) {
            if ($series.metric.__name__ -eq 'up') { Require (@($series.values | Where-Object { $_[1] -ne '1' }).Count -eq 0) "Scrape failure: $($series.metric.instance)" }
            if ($series.metric.__name__ -eq 'process_start_time_seconds') {
                Require ($series.values[0][1] -eq $series.values[-1][1]) "Process restart: $($series.metric.instance)"
            }
        }
    }
} catch { $issues.Add("Review incomplete: $_") }
$review.Add('Inspect per-endpoint/status p95/p99, 429/503, READY versus actual purchase rate, Redis latency/CPU, DB lock/Hikari and generator resources.')
$review.Add('Sustained capacity needs stable backlog/age within the supply window and 3 independent trials; drain alone is insufficient. Worker contract is SUCCESS confirmation deadlines and recovering backlog, not fixed jobs/s.')
$review.Add('For return/late/PG scenarios inspect timeline and state samples. Sampled projection timing is not an exact release-event timestamp; do not certify <=5s from coarse samples.')
$result=@{status=$(if ($issues.Count) {'failed'} elseif ($config.scenario -in @('priming','warmup')) {'passed'} else {'requires_review'});automatedChecksPassed=($issues.Count -eq 0);issues=@($issues);capacity=$capacity;saleAlignmentSeconds=$alignment;warmupWindows=$warmupWindows;manualReview=@($review)}
$result | ConvertTo-Json -Depth 10 | Set-Content "$Directory/result.json"
$result | ConvertTo-Json -Depth 10
