# Changelog

## 0.2.1 - 2026-11-15

Fixes from code review. Run `dbt run-operation sentinel_install` to add the new `freshness_events` columns and redeploy the views (schema version 3).

- `v_health_summary.overall_state` checks high and medium alerts before anything else, so a stopped scheduler with failing stages or sources now shows red or amber. It is `unknown` only when no dbt run has ever been recorded.
- Boolean vars are parsed with the new `sentinel_bool_var`, so the string `'false'` (e.g. from `env_var()`) no longer turns on `sentinel_enabled`, `sentinel_capture_query_text`, `sentinel_expose_command_text`, `sentinel_capture_messages` or `sentinel_manifest_include_packages`. Unrecognised values are rejected.
- `freshness_events` records `project_name` and `target_name`; `v_source_freshness` keeps the latest check per source and target, so a dev check no longer masks a prod failure, and alerts are no longer repeated for every target. Rows written before 0.2.1 have no target and are ignored by the view.
- dbt unit tests (`unit_test`, dbt >= 1.8) are synced from the manifest (test type `unit`), linked to their model, and counted in `v_test_failures`, test-failure alerts and `v_model_health`. `v_test_coverage` gains a `unit_tests` column.
- Hooks in `warn` mode check that their table exists and skip with a log line when Sentinel is not installed in the target, instead of failing the build with an uncatchable T-SQL name-resolution error.
- Warn-mode problems are written with `log()` rather than `exceptions.warn`, so `--warn-error` can no longer turn a swallowed telemetry error into a build failure.
- `sentinel_sample_requests` compares end times at the stored `datetime2(3)` precision, so the newest request is no longer copied again on the next run.
- `sentinel_view_reader_role` and `sentinel_schema_owner` accept any principal name (such as an Entra ID group like `PBI-Readers`), bracket-quoted and escaped. Configuration and every view are now validated and rendered before any view is dropped.
- If a node-results batch fails, the run's completion event is skipped, so the run shows as `missing_completion` rather than as complete with missing nodes. Likewise, a partially loaded manifest no longer gets a snapshot header.
- `examples/azure-pipelines-steps.yml` passes `--target prod` to every Sentinel step.

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
