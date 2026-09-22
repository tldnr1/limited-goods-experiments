#requires -Version 7.0
# Offline command routing tests. Docker and HTTP are mocked; never uses Prepare/Run.
$ErrorActionPreference='Stop'
$target=Join-Path $PSScriptRoot 'target.ps1'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null; $parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
if ($ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq 'docker' },$true)) {
    throw 'A function named Docker shadows the native docker command (case-insensitive recursion).'
}
$calls=[System.Collections.Generic.List[object]]::new()
$mode='healthy'
$expectedRate=25
$expectedDelay=0
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function docker {
    # Any command outside this read-only allowlist fails without invoking Docker.
    Assert ((Get-Location).Path -eq $root) 'Docker was called outside the repository root'
    $arguments=@($args)
    $calls.Add($arguments)
    $global:LASTEXITCODE=0
    if ($mode -eq 'docker-failure') { $global:LASTEXITCODE=23; return }
    if ($arguments[0] -eq 'ps') {
        Assert ($arguments[2] -in @('name=^/goods-k6$','name=^/goods-target-k6$','name=^/goods-target-warmup-k6$')) 'Container filter changed'
        return
    }
    if ($arguments[0] -eq 'compose' -and $arguments -contains 'ps') { return "id-$($arguments[-1])" }
    if ($arguments[0] -eq 'compose' -and $arguments[-2] -eq 'config' -and $arguments[-1] -eq '--quiet') { return }
    if ($arguments[0] -eq 'exec' -and $arguments[-1] -like 'SELECT count(*) FROM pg_stat_activity*') { return '0' }
    if ($arguments[0] -eq 'inspect') {
        $service=$arguments[1] -replace '^id-',''
        $profiles=@{api1='waiting';api2='waiting';reservation='reservation';payment='payment';worker='worker';'mock-pg'='mockpg'}
        $db=if ($mode -eq 'dev') { 'limited_goods_dev' } else { 'limited_goods_perf' }
        return ConvertTo-Json -Depth 5 -InputObject @(@{
            State=@{Running=$true;Health=@{Status='healthy'}}
            Config=@{Env=@("DB_URL=jdbc:postgresql://postgres:5432/$db",'REDIS_NAMESPACE=goods:perf:',
                "SPRING_PROFILES_ACTIVE=$($profiles[$service])","APP_WAITING_RATE=$expectedRate",
                'RESERVATION_RATE=25','ADMISSION_PERMITS=8',"MOCK_PG_DELAY_MS=$expectedDelay")}
        })
    }
    throw "Unexpected Docker command in offline Check: $($arguments -join ' ')"
}
function Invoke-RestMethod {
    param($Uri,$TimeoutSec)
    Assert ($Uri -like 'http://127.0.0.1:9090/api/v1/query?query=*') 'Unexpected HTTP call'
    $count=if ($mode -eq 'missing-scrape') { 5 } else { 6 }
    return @{status='success';data=@{result=@(1..$count | ForEach-Object { @{value=@(0,'1')} })}}
}
function Check-Fails([string]$expected) {
    $caught=$null
    try { & $target -Action Check | Out-Null } catch { $caught=$_ }
    Assert ($caught -and "$caught" -like "*$expected*") "Expected '$expected', got '$caught'"
}
$savedDb=[Environment]::GetEnvironmentVariable('DB_NAME','Process')
$startLocation=(Get-Location).Path
try {
    $env:DB_NAME='command-test-sentinel'
    # Enter from a different directory; script paths and Compose cwd must still resolve.
    Push-Location ([IO.Path]::GetTempPath())
    try {
        $callerLocation=(Get-Location).Path
        $output=@(& $target -Action Check)
        Assert ($output.Count -eq 1 -and $output[0] -like '*읽기 전용*') 'Check output missing'
        Assert ((Get-Location).Path -eq $callerLocation) 'Caller location was not restored'
    } finally { Pop-Location }
    Assert ($env:DB_NAME -eq 'command-test-sentinel') 'Environment was not restored after success'
    Assert (@($calls | Where-Object { $_[0] -eq 'inspect' }).Count -eq 17) 'Role/container checks did not reach Docker mock'
    $expectedRate=37
    & (Join-Path $PSScriptRoot '../performance.ps1') -Mode target -Action Check -WaitingRate 37 | Out-Null
    $expectedRate=25
    $expectedDelay=200
    & (Join-Path $PSScriptRoot '../performance.ps1') -Mode target -Action Check -Scenario warmup -MockPgDelayMs 200 | Out-Null
    Check-Fails 'MOCK_PG_DELAY_MS=0'
    $expectedDelay=0
    foreach ($invalid in @(-1,5001)) {
        $calls.Clear(); $caught=$null
        try { & $target -Action Check -MockPgDelayMs $invalid | Out-Null } catch { $caught=$_ }
        Assert ($caught -and $calls.Count -eq 0) 'Invalid delay reached Docker'
    }
    $mode='docker-failure'; Check-Fails 'exit=23'
    Assert ($env:DB_NAME -eq 'command-test-sentinel') 'Environment was not restored after failure'
    $mode='dev'; Check-Fails 'dev/baseline'
    $mode='missing-scrape'; Check-Fails 'Prometheus'
    $mode='healthy'
    $calls.Clear()
    $caught=$null
    try { & $target -Action Check -Permits 0 | Out-Null } catch { $caught=$_ }
    Assert ($caught -and $calls.Count -eq 0) 'Invalid settings reached Docker'
    '10 offline command checks passed (mocked Docker/HTTP; no Prepare, Run, or real sleeps).'
} finally {
    [Environment]::SetEnvironmentVariable('DB_NAME',$savedDb,'Process')
    Assert ((Get-Location).Path -eq $startLocation) 'Caller location changed'
}
