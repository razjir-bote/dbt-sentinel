# Changelog

## 0.2.3 - 2026-11-15

Fixes `sentinel_install` failing on Azure Synapse dedicated SQL pools with `Parse error ... Incorrect syntax near '.'` while creating `v_warehouse_requests`. No table changes; re-run `dbt run-operation sentinel_install` to recreate the views.

- `LABEL` and `IMPORTANCE` are keywords in the dedicated pool parser, so `alias.label` and `alias.importance` are now bracket-quoted (`alias.[label]`, `alias.[importance]`) in `v_warehouse_requests`, `v_warehouse_waits`, `v_user_queries`, `v_query_history`, the shared requests query and the `query_samples` collection insert. Column names in the views are unchanged.
- `tests/check_package.py` flags these columns if they are written without brackets.
- The integration test model `sentinel_it_passing` no longer names a column `label`, which made `dbt build` fail with `Incorrect syntax near 'as'`.

## 0.2.2 - 2026-11-15

Fixes from a second code review. No table changes; run `dbt run-operation sentinel_deploy_views` (or `sentinel_install`) to pick up the view changes.

- `sentinel_deploy_views` checks that `sentinel_view_reader_role` exists before dropping any view. A misspelled or not-yet-created role no longer leaves every view without its grants.
- Writes check that the table has every column this package version expects, not just that it exists. After a package upgrade without `sentinel_install`, hooks skip with a log line instead of failing the build with an uncatchable "Invalid column name", and operations stop with a clear message.
- `scripts/freshness_to_sentinel.py` splits calls by size as well as count (new `--max-args-chars`, default 6000), so long error messages can't exceed the Windows command-line limit. Launch errors are reported per call instead of crashing the script, and print mode now quotes commands for cmd.exe on Windows (POSIX shell elsewhere).
- `v_health_summary.sources_unchecked_or_stale` only counts unchecked sources that have a freshness policy, matching the alert rules.
- `sentinel_check` runs its probes through `sp_executesql`, so a view that no longer binds is reported as not queryable instead of aborting the check. Probe failures are no longer labelled "telemetry write failed".
- `v_table_health_history.is_latest` marks each table's own latest sample (within 48 hours of the newest sample overall), so a table missing from one batch no longer drops out of maintenance alerts.
- Manifest edge and test aggregations read only the latest snapshot per project × target. New `prune_manifests: true` option for `sentinel_purge_history` deletes superseded snapshots older than `keep_days`; the latest snapshot is always kept.
- `v_pipeline_health`, `v_operational_alerts` and `v_health_summary` read run history once each instead of several times, cutting the cost of each dashboard refresh.
- List vars (`sentinel_query_exclude_logins`, `sentinel_storage_exclude_schemas`, `sentinel_tracked_commands`, `sentinel_supported_adapters`) accept a comma-separated string. Before this fix, a plain string was read one character at a time.

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
