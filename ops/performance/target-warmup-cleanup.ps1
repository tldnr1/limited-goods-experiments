# Called only after successful, fully collected priming/warmup, before the next fixture.
function Remove-TargetWarmup([string]$WarmupDirectory) {
    $result=Get-Content "$WarmupDirectory/result.json" -Raw | ConvertFrom-Json
    if ($result.status -ne 'passed') { throw 'Warmup validation failed; cleanup/measurement prohibited' }
    $summary=Get-Content "$WarmupDirectory/k6-summary.json" -Raw | ConvertFrom-Json
    $actual=0L
    if (-not [long]::TryParse([string]$summary.metrics.target_started.values.count,[ref]$actual) -or $actual -le 0) {
        throw 'Missing/invalid actual warmup arrival count; cleanup prohibited'
    }
    $fixture=Get-Content "$WarmupDirectory/fixture.json" -Raw | ConvertFrom-Json
    $saleId=[Guid]$fixture.sale.id
    $cleanup=@"
BEGIN;
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(74190321);
DO `$`$
BEGIN
 IF current_database()<>'limited_goods_perf'
    OR (SELECT count(*) FROM sales)<>1
    OR NOT EXISTS (SELECT 1 FROM sales WHERE id='$saleId')
    OR (SELECT count(*) FROM orders WHERE sale_id='$saleId')<>$actual
    OR (SELECT count(*) FROM orders WHERE sale_id='$saleId' AND status='CONFIRMED')<>$actual
    OR (SELECT count(*) FROM payment_attempts p JOIN orders o ON o.id=p.order_id WHERE o.sale_id='$saleId')<>$actual
    OR EXISTS (SELECT 1 FROM orders o JOIN payment_attempts p ON p.order_id=o.id
               WHERE o.sale_id='$saleId' AND (p.status<>'SUCCEEDED' OR p.terminal_at IS NULL))
 THEN RAISE EXCEPTION 'Warmup cleanup guard failed'; END IF;
END `$`$;
DELETE FROM mock_pg_receipts WHERE attempt_id IN (SELECT p.id FROM payment_attempts p JOIN orders o ON o.id=p.order_id WHERE o.sale_id='$saleId');
DELETE FROM payment_attempts WHERE order_id IN (SELECT id FROM orders WHERE sale_id='$saleId');
DELETE FROM reservations WHERE order_id IN (SELECT id FROM orders WHERE sale_id='$saleId');
DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE sale_id='$saleId');
DELETE FROM orders WHERE sale_id='$saleId';
DELETE FROM sale_items WHERE sale_id='$saleId';
DELETE FROM sales WHERE id='$saleId';
COMMIT;
"@
    Sql $cleanup | Set-Content "$WarmupDirectory/cleanup-db.txt"
    # DB delete committed after all preceding publishers finished; later publishers see no sale.
    $keys=@(Invoke-Docker @('exec',$ids.redis,'redis-cli','--scan','--pattern','goods:perf:*'))
    foreach ($key in $keys) {
        if (-not $key.StartsWith('goods:perf:')) { throw 'Unexpected Redis cleanup key' }
        Invoke-Docker @('exec',$ids.redis,'redis-cli','DEL',$key) | Out-Null
    }
    if ([int](Sql 'SELECT count(*) FROM sales') -ne 0) { throw 'Warmup cleanup left sales' }
    Sql (Get-Content "$PSScriptRoot/target-state.sql" -Raw) | Set-Content "$WarmupDirectory/cleanup-state.json"
    Set-Content "$WarmupDirectory/cleanup-completed.txt" ([DateTimeOffset]::UtcNow.ToString('o'))
}
