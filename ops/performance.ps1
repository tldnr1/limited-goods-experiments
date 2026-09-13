#requires -Version 7.0
param(
    [ValidateSet('Check','Prepare','Run')][string]$Action = 'Check',
    [ValidateSet('baseline','gate','target')][string]$Mode = 'baseline',
    [ValidateSet('purchase-spike','capacity','warmup','worker','waiting','waiting-join','reservation','isolation','business')][string]$Scenario = 'purchase-spike',
    [int]$OpeningRps = 0,
    [int]$TailRps = 0,
    [int]$Rps = 0,
    [int]$Stock = 10000,
    [int]$DurationSeconds = 60,
    [switch]$Diagnostics,
    [ValidateSet('normal','burst','late-payment','abandon','retry','pg-failure')][string]$Variant = 'normal',
    [int]$Users = 50000,
    [int]$PaymentRps = 40,
    [int]$Vus = 100,
    [int]$MaxVus = 2000,
    [int]$WaitingRate = 25,
    [int]$ReservationRate = 25,
    [int]$Permits = 8,
    [ValidateRange(0,5000)][int]$MockPgDelayMs = 0,
    [int]$Seed = 20260911,
    [switch]$Reset
)
if ($Mode -eq 'target') {
    $targetParameters = @{} + $PSBoundParameters
    $targetParameters.Remove('Mode')
    & (Join-Path $PSScriptRoot 'performance/target.ps1') @targetParameters
    return
}
if ($Scenario -notin @('purchase-spike','capacity')) { throw 'Target 시나리오에는 -Mode target이 필요합니다.' }
if ($Reset) { throw '-Reset은 -Mode target -Action Run 전용입니다.' }
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
$compose = @('compose','--env-file','ops/perf.env','--profile','observe')
$runDir = $null
$prepared = $false
$startedAt = [DateTimeOffset]::UtcNow
$savedEnvironment = @{}
$observer = $null
$progressObserver = $null
$observationStart = $null
. (Join-Path $PSScriptRoot 'perf-diagnostics.ps1')
. (Join-Path $PSScriptRoot 'performance/purchase-warmup.ps1')
. (Join-Path $PSScriptRoot 'performance/capacity.ps1')

function Invoke-Docker {
    param([string[]]$Arguments)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "docker 명령 실패 (exit=$LASTEXITCODE): $($Arguments -join ' ')" }
}

function Prepare-Performance {
    $targetApps = Invoke-Docker -Arguments @('ps','--filter','label=com.docker.compose.project=limited-goods-java',
        '--format','{{.Names}}') | Where-Object { $_ -match '-(reservation|payment|checkout-nginx)-' }
    if ($targetApps) { throw 'Target 역할이 실행 중입니다. ops/target.ps1 -Action Stop 후 baseline 실험을 준비하세요.' }
    $activeLoad = Invoke-Docker -Arguments @('ps','--filter','name=^/goods-k6$','-q')
    if ($activeLoad) { throw 'goods-k6가 실행 중입니다. 기존 실험을 먼저 종료하세요.' }
    & (Join-Path $root 'gradlew.bat') --no-daemon bootJar
    if ($LASTEXITCODE -ne 0) { throw 'JAR 빌드 실패' }
    Invoke-Docker -Arguments ($compose + @('build','api1'))
    Invoke-Docker -Arguments ($compose + @('stop'))
    # First boot also migrates a fresh perf database; no volume removal.
    Invoke-Docker -Arguments ($compose + @('up','-d','--wait','--wait-timeout','240'))
    & (Join-Path $PSScriptRoot 'reset-db.ps1') -Environment perf
    Invoke-Docker -Arguments ($compose + @('up','-d','--wait','--wait-timeout','240'))
    & (Join-Path $PSScriptRoot 'check-health.ps1') | Out-Null
    foreach ($service in @('api1','api2','worker','mock-pg')) {
        $id = Invoke-Docker -Arguments ($compose + @('ps','-q',$service))
        $container = @( (Invoke-Docker -Arguments @('inspect',$id)) | ConvertFrom-Json )[0]
        if ($container.Config.Env -notcontains 'DB_URL=jdbc:postgresql://postgres:5432/limited_goods_perf' -or
            $container.Config.Env -notcontains "ADMISSION_ENABLED=$env:ADMISSION_ENABLED") {
            throw "$service 실제 실행 환경이 요청한 perf/$Mode와 다릅니다."
        }
    }
}

function Save-Snapshot {
    param([string]$Label)
    Invoke-Docker -Arguments ($compose + @('ps','-a')) | Set-Content "$runDir/$Label-containers.txt" -Encoding utf8
    $ids = @(Invoke-Docker -Arguments ($compose + @('ps','-q')))
    Invoke-Docker -Arguments (@('stats','--no-stream','--format','{{json .}}') + $ids) |
        Set-Content "$runDir/$Label-resources.jsonl" -Encoding utf8
    foreach ($service in @('api1','api2','worker','mock-pg','postgres')) {
        Invoke-Docker -Arguments ($compose + @('exec','-T',$service,'cat','/sys/fs/cgroup/cpu.stat')) |
            Set-Content "$runDir/$Label-$service-cpu-stat.txt" -Encoding utf8
    }
    Get-Content (Join-Path $PSScriptRoot 'invariants.sql') |
        & docker @compose exec -T postgres psql -v ON_ERROR_STOP=1 -U goods -d limited_goods_perf |
        Set-Content "$runDir/$Label-db.txt" -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'DB 결과 수집 실패' }
    $arguments = $compose + @('exec','-T','postgres','psql','-v','ON_ERROR_STOP=1','-U','goods','-d',
        'limited_goods_perf','-c','SELECT sale_id,total,available,held,sold FROM sale_items ORDER BY sale_id,id')
    Invoke-Docker -Arguments $arguments | Set-Content "$runDir/$Label-inventory.txt" -Encoding utf8
}

Push-Location $root
try {
    if ($Action -eq 'Run') {
        if ($Scenario -eq 'capacity') {
            if ($Rps -le 0 -or $DurationSeconds -le 0 -or $DurationSeconds -gt 3600 -or
                $Stock -gt 1000000 -or $Stock -lt [Math]::Ceiling([double]$Rps * $DurationSeconds * 1.1) + 1) {
                throw 'capacity: 양수 Rps, DurationSeconds 1~3600, Stock >= ceil(Rps*DurationSeconds*1.1)+1 (최대 1000000)이 필요합니다.'
            }
            if ($OpeningRps -ne 0 -or $TailRps -ne 0) { throw 'capacity는 OpeningRps/TailRps 대신 Rps를 사용합니다.' }
        } elseif ($OpeningRps -le 0 -or $TailRps -le 0 -or $Rps -ne 0 -or
            $PSBoundParameters.ContainsKey('Stock') -or $PSBoundParameters.ContainsKey('DurationSeconds')) {
            throw 'purchase-spike는 양수 OpeningRps/TailRps만 사용합니다. Rps/Stock/DurationSeconds는 capacity 전용입니다.'
        }
    }
    if ($Action -eq 'Check') {
        Invoke-Docker -Arguments @('compose','config','--quiet')
        & (Join-Path $PSScriptRoot 'check-health.ps1') | ConvertTo-Json -Depth 5
        return
    }
    # Restore inherited shell settings when the command ends.
    foreach ($name in @('APP_ENV','DB_NAME','ADMISSION_ENABLED','MSYS_NO_PATHCONV','PURCHASE_TIMING_LOG_LEVEL')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    }
    $env:APP_ENV='perf'
    $env:DB_NAME='limited_goods_perf'
    $env:ADMISSION_ENABLED=if ($Mode -eq 'gate') { 'true' } else { 'false' }
    $env:MSYS_NO_PATHCONV='1'
    $env:PURCHASE_TIMING_LOG_LEVEL=if ($Diagnostics) { 'INFO' } else { 'OFF' }
    if ($Action -eq 'Run') {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $runDir = Join-Path $root "artifacts/performance/$stamp-$Mode-$Scenario"
        New-Item -ItemType Directory -Path $runDir -ErrorAction Stop | Out-Null
        [ordered]@{ status='preparing'; mode=$Mode; scenario=$Scenario; openingRps=$OpeningRps; tailRps=$TailRps;
            rps=$Rps; stock=$(if ($Scenario -eq 'capacity') { $Stock } else { 1000 });
            durationSeconds=$(if ($Scenario -eq 'capacity') { $DurationSeconds } else { 60 });
            orderProgressSeconds=$(if ($Scenario -eq 'capacity') { 1 } else { $null });
            dbWaitSampleMilliseconds=$(if ($Diagnostics) { 100 } else { $null });
            warmupRps=10; warmupSeconds=30;
            diagnostics=[bool]$Diagnostics; prometheusScrapeSeconds=1;
            startedAt=$startedAt.ToString('o') } | ConvertTo-Json | Set-Content "$runDir/run.json" -Encoding utf8
        git rev-parse HEAD | Set-Content "$runDir/commit.txt" -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw 'Git revision 조회 실패' }
        git diff HEAD | Set-Content "$runDir/working-tree.patch" -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw 'Git diff 조회 실패' }
        git status --short | Set-Content "$runDir/git-status.txt" -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw 'Git 상태 조회 실패' }
    }
    Prepare-Performance
    $prepared = $true
    if ($Action -eq 'Prepare') {
        Write-Output "perf/$Mode 준비 완료. 구매 요청과 부하는 발생시키지 않았습니다."
        return
    }
    Invoke-Docker -Arguments ($compose + @('config')) | Set-Content "$runDir/compose.yaml" -Encoding utf8
    Copy-Item ops/nginx.conf,ops/prometheus.yml -Destination $runDir
    $ids = @(Invoke-Docker -Arguments ($compose + @('ps','-q')))
    (Invoke-Docker -Arguments (@('inspect') + $ids) | ConvertFrom-Json) |
        Select-Object Name,@{Name='Networks';Expression={$_.NetworkSettings.Networks}} |
        ConvertTo-Json -Depth 8 | Set-Content "$runDir/container-network-map.json" -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $root "k6/$Scenario.js") -Destination "$runDir/scenario.js"
    Copy-Item -LiteralPath (Join-Path $root 'k6/lib') -Destination "$runDir/lib" -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'performance/purchase-state.sql') -Destination $runDir
    Get-FileHash build/libs/limited-goods.jar | Select-Object Algorithm,Hash |
        ConvertTo-Json | Set-Content "$runDir/jar-hash.json" -Encoding utf8
    Invoke-WebRequest 'http://127.0.0.1:9090/-/ready' -TimeoutSec 5 | Out-Null
    $targetsReady = $false
    for ($i=0; $i -lt 8; $i++) {
        $upQuery = [Uri]::EscapeDataString('up{job="goods"}')
        $up = Invoke-RestMethod "http://127.0.0.1:9090/api/v1/query?query=$upQuery" -TimeoutSec 5
        $targets = @($up.data.result)
        if ($up.status -eq 'success' -and $targets.Count -eq 3 -and
            @($targets | Where-Object { $_.value[1] -ne '1' }).Count -eq 0) {
            $targetsReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $targetsReady) { throw 'Prometheus의 API 2개/Worker 수집 준비 미완료. 부하는 시작하지 않았습니다.' }
    Copy-Item -LiteralPath (Join-Path $root 'k6/warmup.js') -Destination "$runDir/warmup.js"
    Save-Snapshot -Label 'pre-warmup'
    $poolsBefore = @(Get-PurchasePools)
    $poolsBefore | ConvertTo-Json | Set-Content "$runDir/warmup-pools-before.json" -Encoding utf8
    $observationStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Diagnostics) {
        $observer = Start-DbObserver -Directory $runDir
        Wait-DbObserver -Observer $observer
    }
    [ordered]@{ observationStart=$observationStart; warmupStart=[DateTimeOffset]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content "$runDir/phases.json" -Encoding utf8
    Write-Output '워밍업: 별도 판매, 10 RPS × 30초'
    $warmupArguments = @('run','--rm','--name','goods-k6','--cpus','1.5','--memory','1g',
        '--mount',"type=bind,source=$root/k6,target=/scripts,readonly",
        '--mount',"type=bind,source=$runDir,target=/results",
        'grafana/k6:0.54.0','run','--summary-export=/results/warmup-summary.json',
        '--out','json=/results/warmup-raw.json','/scripts/warmup.js')
    & docker @warmupArguments 2>&1 | Tee-Object -FilePath "$runDir/warmup.log"
    $warmupExit = $LASTEXITCODE
    Set-Content "$runDir/warmup-exit-code.txt" $warmupExit -Encoding utf8
    $phases = Get-Content "$runDir/phases.json" -Raw | ConvertFrom-Json
    $phases | Add-Member -NotePropertyName warmupEnd -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))
    $phases | ConvertTo-Json | Set-Content "$runDir/phases.json" -Encoding utf8
    if ($warmupExit -ne 0) { throw '워밍업 실패. 본 측정은 실행하지 않았습니다.' }
    Stop-DbObserver -Observer $observer
    $observer = $null
    Wait-PurchaseWarmup -Directory $runDir -PoolsBefore $poolsBefore
    Save-Snapshot -Label 'before'
    $measuredSeconds = if ($Scenario -eq 'capacity') { $DurationSeconds } else { 60 }
    if ($Scenario -eq 'capacity') {
        $measuredPoolsBefore = @(Get-PurchasePools)
        $measuredPoolsBefore | ConvertTo-Json | Set-Content "$runDir/measured-pools-before.json" -Encoding utf8
        $warmupEvidence = Get-Content "$runDir/warmup-evidence.json" -Raw | ConvertFrom-Json
        $progressObserver = Start-DbObserver -Directory $runDir -SampleCount ($measuredSeconds + 120) `
            -SqlPath (Join-Path $PSScriptRoot 'performance/order-progress.sql') -Label 'order-progress' -ExcludeSaleId $warmupEvidence.saleId
        Wait-DbObserver -Observer $progressObserver
    }
    if ($Diagnostics) {
        $observer = Start-DbObserver -Directory $runDir -SampleCount (($measuredSeconds + 120) * 10) -Label 'measured-db-waits'
        Wait-DbObserver -Observer $observer
    }
    $loadStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $phases | Add-Member -NotePropertyName loadStart -NotePropertyValue $loadStart
    $phases | ConvertTo-Json | Set-Content "$runDir/phases.json" -Encoding utf8
    if ($Scenario -eq 'capacity') { Write-Output "실제 부하 시작: $Mode / capacity $Rps RPS × $DurationSeconds 초, 재고 $Stock" }
    else { Write-Output "실제 부하 시작: $Mode / $OpeningRps RPS 10초 → $TailRps RPS 50초" }
    $arguments = @('run','--rm','--name','goods-k6','--cpus','1.5','--memory','1g',
        '--mount',"type=bind,source=$root/k6,target=/scripts,readonly",
        '--mount',"type=bind,source=$runDir,target=/results",
        '-e',"OPENING_RPS=$OpeningRps",'-e',"TAIL_RPS=$TailRps",
        '-e',"RPS=$Rps",'-e',"STOCK=$Stock",'-e',"DURATION_SECONDS=$DurationSeconds",
        'grafana/k6:0.54.0','run','--summary-export=/results/summary.json','--out','json=/results/raw.json',
        "/scripts/$Scenario.js")
    & docker @arguments 2>&1 | Tee-Object -FilePath "$runDir/k6.log"
    $k6Exit = $LASTEXITCODE
    Set-Content "$runDir/exit-code.txt" $k6Exit -Encoding utf8
    $phases | Add-Member -NotePropertyName loadFinished -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $phases | ConvertTo-Json | Set-Content "$runDir/phases.json" -Encoding utf8
    # Save failed-run evidence, but never retry or advance to another experiment.
    if ($k6Exit -eq 0) { Start-Sleep -Seconds 30 }
    Stop-DbObserver -Observer $progressObserver
    $progressObserver = $null
    Stop-DbObserver -Observer $observer
    $observer = $null
    $capacityFailure = $null
    if ($Scenario -eq 'capacity') {
        try { Save-CapacityResult -Directory $runDir -PoolsBefore $measuredPoolsBefore }
        catch { $capacityFailure = $_ }
    }
    Save-Snapshot -Label 'after'
    $loadEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $phases | Add-Member -NotePropertyName loadEnd -NotePropertyValue $loadEnd
    $phases | ConvertTo-Json | Set-Content "$runDir/phases.json" -Encoding utf8
    Save-Prometheus -Directory $runDir -Start $observationStart -End $loadEnd
    if ($capacityFailure -and $k6Exit -ne 0) { $capacityFailure | Out-String | Add-Content "$runDir/collection-errors.txt" }
    if ($k6Exit -ne 0) { throw "k6 실패 (exit=$k6Exit). 후속 실험은 실행하지 않았습니다." }
    if ($capacityFailure) { throw $capacityFailure }
    $manifest = Get-Content "$runDir/run.json" -Raw | ConvertFrom-Json
    $manifest.status = 'collected'
    $manifest | Add-Member -NotePropertyName completedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))
    $manifest | ConvertTo-Json | Set-Content "$runDir/run.json" -Encoding utf8
    Write-Output "기록 완료: $runDir (목표 합격 여부는 별도 판단)"
} catch {
    if ($runDir) {
        $_ | Out-String | Set-Content "$runDir/error.txt" -Encoding utf8
        $manifest = Get-Content "$runDir/run.json" -Raw | ConvertFrom-Json
        $manifest.status = 'failed'
        $manifest | ConvertTo-Json | Set-Content "$runDir/run.json" -Encoding utf8
    }
    throw
} finally {
    if ($progressObserver) {
        try { Stop-DbObserver -Observer $progressObserver }
        catch { $_ | Out-String | Add-Content "$runDir/collection-errors.txt"; Write-Warning $_ }
    }
    if ($observer) {
        try { Stop-DbObserver -Observer $observer }
        catch { $_ | Out-String | Add-Content "$runDir/collection-errors.txt"; Write-Warning $_ }
    }
    if ($observationStart -and -not (Test-Path "$runDir/prometheus.json")) {
        # A failed warmup must retain evidence too; do not replace the original failure.
        try { Save-Snapshot -Label 'failed' }
        catch { $_ | Out-String | Add-Content "$runDir/collection-errors.txt"; Write-Warning $_ }
        try { Save-Prometheus -Directory $runDir -Start $observationStart -End ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
        catch { $_ | Out-String | Add-Content "$runDir/collection-errors.txt"; Write-Warning $_ }
    }
    if ($runDir -and $prepared) {
        & docker @compose logs --no-color --since $startedAt.ToString('o') > "$runDir/services.log"
        if ($LASTEXITCODE -ne 0) { Write-Warning '서비스 로그 저장 실패' }
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')
    }
    Pop-Location
}
