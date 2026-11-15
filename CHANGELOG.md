# Changelog

## 0.2.0 - 2026-11-15

- Table health checks for Dedicated SQL Pool: `v_table_skew` (rows per distribution and skew %), `v_columnstore_health` (row-group size, delta store, deleted rows, memory-trimmed groups), `v_table_statistics` (missing statistics and optimizer vs actual row-count drift) and the combined `v_table_health` with recommended fixes.
- `sentinel_sample_table_health` daily snapshot into `table_health_samples`; `v_table_health_history`; low-severity `table_maintenance` alerts; `tables_needing_maintenance` in `v_health_summary`.
- Nine configurable thresholds (see `examples/dbt_project_fragment.yml`). Run `sentinel_install` to add the new table and views.

## 0.1.0 - 2026-11-15

Initial release for dbt Core 1.12 + dbt-synapse on Azure Synapse Dedicated SQL Pool.

- Telemetry schema: run events, node results, manifest snapshots/nodes/edges, warehouse, storage and query samples, stage and freshness events, install log.
- Hooks: `sentinel_start_run`, `sentinel_capture_run` (batched, typed inserts; `warn` mode by default so telemetry cannot fail a build).
- Operations: `sentinel_install`, `sentinel_deploy_views`, `sentinel_check`, `sentinel_sync_manifest`, `sentinel_sample_warehouse`, `sentinel_sample_storage`, `sentinel_sample_requests`, `sentinel_record_stage`, `sentinel_record_freshness`, `sentinel_record_freshness_batch`, `sentinel_purge_history`.
- 23 dashboard views, including login-level query activity (`v_user_queries`, `v_query_history`, `v_user_activity_daily`).
- Examples for host configuration, Azure DevOps and Power BI; `scripts/freshness_to_sentinel.py`.
