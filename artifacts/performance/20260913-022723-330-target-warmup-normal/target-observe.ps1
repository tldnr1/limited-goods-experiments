param([string]$Directory,[string]$Postgres,[string]$Redis,[string[]]$Containers,[int]$IntervalSeconds=5,[string]$GeneratorName='goods-target-k6')
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
try {
    $stateSql=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'target-state.sql') -Raw
    $fixture=Get-Content -LiteralPath (Join-Path $Directory 'fixture.json') -Raw | ConvertFrom-Json
    # Bounded even if the parent terminates without writing stop-observer.
    $deadline=[DateTimeOffset]::UtcNow.AddMinutes(20)
    while (-not (Test-Path "$Directory/stop-observer") -and [DateTimeOffset]::UtcNow -lt $deadline) {
        $at=[DateTimeOffset]::UtcNow.ToString('o')
        $db=$stateSql | & docker exec -i $Postgres psql -X -qAt -v ON_ERROR_STOP=1 -U goods -d limited_goods_perf
        if ($LASTEXITCODE -ne 0) { throw 'DB sampling failed' }
        # psql JSON may span lines (e.g. json_agg of multiple inventory rows). JSONL requires one per sample.
        ($db -join "`n") | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress |
            Add-Content "$Directory/db-samples.jsonl" -Encoding utf8
        $stats=& docker stats --no-stream --format '{{json .}}' @Containers
        if ($LASTEXITCODE -ne 0) { throw 'Resource sampling failed' }
        @{at=$at;containers=@($stats | ForEach-Object { $_ | ConvertFrom-Json })} | ConvertTo-Json -Compress -Depth 8 | Add-Content "$Directory/resources.jsonl"
        $generator=& docker ps --filter "name=^/$GeneratorName$" -q
        if ($LASTEXITCODE -ne 0) { throw 'Generator lookup failed' }
        if ($generator) {
            $generatorStats=& docker stats --no-stream --format '{{json .}}' $generator
            if ($LASTEXITCODE -eq 0 -and $generatorStats) {
                @{at=$at;container=($generatorStats | ConvertFrom-Json)} | ConvertTo-Json -Compress -Depth 5 | Add-Content "$Directory/generator-resources.jsonl"
            }
        }
        $info=& docker exec $Redis redis-cli INFO all
        if ($LASTEXITCODE -ne 0) { throw 'Redis INFO failed' }
        $script="local t=redis.call('TIME'); local now=t[1]*1000+math.floor(t[2]/1000); return cjson.encode({queue=redis.call('ZCARD','goods:perf:waiting:queue'),ready=redis.call('ZCARD','goods:perf:waiting:ready'),live=redis.call('ZCARD','goods:perf:waiting:live'),stale=redis.call('ZCOUNT','goods:perf:waiting:live','-inf',now)})"
        $queue=& docker exec $Redis redis-cli EVAL $script 0
        if ($LASTEXITCODE -ne 0) { throw 'Redis queue sampling failed' }
        $catalog=& docker exec $Redis redis-cli GET "goods:perf:catalog:$($fixture.sale.id)"
        if ($LASTEXITCODE -ne 0) { throw 'Redis projection sampling failed' }
        @{at=$at;info=($info -join "`n");queue=($queue | ConvertFrom-Json);catalog=$catalog} |
            ConvertTo-Json -Compress -Depth 5 | Add-Content "$Directory/redis-samples.jsonl"
        if (-not (Test-Path "$Directory/observer-ready")) { Set-Content "$Directory/observer-ready" $at }
        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    $_ | Out-String | Set-Content "$Directory/observer-error.txt"
    throw
}
