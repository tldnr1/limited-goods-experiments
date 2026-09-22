-- perf is empty before each trial, so these aggregates cover only this run's fixtures.
WITH inventory AS (
 SELECT s.*, coalesce(sum(i.quantity) FILTER (WHERE o.status IN ('PAYMENT_PENDING','PAYMENT_PROCESSING')),0) expected_held,
   coalesce(sum(i.quantity) FILTER (WHERE o.status='CONFIRMED'),0) expected_sold
 FROM sale_items s LEFT JOIN order_items i ON i.sale_item_id=s.id LEFT JOIN orders o ON o.id=i.order_id GROUP BY s.id
), limits AS (
 SELECT o.user_id,i.sale_item_id FROM orders o JOIN order_items i ON i.order_id=o.id
 JOIN sale_items s ON s.id=i.sale_item_id WHERE o.status<>'EXPIRED'
 GROUP BY o.user_id,i.sale_item_id,s.per_user_limit HAVING sum(i.quantity)>s.per_user_limit
), success AS (
 SELECT p.*,r.confirmation_deadline,o.status AS order_status
 FROM payment_attempts p JOIN reservations r ON r.order_id=p.order_id JOIN orders o ON o.id=p.order_id
 WHERE p.scenario='SUCCESS'
)
SELECT json_build_object(
 'at',clock_timestamp(),
 'orders',(SELECT count(*) FROM orders),
 'confirmed',(SELECT count(*) FROM orders WHERE status='CONFIRMED'),
 'expired',(SELECT count(*) FROM orders WHERE status='EXPIRED'),
 'attempts',(SELECT count(*) FROM payment_attempts),
 'succeeded',(SELECT count(*) FROM payment_attempts WHERE status='SUCCEEDED'),
 'failed',(SELECT count(*) FROM payment_attempts WHERE status='FAILED'),
 'unknown',(SELECT count(*) FROM payment_attempts WHERE status='UNKNOWN'),
 'pending',(SELECT count(*) FROM payment_attempts WHERE status IN ('CREATED','PROCESSING','UNKNOWN')),
 'successAccepted',(SELECT count(*) FROM success),
 'successConfirmed',(SELECT count(*) FROM success WHERE status='SUCCEEDED' AND order_status='CONFIRMED' AND terminal_at IS NOT NULL),
 'successPending',(SELECT count(*) FROM success WHERE status NOT IN ('SUCCEEDED','FAILED')),
 'successDeadlineViolations',(SELECT count(*) FROM success WHERE terminal_at>confirmation_deadline
   OR (status NOT IN ('SUCCEEDED','FAILED') AND clock_timestamp()>confirmation_deadline)),
 'terminalEvidenceMissing',(SELECT count(*) FROM payment_attempts WHERE status IN ('SUCCEEDED','FAILED') AND terminal_at IS NULL),
 'oldestSuccessPendingSeconds',(SELECT coalesce(max(extract(epoch FROM clock_timestamp()-created_at)),0) FROM success WHERE status NOT IN ('SUCCEEDED','FAILED')),
 'latestSuccessDeadline',(SELECT max(confirmation_deadline) FROM success),
 'latestSuccessPendingDeadline',(SELECT max(confirmation_deadline) FROM success WHERE status NOT IN ('SUCCEEDED','FAILED')),
 'earliestSuccessPendingDeadline',(SELECT min(confirmation_deadline) FROM success WHERE status NOT IN ('SUCCEEDED','FAILED')),
 'oldestPendingSeconds',(SELECT coalesce(max(extract(epoch FROM clock_timestamp()-created_at)),0) FROM payment_attempts WHERE status IN ('CREATED','PROCESSING','UNKNOWN')),
 'inventoryViolations',(SELECT count(*) FROM inventory WHERE total<>available+held+sold OR held<>expected_held OR sold<>expected_sold),
 'userLimitViolations',(SELECT count(*) FROM limits),
 'holdViolations',(SELECT count(*) FROM orders o LEFT JOIN reservations r ON r.order_id=o.id WHERE r.order_id IS NULL
   OR r.hold_expires_at<>o.created_at+interval '300 seconds'
   OR (o.status='CONFIRMED' AND r.status<>'CONFIRMED') OR (o.status='EXPIRED' AND r.status<>'EXPIRED')
   OR (o.status IN ('PAYMENT_PENDING','PAYMENT_PROCESSING') AND r.status<>'ACTIVE')),
 'duplicateSuccess',(SELECT count(*) FROM (SELECT order_id FROM payment_attempts WHERE status='SUCCEEDED' GROUP BY order_id HAVING count(*)>1) d),
 'waitingDbConnections',(SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND application_name IN ('api1','api2')),
 'lockWaiters',(SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock'),
 'database',(SELECT row_to_json(d) FROM (SELECT xact_commit,xact_rollback,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,deadlocks FROM pg_stat_database WHERE datname=current_database()) d),
 'inventory',(SELECT coalesce(json_agg(d),'[]') FROM (SELECT id,sale_id,total,available,held,sold FROM sale_items) d)
);
