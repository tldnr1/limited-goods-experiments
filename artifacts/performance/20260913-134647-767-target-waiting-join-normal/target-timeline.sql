SELECT json_build_object('orders', (SELECT coalesce(json_agg(d),'[]') FROM (
 SELECT o.id,o.user_id,o.sale_id,o.created_at,o.status,r.hold_expires_at,r.confirmation_deadline
 FROM orders o JOIN reservations r ON r.order_id=o.id ORDER BY o.created_at) d),
 'payments', (SELECT coalesce(json_agg(d),'[]') FROM (
 SELECT p.id,p.order_id,p.created_at,p.terminal_at,p.status,p.scenario,r.confirmation_deadline,m.accepted_at AS first_pg_at,m.deadline,m.result,
 extract(epoch FROM m.accepted_at-p.created_at) AS first_pg_delay_seconds
 FROM payment_attempts p JOIN reservations r ON r.order_id=p.order_id LEFT JOIN mock_pg_receipts m ON m.attempt_id=p.id ORDER BY p.created_at) d));
