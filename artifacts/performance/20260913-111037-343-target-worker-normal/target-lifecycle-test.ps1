#requires -Version 7.0
# Executes copies of the real scripts in a disposable workspace with Docker/HTTP/Git mocked.
# The build command is a no-op batch file; Run always stops before fixture HTTP and k6.
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "target-lifecycle-$([Guid]::NewGuid().ToString('N'))"
$calls=[System.Collections.Generic.List[string]]::new()
$mockRunning=@{}
$mockApps=@('nginx','checkout-nginx','api1','api2','reservation','payment','worker','mock-pg')
$mockServices=$mockApps+@('postgres','redis','prometheus')
$mockMode='healthy'
$mockScrapes=0
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function git { $global:LASTEXITCODE=0; 'offline-revision' }
function docker {
    $arguments=@($args)
    $command=$arguments -join ' '
    $calls.Add($command)
    $global:LASTEXITCODE=0
    Assert ((Get-Location).Path -eq $testRoot) 'Wrong Compose working directory'
    if ($arguments[0] -eq 'ps') {
        if ($command -like '*label=com.docker.compose.project*') {
            return @($mockServices | Where-Object { $mockRunning[$_] } | ForEach-Object { "limited-goods-java-$_-1" })
        }
        if ($mockMode -eq 'active-load') { return 'existing-k6' }
        return
    }
    if ($arguments[0] -eq 'image') { return 'image-id' }
    if ($arguments[0] -eq 'inspect') {
        $profiles=@{api1='waiting';api2='waiting';reservation='reservation';payment='payment';worker='worker';'mock-pg'='mockpg'}
        $info=foreach ($id in $arguments[1..($arguments.Count-1)]) {
            $service=$id -replace '^id-',''
            @{Id=$id;State=@{Running=[bool]$mockRunning[$service];Health=@{Status='healthy'}};Config=@{Env=@(
                'DB_URL=jdbc:postgresql://postgres:5432/limited_goods_perf','REDIS_NAMESPACE=goods:perf:',
                "SPRING_PROFILES_ACTIVE=$($profiles[$service])",'APP_WAITING_RATE=25','RESERVATION_RATE=25','ADMISSION_PERMITS=8','MOCK_PG_DELAY_MS=0')}}
        }
        return ConvertTo-Json -InputObject @($info) -Depth 6
    }
    if ($arguments[0] -eq 'exec') {
        if ($command -like '*pg_stat_activity*') { return '0' }
        if ($command -like '*SLOWLOG*') { return }
    }
    if ($arguments[0] -eq 'compose') {
        if ($arguments -contains 'ps') {
            if ($mockRunning[$arguments[-1]]) { return "id-$($arguments[-1])" }
            return
        }
        if ($arguments -contains 'config') { if ($arguments -notcontains '--quiet') { return 'services: {}' }; return }
        if ($arguments -contains 'build') {
            if ($mockMode -eq 'build-failure') { $global:LASTEXITCODE=23 }
            return
        }
        if ($arguments -contains 'stop') {
            if ($mockMode -eq 'stop-failure') { $global:LASTEXITCODE=23; return }
            foreach ($service in $mockApps) { $mockRunning[$service]=$false }
            return
        }
        if ($arguments -contains 'up') {
            Assert ($arguments -contains '--no-build' -and $arguments -contains '--wait') 'Unsafe start flags'
            if ($mockMode -eq 'start-failure') { $global:LASTEXITCODE=23; return }
            foreach ($service in $mockServices) { $mockRunning[$service]=$true }
            return
        }
        if ($arguments -contains 'logs') { return 'offline-log' }
        if ($arguments -contains 'psql') {
            if ($command -like '*select current_database()*') { return 'limited_goods_perf' }
            $sql=($input | Out-String)
            if ($sql -like '*TRUNCATE*') {
                Assert (@($mockApps | Where-Object { $mockRunning[$_] }).Count -eq 0) 'Reset raced with running apps'
                $calls.Add('TRUNCATE perf')
                if ($mockMode -eq 'reset-failure') { $global:LASTEXITCODE=23 }
                return
            }
            if ($sql -like '*SELECT count(*) FROM sales*') { return $(if ($mockMode -eq 'existing-data') {'1'} else {'0'}) }
            if ($mockMode -eq 'snapshot-failure') { $global:LASTEXITCODE=23; return }
            $calls.Add($(if ($sql -like '*inventoryViolations*') {'SNAPSHOT state'} else {'SNAPSHOT timeline'}))
            return '{}'
        }
        if ($arguments -contains 'redis-cli') {
            if ($arguments -contains '--scan') { return 'goods:perf:offline-key' }
            if ($arguments -contains 'DEL') { Assert ($arguments[-1] -like 'goods:perf:*') 'Wrong namespace'; return '1' }
        }
    }
    throw "Unexpected command; real Docker is never invoked: $command"
}
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$Method,$ContentType,$Body)
    if ($Method -eq 'Post') { $calls.Add('FIXTURE boundary'); throw 'OFFLINE_BOUNDARY' }
    Assert ($Uri -like 'http://127.0.0.1:9090/api/v1/query?query=*') 'Unexpected HTTP'
    $script:mockScrapes++
    $count=if ($mockMode -eq 'scrape-lag' -and $mockScrapes -eq 1) {5} else {6}
    return @{status='success';data=@{result=@(1..$count | ForEach-Object { @{value=@(0,'1')} })}}
}
function Start-Sleep { param($Seconds) $calls.Add('SCRAPE wait'); Assert ($Seconds -eq 1) 'Unexpected real wait path' }
function Invoke-Case([hashtable]$Parameters,[string]$ExpectedError='') {
    $calls.Clear()
    $caught=$null
    try { & "$testRoot/ops/performance.ps1" -Mode target @Parameters | Out-Null } catch { $caught=$_ }
    if ($ExpectedError) { Assert ($caught -and "$caught" -like "*$ExpectedError*") "Expected '$ExpectedError', got '$caught'" }
    else { Assert (-not $caught) "Unexpected failure: $caught" }
}
function Count-Commands([string]$pattern) { @($calls | Where-Object { $_ -like $pattern }).Count }
try {
    foreach ($path in @('ops/performance','k6/target','build/libs','artifacts/performance')) {
        New-Item -ItemType Directory -Path "$testRoot/$path" -Force | Out-Null
    }
    Copy-Item "$sourceRoot/ops/performance.ps1","$sourceRoot/ops/reset-db.ps1" "$testRoot/ops"
    Copy-Item "$PSScriptRoot/target.ps1","$PSScriptRoot/target-trial.ps1","$PSScriptRoot/target-hikari.ps1","$PSScriptRoot/target-warmup-cleanup.ps1","$PSScriptRoot/target-state.sql","$PSScriptRoot/target-timeline.sql" "$testRoot/ops/performance"
    Set-Content "$testRoot/gradlew.bat" '@exit /b 0'
    Set-Content "$testRoot/build/libs/limited-goods.jar" 'offline-jar'
    Set-Content "$testRoot/k6/target/offline.js" '// Never executed'
    foreach ($service in $mockServices) { $mockRunning[$service]=$false }
    $mockMode='scrape-lag'
    Invoke-Case @{Action='Prepare'}
    Assert ((Count-Commands 'SCRAPE wait') -eq 1) 'Prepare did not tolerate initial scrape lag'
    $mockMode='healthy'
    Assert ((Count-Commands '* build api1') -eq 1 -and (Count-Commands '* up *') -eq 1) 'Prepare must build/start once'
    Assert ((Count-Commands '* stop *') -eq 1 -and (Count-Commands 'TRUNCATE*') -eq 0) 'Prepare must preserve data'

    $run=@{Action='Run';Reset=$true;Scenario='worker';Rps=10;DurationSeconds=30}
    Invoke-Case $run 'OFFLINE_BOUNDARY'
    Assert ((Count-Commands '* build *') -eq 0 -and (Count-Commands '* up *') -eq 1) 'Repeat run rebuilt or started twice'
    Assert ((Count-Commands '* stop *') -eq 1 -and (Count-Commands 'TRUNCATE*') -eq 1) 'Repeat run must stop/reset once'
    Assert ($calls.IndexOf('SNAPSHOT state') -lt $calls.IndexOf('TRUNCATE perf') -and
        $calls.IndexOf('SNAPSHOT timeline') -lt $calls.IndexOf('TRUNCATE perf')) 'Reset preceded evidence capture'
    Assert ((Count-Commands '*--pull never*') -eq 1) 'Repeat run can pull images'
    Assert ((Count-Commands 'FIXTURE boundary') -eq 1) 'Run failed before measurement boundary'
    Invoke-Case @{Action='Run';Reset=$true;Scenario='warmup'} 'OFFLINE_BOUNDARY'
    Assert ((Count-Commands 'FIXTURE boundary') -eq 1 -and (Count-Commands '* up *') -eq 1) 'Standalone warmup lifecycle changed'

    $mockMode='existing-data'
    Invoke-Case @{Action='Run';Scenario='worker';Rps=10} 'Run -Reset'
    Assert ((Count-Commands '* stop *') -eq 0) 'Bare Run reset existing data'
    $mockMode='healthy'
    Invoke-Case @{Action='Run';Reset=$true;Rps=0} '잘못된 부하'
    Assert ($calls.Count -eq 0) 'Invalid workload reached Docker'
    Invoke-Case @{Action='Check';Reset=$true} 'Run 전용'
    Assert ($calls.Count -eq 0) 'Check -Reset reached Docker'

    $mockMode='active-load'
    Invoke-Case $run '실행 중'
    Assert ((Count-Commands '* stop *') -eq 0) 'Active load was interrupted'
    $mockMode='healthy'
    $lock=[IO.File]::Open("$testRoot/artifacts/performance/.target.lock",'Open','ReadWrite','None')
    try { Invoke-Case $run '결과 수집'; Assert ($calls.Count -eq 0) 'Collection lock was ignored' }
    finally { $lock.Dispose() }

    $mockMode='build-failure'
    Invoke-Case @{Action='Prepare'} 'exit=23'
    Assert ((Count-Commands '* stop *') -eq 0 -and (Count-Commands '* up *') -eq 0) 'Failed build interrupted apps'

    foreach ($failure in @('stop-failure','snapshot-failure','reset-failure','start-failure')) {
        foreach ($service in $mockServices) { $mockRunning[$service]=$true }
        $mockMode=$failure
        Invoke-Case $run $(switch ($failure) {
            'snapshot-failure' {'perf SQL failed'}
            'reset-failure' {'초기화 실패'}
            default {'exit=23'}
        })
        Assert ((Count-Commands 'FIXTURE boundary') -eq 0) "$failure still started fixture/load"
        if ($failure -in @('stop-failure','snapshot-failure')) { Assert ((Count-Commands 'TRUNCATE*') -eq 0) 'Failure still cleared data' }
        if ($failure -ne 'start-failure') { Assert ((Count-Commands '* up *') -eq 0) 'Failure still restarted apps' }
        # Lock must be released even after a failed reset/collector.
        $probe=[IO.File]::Open("$testRoot/artifacts/performance/.target.lock",'Open','ReadWrite','None'); $probe.Dispose()
    }
    $mockMode='healthy'
    foreach ($service in $mockServices) { $mockRunning[$service]=$false }
    $mockRunning.api1=$true
    $calls.Clear()
    $caught=$null
    Push-Location $testRoot
    try { & "$testRoot/ops/reset-db.ps1" -Environment perf -AppsStopped | Out-Null } catch { $caught=$_ }
    finally { Pop-Location }
    Assert ($caught -and "$caught" -like '*모든 앱이 중단*' -and (Count-Commands 'TRUNCATE*') -eq 0) 'AppsStopped bypassed running-app guard'
    '14 offline lifecycle checks passed (no Docker, real HTTP, k6, build, or waits).'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^target-lifecycle-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
