#requires -Version 7.0
param(
    [ValidateSet('Check','Prepare','Run')][string]$Action='Check',
    [ValidateSet('warmup','worker','waiting','reservation','isolation','business')][string]$Scenario='worker',
    [ValidateSet('normal','burst','late-payment','abandon','retry','pg-failure')][string]$Variant='normal',
    [int]$Rps=0,[int]$DurationSeconds=60,[int]$Stock=1000,[int]$Users=50000,[int]$PaymentRps=40,
    [int]$Vus=100,[int]$MaxVus=2000,[int]$WaitingRate=25,[int]$ReservationRate=25,[int]$Permits=8,
    [ValidateRange(0,5000)][int]$MockPgDelayMs=0,[int]$Seed=20260911,[switch]$Diagnostics,[switch]$Reset
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$compose=@('compose','--env-file','ops/perf.env','-f','compose.yaml','-f','compose.target.yml','-f','ops/performance/target-compose.yml','--profile','observe')
$services=@('api1','api2','reservation','payment','worker','mock-pg')
$apps=@('nginx','checkout-nginx')+$services
$saved=@{}
$directory=$null
$ids=@{}
$executionLock=$null
function Invoke-Docker([string[]]$Arguments) {
    # Keep progress attached to the terminal. Only query callers capture stdout.
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker failed (exit=$LASTEXITCODE): $($Arguments -join ' ')" }
}
function Sql([string]$Statement) {
    $output=$Statement | & docker @compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U goods -d limited_goods_perf
    if ($LASTEXITCODE -ne 0) { throw 'perf SQL failed' }
    return $output
}
function Assert-NoOtherWork {
    foreach ($name in @('goods-k6','goods-target-k6','goods-target-warmup-k6')) {
        if (Invoke-Docker @('ps','--filter',"name=^/$name$",'-q')) { throw "$name 실행 중. 먼저 종료하세요." }
    }
    foreach ($service in $services) {
        $id=Invoke-Docker ($compose+@('ps','-q',$service))
        if ($id) {
            $info=@((Invoke-Docker @('inspect',$id) | ConvertFrom-Json))[0]
            if ($info.Config.Env -notcontains 'DB_URL=jdbc:postgresql://postgres:5432/limited_goods_perf') {
                throw "$service dev/baseline 실행을 먼저 명시적으로 종료하세요. 자동 중단하지 않습니다."
            }
        }
    }
    $postgres=Invoke-Docker ($compose+@('ps','-q','postgres'))
    if ($postgres) {
        $active=Invoke-Docker @('exec',$postgres,'psql','-X','-At','-U','goods','-d','postgres','-c',
            "SELECT count(*) FROM pg_stat_activity WHERE datname IN ('limited_goods_dev','limited_goods_test') AND backend_type='client backend' AND application_name<>'psql'")
        if ([int]$active -gt 0) { throw 'dev/test DB 연결이 있습니다. perf와 동시 실행하지 마세요.' }
    }
}
function Assert-Ready([switch]$WaitForScrape) {
    $profiles=@{api1='waiting';api2='waiting';reservation='reservation';payment='payment';worker='worker';'mock-pg'='mockpg'}
    foreach ($service in ($apps+@('postgres','redis','prometheus'))) {
        $id=Invoke-Docker ($compose+@('ps','-q',$service))
        if (-not $id) { throw "$service 준비 안 됨. Prepare를 먼저 실행하세요." }
        $info=@((Invoke-Docker @('inspect',$id) | ConvertFrom-Json))[0]
        if (-not $info.State.Running -or ($info.State.Health -and $info.State.Health.Status -ne 'healthy')) { throw "$service unhealthy" }
        $ids[$service]=$id
        if ($profiles.ContainsKey($service)) {
            foreach ($setting in @("SPRING_PROFILES_ACTIVE=$($profiles[$service])",'DB_URL=jdbc:postgresql://postgres:5432/limited_goods_perf','REDIS_NAMESPACE=goods:perf:')) {
                if ($info.Config.Env -notcontains $setting) { throw "$service 설정 불일치: $setting" }
            }
        }
        $expected=@()
        if ($service -in @('api1','api2')) { $expected=@("APP_WAITING_RATE=$WaitingRate") }
        if ($service -eq 'reservation') { $expected=@("RESERVATION_RATE=$ReservationRate","ADMISSION_PERMITS=$Permits") }
        if ($service -eq 'mock-pg') { $expected=@("MOCK_PG_DELAY_MS=$MockPgDelayMs") }
        foreach ($setting in $expected) { if ($info.Config.Env -notcontains $setting) { throw "Prepare 설정과 불일치: $setting" } }
    }
    $query=[Uri]::EscapeDataString('up{job="target"}')
    for ($attempt=0;$attempt -lt $(if ($WaitForScrape) {10} else {1});$attempt++) {
        $up=Invoke-RestMethod "http://127.0.0.1:9090/api/v1/query?query=$query" -TimeoutSec 5
        if ($up.status -eq 'success' -and @($up.data.result).Count -eq 6 -and
            @($up.data.result | Where-Object { $_.value[1] -ne '1' }).Count -eq 0) { return }
        if ($WaitForScrape -and $attempt -lt 9) { Start-Sleep -Seconds 1 }
    }
    throw 'Target Prometheus 6개 수집 대상 준비 안 됨'
}
function Save-Json($Value,[string]$Path) { $Value | ConvertTo-Json -Depth 30 | Set-Content $Path -Encoding utf8 }

. (Join-Path $PSScriptRoot 'target-trial.ps1')
. (Join-Path $PSScriptRoot 'target-warmup-cleanup.ps1')
Push-Location $root
try {
    if ($Diagnostics) { throw 'Target은 공통 관측을 항상 수집합니다. baseline -Diagnostics를 혼용하지 마세요.' }
    if ($Reset -and $Action -ne 'Run') { throw '-Reset은 -Action Run 전용입니다.' }
    if ($WaitingRate -lt 1 -or $ReservationRate -lt 1 -or $Permits -lt 1) { throw 'Rate/permit은 양수여야 합니다.' }
    if ($Action -eq 'Run') {
        if ($DurationSeconds -lt 1 -or $DurationSeconds -gt 180 -or $Vus -lt 1 -or $MaxVus -lt $Vus -or $PaymentRps -lt 1 -or
            $Stock -lt 1 -or $Stock -gt 1000000 -or $Users -lt 10 -or $Users -gt 50000 -or $Users % 10 -ne 0 -or
            ($Scenario -notin @('business','warmup') -and ($Rps -lt 1 -or $Rps -gt 100000))) { throw '잘못된 부하 설정. 실행 가이드의 범위를 확인하세요.' }
        if ($Scenario -ne 'business' -and $Variant -ne 'normal' -and -not ($Scenario -in @('waiting','isolation') -and $Variant -eq 'abandon')) {
            throw '이 variant는 Business 전용입니다. Waiting/Isolation은 normal 또는 abandon만 지원합니다.'
        }
        if ($Scenario -eq 'reservation' -and $Stock -lt $Rps*$DurationSeconds) { throw 'Reservation은 전체 유입 이상 재고를 지정하세요.' }
    }
    foreach ($entry in @{DB_NAME='limited_goods_perf';APP_ENV='perf';ADMISSION_ENABLED='true';TARGET_WAITING_RATE="$WaitingRate";TARGET_RESERVATION_RATE="$ReservationRate";TARGET_PERMITS="$Permits";MOCK_PG_DELAY_MS="$MockPgDelayMs"}.GetEnumerator()) {
        $saved[$entry.Key]=[Environment]::GetEnvironmentVariable($entry.Key,'Process')
        [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')
    }
    # Hold through drain and collection too: k6 may have exited while evidence is still being written.
    if ($Action -ne 'Check') {
        $artifactRoot=Join-Path $root 'artifacts/performance'
        New-Item -ItemType Directory -Force $artifactRoot | Out-Null
        try { $executionLock=[IO.File]::Open("$artifactRoot/.target.lock",'OpenOrCreate','ReadWrite','None') }
        catch { throw '다른 Target Prepare/Run 또는 결과 수집이 진행 중입니다.' }
    }
    Assert-NoOtherWork
    Invoke-Docker ($compose+@('config','--quiet'))
    if ($Action -eq 'Prepare') {
        & ./gradlew.bat --no-daemon bootJar
        if ($LASTEXITCODE -ne 0) { throw 'JAR build failed' }
        Invoke-Docker ($compose+@('build','api1'))
        Invoke-Docker ($compose+@('stop')+$apps)
        # Mock PG runs Flyway before Reservation; existing service_healthy dependencies gate the rest.
        Invoke-Docker ($compose+@('up','-d','--no-build','--wait','--wait-timeout','300'))
        Assert-Ready -WaitForScrape
        Write-Output 'Target perf 배포/준비 확인 완료. 데이터를 초기화하거나 부하를 실행하지 않았습니다. 반복 실험은 Run -Reset으로 실행하세요.'
        return
    }
    Assert-Ready
    if ($Action -eq 'Check') { Write-Output 'Target perf 역할/DB/namespace/rate/관측 준비 확인 완료 (읽기 전용).'; return }
    Invoke-Docker @('image','inspect','grafana/k6:0.54.0','--format','{{.Id}}') | Out-Null
    if (-not $Reset -and [int](Sql 'SELECT count(*) FROM sales') -ne 0) { throw '이전 fixture가 있습니다. Run -Reset으로 별도 실험을 시작하세요.' }
    $runId=[Guid]::NewGuid().ToString('N')
    $directory=Join-Path $root "artifacts/performance/$(Get-Date -Format yyyyMMdd-HHmmss-fff)-target-$Scenario-$Variant"
    New-Item -ItemType Directory $directory | Out-Null
    $config=[ordered]@{runId=$runId;scenario=$Scenario;variant=$Variant;rps=$Rps;durationSeconds=$DurationSeconds;stock=$Stock;users=$Users;paymentRps=$PaymentRps;vus=$Vus;maxVus=$MaxVus;waitingRate=$WaitingRate;reservationRate=$ReservationRate;permits=$Permits;seed=$Seed;mockPgDelayMs=$MockPgDelayMs;reset=[bool]$Reset}
    Save-Json $config "$directory/config.json"
    Invoke-Docker ($compose+@('config')) | Set-Content "$directory/compose.yaml"
    git rev-parse HEAD | Set-Content "$directory/commit.txt"
    git diff HEAD | Set-Content "$directory/working-tree.patch"
    git status --short | Set-Content "$directory/git-status.txt"
    Copy-Item ops/performance/target*.ps1,ops/performance/target*.sql -Destination $directory
    Get-FileHash build/libs/limited-goods.jar | Select-Object Algorithm,Hash | ConvertTo-Json | Set-Content "$directory/jar-hash.json"
    if ($Reset) {
        Invoke-Docker @('image','inspect','limited-goods-java:local','--format','{{.Id}}') | Out-Null
        Invoke-Docker ($compose+@('stop')+$apps)
        # Preserve the previous durable state before deleting it. A failed capture aborts reset.
        Sql (Get-Content "$PSScriptRoot/target-state.sql" -Raw) | Set-Content "$directory/pre-reset-db.json"
        Sql (Get-Content "$PSScriptRoot/target-timeline.sql" -Raw) | Set-Content "$directory/pre-reset-timeline.json"
        & ./ops/reset-db.ps1 -Environment perf -AppsStopped
        if (-not $?) { throw 'perf reset failed' }
        Invoke-Docker ($compose+@('up','-d','--no-build','--pull','never','--wait','--wait-timeout','300'))
        Assert-Ready -WaitForScrape
    }
    $warmupConfig=@{} + $config
    $warmupConfig.scenario='warmup'; $warmupConfig.variant='normal'
    $warmupConfig.warmupStages=@(2,5,10,10 | ForEach-Object { @{rate=$_;durationSeconds=10} })
    $warmupConfig.users=($warmupConfig.warmupStages | ForEach-Object { $_.rate*$_.durationSeconds } | Measure-Object -Sum).Sum
    $warmupConfig.durationSeconds=($warmupConfig.warmupStages.durationSeconds | Measure-Object -Sum).Sum
    $warmupConfig.stock=[Math]::Max(400,$warmupConfig.users+$warmupConfig.warmupStages.Count)
    $warmupConfig.vus=40; $warmupConfig.maxVus=40; $warmupConfig.primed=$true
    $warmupConfig.rps=10; $warmupConfig.runId="$runId-warmup"
    $warmupDirectory=if ($Scenario -eq 'warmup') {$directory} else {Join-Path $directory 'warmup'}
    $primingConfig=@{} + $config
    $primingConfig.scenario='priming'; $primingConfig.variant='normal'; $primingConfig.iterations=1
    $primingConfig.stock=$primingConfig.iterations; $primingConfig.users=$primingConfig.iterations
    $primingConfig.durationSeconds=180; $primingConfig.vus=1; $primingConfig.maxVus=1
    $primingConfig.runId="$runId-priming"
    $primingDirectory=Join-Path $warmupDirectory 'priming'
    Invoke-TargetTrial $primingConfig $primingDirectory
    Remove-TargetWarmup $primingDirectory
    if ($Scenario -eq 'warmup') {
        Invoke-TargetTrial $warmupConfig $directory
    } else {
        Invoke-TargetTrial $warmupConfig $warmupDirectory
        Remove-TargetWarmup $warmupDirectory
        # No up/restart/reset after this boundary. Keep all warmed JVMs running.
        Invoke-TargetTrial (@{} + $config) $directory
    }
} catch {
    if ($directory) { $_ | Out-String | Set-Content "$directory/error.txt" }
    throw
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') }
    if ($executionLock) { $executionLock.Dispose() }
    Pop-Location
}
