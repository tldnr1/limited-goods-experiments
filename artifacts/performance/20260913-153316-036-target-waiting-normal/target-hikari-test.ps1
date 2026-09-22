# Offline instant-query collection: fake HTTP, no Docker/k6 or real sleeps.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/target-hikari.ps1"
$calls=0; $saved=$null; $mode='ready'; $checks=0
function Assert($ok,$message) { if (-not $ok) { throw $message }; $script:checks++ }
function Start-Sleep { param($Seconds) }
function Save-Json($value,$path) { $script:saved=$value }
function Invoke-RestMethod { param($Uri,$TimeoutSec)
    $script:calls++
    Assert ($Uri -like '*api/v1/query?*' -and [Uri]::UnescapeDataString($Uri) -like '*or on(__name__,instance,pool) label_replace(timestamp(*') 'Expected instant query retaining both counter and scrape timestamps'
    if ($mode -eq 'error') { throw 'offline HTTP failure' }
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000
    $rows=@(foreach ($instance in @('reservation:8080','payment:8080','worker:8080','mock-pg:8080')) {
        @{metric=@{__name__='hikaricp_connections_timeout_total';instance=$instance;pool='HikariPool-1'};value=@($now,'3')}
        @{metric=@{__name__='hikari_boundary_scraped_at';instance=$instance;pool='HikariPool-1'};value=@($now,$(if ($mode -eq 'stale') {'1'} else { $now.ToString([Globalization.CultureInfo]::InvariantCulture) }))}
    })
    if ($mode -eq 'missing' -or ($mode -eq 'retry' -and $calls -eq 1)) { $rows=@() }
    if ($mode -eq 'unexpected') { $rows[0].metric.instance='api1:8080' }
    if ($mode -eq 'duplicate') { $rows+= $rows[0] }
    if ($mode -eq 'nan') { $rows[0].value[1]='NaN' }
    return @{status='success';data=@{resultType='vector';result=$rows}}
}
foreach ($testMode in @('ready','retry','missing','stale','unexpected','duplicate','nan','error')) {
    $mode=$testMode; $calls=0; $saved=$null; $caught=$null
    try { Save-TargetHikariBoundary 'unused.json' } catch { $caught=$_ }
    if ($mode -in @('ready','retry')) {
        Assert (-not $caught -and $saved.series.Count -eq 4 -and $saved.series[0].value -eq 3) 'Valid accumulated baseline was not saved'
        Assert ($calls -eq $(if ($mode -eq 'retry') {2} else {1})) 'Readiness retry count wrong'
    } else {
        Assert ($caught -and $calls -eq 15 -and $null -eq $saved) 'Invalid evidence did not fail within bounded retries'
    }
}
# Run the actual pre-load/load/drain segment with boundary failures injected.
$trial=Get-Content "$PSScriptRoot/target-trial.ps1" -Raw
$from=$trial.IndexOf('    Save-TargetHikariBoundary "$directory/boundary-before.json"')
$to=$trial.IndexOf('    $match=Select-String',$from)
$segment=[scriptblock]::Create($trial.Substring($from,$to-$from))
$events=[Collections.Generic.List[string]]::new()
function Save-TargetHikariBoundary($path) {
    $events.Add($path)
    if ($failBefore -and $path -like '*boundary-before.json') { throw 'Hikari baseline unavailable' }
}
function docker { $events.Add('load'); $global:LASTEXITCODE=0 }
function Tee-Object { param($FilePath) }
function Set-Content { param($Path,$Value) }
function Wait-TargetSuccessDrain($path) { $events.Add('drain'); return 'all_success_terminal' }
$directory='warmup'; $Scenario='warmup'; $failBefore=$true
$caught=$null
try { & $segment | Out-Null } catch { $caught=$_ }
Assert ($caught -and ($events -join ',') -eq 'warmup/boundary-before.json') 'Missing baseline reached load'
$failBefore=$false; $events.Clear(); & $segment | Out-Null
$directory='measurement'; & $segment | Out-Null
Assert (($events -join ',') -eq 'warmup/boundary-before.json,load,drain,warmup/boundary-after.json,measurement/boundary-before.json,load,drain,measurement/boundary-after.json') 'Trial boundaries are not independent or do not enclose load and drain'
"$checks offline Hikari collection/boundary assertions passed."
