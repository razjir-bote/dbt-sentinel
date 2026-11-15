-- dbt Sentinel acceptance queries. Run in the development pool after the
-- steps in integration_tests/README.md. Schema: sentinel_it_telemetry.
-- Each query states its expected result.

-- A1. Exactly one start and at most one end event per invocation. Expect 0 rows.
SELECT invocation_id, event_type, COUNT(*) AS n
FROM sentinel_it_telemetry.run_events
GROUP BY invocation_id, event_type
HAVING COUNT(*) > 1;

-- A2. One row per invocation in v_run_history. Expect 0 rows.
SELECT invocation_id, COUNT(*) AS n
FROM sentinel_it_telemetry.v_run_history
GROUP BY invocation_id
HAVING COUNT(*) > 1;

-- A3. Node row count matches the recorded nodes_total for every completed run. Expect 0 rows.
SELECT h.invocation_id, h.nodes_total, COUNT(n.unique_id) AS node_rows
FROM sentinel_it_telemetry.v_run_history AS h
LEFT JOIN sentinel_it_telemetry.node_results AS n ON n.invocation_id = h.invocation_id
WHERE h.completed_at_utc IS NOT NULL
GROUP BY h.invocation_id, h.nodes_total
HAVING COUNT(n.unique_id) <> h.nodes_total;

-- A4. The forced-failure build is recorded as error with a failed test. Expect >= 1 row.
SELECT h.invocation_id, h.run_status, f.test_name, f.status
FROM sentinel_it_telemetry.v_run_history AS h
JOIN sentinel_it_telemetry.v_test_failures AS f ON f.invocation_id = h.invocation_id
WHERE h.run_status = 'error' AND f.test_name = 'sentinel_it_failing';

-- A5. Test coverage after manifest sync: the passing model has 2 tests (+1 singular). Expect test_count = 3, has_owner = 1.
SELECT unique_id, test_count, not_null_tests, unique_tests, singular_tests, has_owner
FROM sentinel_it_telemetry.v_test_coverage
WHERE unique_id = 'model.sentinel_integration_tests.sentinel_it_passing';

-- A6. The interrupted build shows missing_completion (after sentinel_missing_completion_minutes). Expect >= 1 row.
SELECT invocation_id, started_at_utc, run_status
FROM sentinel_it_telemetry.v_run_history
WHERE run_status = 'missing_completion';

-- A7. Samples, stage and freshness writers. Expect each count >= 1.
SELECT 'warehouse_samples' AS t, COUNT(*) AS n FROM sentinel_it_telemetry.warehouse_samples
UNION ALL SELECT 'storage_samples', COUNT(*) FROM sentinel_it_telemetry.storage_samples
UNION ALL SELECT 'query_samples', COUNT(*) FROM sentinel_it_telemetry.query_samples
UNION ALL SELECT 'table_health_samples', COUNT(*) FROM sentinel_it_telemetry.table_health_samples
UNION ALL SELECT 'stage_events', COUNT(*) FROM sentinel_it_telemetry.stage_events
UNION ALL SELECT 'freshness_events', COUNT(*) FROM sentinel_it_telemetry.freshness_events;

-- A7b. Query history has no duplicate requests and carries login names. Expect 0 rows, then >= 1 row.
SELECT request_id, submit_time_utc, COUNT(*) AS n
FROM sentinel_it_telemetry.query_samples
GROUP BY request_id, submit_time_utc
HAVING COUNT(*) > 1;
SELECT TOP 20 login_name, app_name, query_date_utc, queries, failed_queries FROM sentinel_it_telemetry.v_user_activity_daily;

-- A7c. Table health covers every user table, including Sentinel's own. Expect >= 10 rows, issue columns populated.
SELECT schema_name, table_name, distribution_policy, actual_row_count, skew_pct, is_skewed,
       avg_rows_per_rowgroup, is_poor_columnstore, stats_count, stats_row_diff_pct, is_stale_stats, recommendation
FROM sentinel_it_telemetry.v_table_health;

-- A8. Summary renders one row and alerts include the failed test.
SELECT * FROM sentinel_it_telemetry.v_health_summary;
SELECT alert_type, severity, subject FROM sentinel_it_telemetry.v_operational_alerts;
