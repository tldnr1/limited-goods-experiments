# Target has one pool in each DB role; api1/api2 are DB-free Waiting roles.
function Test-HikariNumber($Value) {
    return ($Value -is [ValueType] -and $Value -isnot [bool] -and $Value -isnot [char] -and
        -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value) -and $Value -ge 0)
}

function Get-TargetHikariMap($Snapshot) {
    $expected=@('reservation:8080','payment:8080','worker:8080','mock-pg:8080')
    if ($Snapshot.metric -cne 'hikaricp_connections_timeout_total' -or -not (Test-HikariNumber $Snapshot.timestamp) -or
        -not (Test-HikariNumber $Snapshot.boundaryRequestedAt) -or $Snapshot.timestamp -lt $Snapshot.boundaryRequestedAt) { throw 'Invalid Hikari boundary metadata' }
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($series in $Snapshot.series) {
        if ($series.instance -cnotin $expected -or -not (Test-HikariNumber $series.value) -or
            -not (Test-HikariNumber $series.scrapedAt) -or $series.scrapedAt -lt $Snapshot.boundaryRequestedAt -or $series.scrapedAt -gt $Snapshot.timestamp) { throw 'Invalid/stale Hikari boundary series' }
        $key=ConvertTo-Json -InputObject @($series.instance,$series.pool) -Compress
        if ($map.ContainsKey($key)) { throw 'Duplicate Hikari boundary series' }
        $map.Add($key,$series)
    }
    if ($map.Count -ne 4 -or @($Snapshot.series.instance | Sort-Object -Unique).Count -ne 4) { throw 'Expected four Target Hikari pools' }
    return ,$map
}

function Save-TargetHikariBoundary([string]$Path) {
    $boundary=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000
    $metric='hikaricp_connections_timeout_total'
    # Instant selector timestamps are evaluation times. timestamp() supplies actual scrape times
    # in the SAME evaluation, so the after snapshot cannot silently reuse a pre-drain scrape.
    $selector=$metric+'{job="target"}'
    $query=[Uri]::EscapeDataString($selector+' or on(__name__,instance,pool) label_replace(timestamp('+$selector+'), "__name__", "hikari_boundary_scraped_at", "__name__", ".*")')
    for ($attempt=0;$attempt -lt 15;$attempt++) {
        try {
            $response=Invoke-RestMethod "http://127.0.0.1:9090/api/v1/query?query=$query" -TimeoutSec 2
            if ($response.status -ne 'success' -or $response.data.resultType -ne 'vector') { throw 'Hikari instant query failed' }
            $rows=@($response.data.result)
            $counters=@($rows | Where-Object { $_.metric.__name__ -eq $metric })
            $series=@(foreach ($counter in $counters) {
                $stamp=@($rows | Where-Object { $_.metric.__name__ -eq 'hikari_boundary_scraped_at' -and $_.metric.instance -ceq $counter.metric.instance -and $_.metric.pool -ceq $counter.metric.pool })
                if ($stamp.Count -ne 1) { throw 'Missing/ambiguous Hikari scrape timestamp' }
                @{instance=$counter.metric.instance;pool=$counter.metric.pool;value=[double]::Parse($counter.value[1],[Globalization.CultureInfo]::InvariantCulture);scrapedAt=[double]::Parse($stamp[0].value[1],[Globalization.CultureInfo]::InvariantCulture)}
            })
            $snapshot=@{metric=$metric;boundaryRequestedAt=$boundary;timestamp=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000;series=$series}
            $null=Get-TargetHikariMap $snapshot
            Save-Json $snapshot $Path
            return
        } catch { $lastError=$_ }
        if ($attempt -lt 14) { Start-Sleep -Seconds 1 }
    }
    throw "Hikari boundary unavailable after 15 bounded attempts: $lastError"
}
