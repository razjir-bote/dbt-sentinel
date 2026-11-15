# dbt Sentinel 0.2.3

A custom, framework-only dbt package for **dbt Core 1.12.6 + dbt-synapse on Azure Synapse Dedicated SQL Pool**. It installs a `sentinel` (configurable) schema containing low-volume telemetry tables and dashboard-ready SQL views. No business/source tables are modified.

**Status:** starter implementation. Every macro is parsed and rendered against a mock dbt context by `tests/check_package.py` (escaping, batching, validation, Dedicated SQL Pool dialect rules, T-SQL parse via sqlglot); **not yet integration-tested against a live Synapse pool**. Run `integration_tests/` against a development pool and validate your dbt-synapse environment before production use. This is not yet a production-certified observability product.

## Install from a release archive

Each release is built as `dist/dbt_sentinel-<version>.zip` (with a `.sha256` checksum) by `python scripts/build_package.py --check`. The zip contains one folder, `dbt_sentinel/`, with only what a host project needs (no tests or integration project).

1. Unzip it somewhere stable, e.g. `C:\dbt-packages\` so you have `C:\dbt-packages\dbt_sentinel\dbt_project.yml`. For a new version, unzip alongside (or replace) and update the path.
2. In the host project's `packages.yml`:

   ```yaml
   packages:
     - local: "C:/dbt-packages/dbt_sentinel"
   ```

3. `dbt deps`, then continue from step 3 of the quick start below.

For Azure DevOps builds, either commit the unzipped folder to the host repository (e.g. `packages/dbt_sentinel` with `local: "packages/dbt_sentinel"`) or publish the package to a private Git repo and pin the tag (`git:` + `revision: "0.2.3"`). A path on your own machine is not visible to build agents.

## Quick start

The short path from zero to a working dashboard. Sections 1-7 below have the detail.

1. **Permissions.** Use a deployment identity that can create a schema, create tables and views, and write to the Sentinel schema. The DMV views (`v_warehouse_requests`, `v_warehouse_waits`, `v_warehouse_pressure`, `v_table_storage`) and `sentinel_sample_warehouse` also need `VIEW DATABASE STATE`.

2. **Add the package** to the host project's `packages.yml`:

   ```yaml
   packages:
     - local: "C:/dbt-sentinel"        # local development (or a relative path)
     # Azure DevOps agents cannot see a local drive - use a private repo and pin a tag:
     # - git: "https://dev.azure.com/<org>/<project>/_git/dbt_sentinel"
     #   revision: "0.2.3"
   ```

3. **Add hooks and vars** to the host `dbt_project.yml`, merged with what is already there (see `examples/dbt_project_fragment.yml` for every option, e.g. `sentinel_view_reader_role`, `sentinel_summary_target`):

   ```yaml
   vars:
     sentinel_schema: sentinel
     sentinel_run_stale_hours: 26
     sentinel_model_slowdown_factor: 2.0
     sentinel_batch_size: 35
   on-run-start:
     - "{{ dbt_sentinel.sentinel_start_run() }}"
   on-run-end:
     - "{{ dbt_sentinel.sentinel_capture_run(results) }}"
   ```

4. **Install** (before the first build with the hooks enabled):

   ```shell
   dbt deps
   dbt run-operation sentinel_install
   dbt run-operation sentinel_sync_manifest
   dbt run-operation sentinel_check
   ```

   `sentinel_check` should pass; warnings for the DMV views mean the identity lacks `VIEW DATABASE STATE`.

5. **Run as normal.** `dbt build` now records start, per-node results and completion. Re-run `sentinel_sync_manifest` after releases that change models, tests or owners; run `sentinel_deploy_views` after changing threshold vars.

6. **Schedule samples and maintenance** in a separate pipeline:

   | Cadence | Command |
   | --- | --- |
   | Every 15 minutes | `dbt run-operation sentinel_sample_warehouse` |
   | Every 15 minutes | `dbt run-operation sentinel_sample_requests` (login-level query history) |
   | Daily | `dbt run-operation sentinel_sample_storage` |
   | Daily | `dbt run-operation sentinel_sample_table_health` |
   | Weekly | `dbt run-operation sentinel_purge_history --args "{keep_days: 180}"` (add `prune_manifests: true` to also drop superseded manifest snapshots; the latest per project × target is always kept) |

7. **Report what dbt cannot see.** Add `sentinel_record_stage` calls (with an `always()` finaliser passing `$(Agent.JobStatus)`) and `scripts/freshness_to_sentinel.py` after `dbt source freshness` - see `examples/azure-pipelines-steps.yml`. Keep these steps `continueOnError: true` so dbt's exit code stays authoritative.

8. **Connect Power BI** to the `v_*` views only (Import, scheduled refresh); starter measures are in `examples/powerbi_measures.dax`.

> **Windows / PowerShell:** older PowerShell versions mangle double quotes inside `--args`. Use YAML-style arguments without inner double quotes, e.g. `--args "{pipeline_name: TDI, stage: bronze, status: success}"`.

Validate first with `integration_tests/` against a development pool (section 7).

## Why tables plus views?

Views can show current metadata and near-real-time DMV information, but cannot preserve prior failures, missed schedules, model execution history, or historical data-volume trends. Sentinel persistently captures dbt hook events and optional stage/freshness/warehouse snapshots. Dashboard views consolidate them.

## Scope

- **Automatic dbt:** `build`/`run`/`test`/`seed`/`snapshot` invocation start/completion (excluding `compile` and `docs generate`), model/test/seed/snapshot result statuses, runtime, errors, test failures, pipeline IDs, commit IDs.
- **Deployment metadata:** model/source/test inventory, owners (`meta.owner`), descriptions, dependency edges, model test coverage.
- **Synapse live diagnostics:** query runtimes, queue latency, suspension/failed queries, waits, physical table row counts and storage.
- **User query activity:** who ran which queries (login, client application, status, timing, statement type), live and as sampled history; SQL text optional.
- **Optional scheduled samples:** warehouse pressure and table growth.
- **Integration hooks:** Spark/Bronze and DevOps stage status; source freshness (must be actively supplied).
- **Dashboard:** summary, recent failures, 24-hour trends, model drill-through, anomaly detection, data-quality coverage, warehouse health, dataset growth.

**Important limitations:** The package cannot independently see Azure DevOps job failures that prevent dbt from starting; this requires orchestration to call `sentinel_record_stage`. Nor can SQL-pool views see Synapse Spark notebook failures, Azure Monitor DWU/billing metrics, or lake source freshness without external telemetry. `dbt source freshness` does not invoke the normal dbt `on-run-end` hook. Extend with a scheduled artifact/DevOps exporter or `sentinel_record_freshness`. DMVs retain recent queries only, and are reset by scaling/pausing; preserve time-series snapshots. The generated views do not grant monitoring privileges automatically.

## File layout

```text
dbt_sentinel/
  dbt_project.yml                 dbt package manifest
  macros/helpers.sql             adapter checks, SQL safe-escaping, batch inserts
  macros/install.sql             table registry, installation/redeployment, smoke check
  macros/collect.sql             hooks, manifest sync, samplers, integration writers, purge
  macros/views.sql               managed, dashboard-ready SQL view definitions
  examples/packages.yml          local install example
  examples/dbt_project_fragment.yml   hooks + every supported var
  examples/azure-pipelines-steps.yml
  examples/powerbi_measures.dax
  scripts/freshness_to_sentinel.py   sources.json -> sentinel_record_freshness_batch
  scripts/build_package.py       builds dist/dbt_sentinel-<version>.zip release archive
  CHANGELOG.md                   release notes
  tests/check_package.py         static + mock-render validation (no database needed)
  tests/dbt_fake_pool.py         runs real dbt + dbt-synapse against a recording fake ODBC connection
  integration_tests/             minimal host project + acceptance queries for a dev pool
```

## 1. Install in a host project

Copy the package alongside the host project or put it in a private Git repository. For a local package:

```yaml
# host project's packages.yml
packages:
  - local: "../dbt_sentinel"
```

In the host project's `dbt_project.yml`, merge the following with existing hooks and vars; **do not replace your existing configuration**:

```yaml
vars:
  sentinel_schema: sentinel
  sentinel_run_stale_hours: 26
  sentinel_model_slowdown_factor: 2.0
  sentinel_batch_size: 35
on-run-start:
  - "{{ dbt_sentinel.sentinel_start_run() }}"
on-run-end:
  - "{{ dbt_sentinel.sentinel_capture_run(results) }}"
```

Passing `results` explicitly is recommended; `sentinel_capture_run()` with no argument falls back to the hook context's `results`. See `examples/dbt_project_fragment.yml` for every supported var. By default (`sentinel_hook_on_error: warn`) a telemetry write failure is logged as a `[WARNING]` line and does not fail the build; set it to `fail` to make telemetry mandatory. Warn mode also holds under `--warn-error` (Sentinel logs instead of raising a dbt warning) and on targets where Sentinel is not installed (the hooks check that their tables exist and skip with a log line). A lost database connection during the hook can still fail it, because dbt's Jinja cannot catch adapter exceptions. If node results cannot be fully written, the completion event is skipped, so the invocation shows as `missing_completion` instead of a complete run with missing nodes.

Boolean vars (`sentinel_enabled`, `sentinel_capture_messages`, `sentinel_capture_query_text`, `sentinel_expose_command_text`, `sentinel_manifest_include_packages`) accept real booleans or the strings `true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`, so values from `env_var()` behave as expected; anything else is rejected. List vars (`sentinel_query_exclude_logins`, `sentinel_storage_exclude_schemas`, `sentinel_tracked_commands`, `sentinel_supported_adapters`) accept a YAML list or a comma-separated string.

Before writing, Sentinel checks that the target table has every column this package version expects. After upgrading the package, run `sentinel_install` again: until you do, hooks skip their writes with a log line, and operations stop with a message telling you to run it.

Execute from the host project's configured environment:

```shell
dbt deps
dbt run-operation sentinel_install
dbt run-operation sentinel_sync_manifest
dbt run-operation sentinel_check
```

Then run `dbt build` normally. `on-run-start` writes a `running` event; `on-run-end` appends execution results and completes the invocation. If dbt aborts before the ending hook, the stale `running` event is flagged in `sentinel.v_run_history` as `missing_completion` after 120 minutes. The host's telemetry schema must already exist before hooks run; do `sentinel_install` first.

View thresholds (`sentinel_run_stale_hours`, `sentinel_missing_completion_minutes`, `sentinel_model_slowdown_factor`, ...) are rendered into the view text: after changing them run `dbt run-operation sentinel_deploy_views`.

After every release that changes the manifest, run `dbt run-operation sentinel_sync_manifest`. For minimal operational overhead, do not repeatedly resync the graph on every build.

## 2. Schedule warehouse samples

Run from Azure DevOps or an equivalent scheduler (for example, every 15 minutes for pressure and daily for storage):

```shell
dbt run-operation sentinel_sample_warehouse
dbt run-operation sentinel_sample_storage
dbt run-operation sentinel_sample_requests
dbt run-operation sentinel_sample_table_health   # daily
```

### Table health (skew, columnstore, statistics)

Three checks cover common causes of slow queries on a Dedicated SQL Pool:

| Check | Flagged when (defaults) | Typical fix |
| --- | --- | --- |
| Distribution skew (`v_table_skew`) | HASH/ROUND_ROBIN table with >= 1,000,000 rows and skew >= 10%, where skew % = 100 x (1 - avg/max rows per distribution) | Choose a higher-cardinality, evenly spread distribution column (CTAS to redistribute) |
| Columnstore quality (`v_columnstore_health`) | Table >= 6,000,000 rows averaging < 100,000 rows per compressed row group, or delta store >= 10% (tables >= 1M rows), or deleted rows >= 10% | `ALTER INDEX ALL ... REBUILD` under a larger resource class; avoid trickle loads |
| Statistics (`v_table_statistics`) | Table >= 1,000 rows with no statistics, or optimizer row count differing from actual by >= 20% (replicated tables excluded) | `UPDATE STATISTICS` after loads (the pool does not auto-update) |

`v_table_health` combines them per table with an `issue_count` and a plain-language `recommendation`. These views read the DMVs live and can take a few seconds on large databases; for dashboards and alerting, schedule a daily snapshot:

```shell
dbt run-operation sentinel_sample_table_health
```

`v_table_health_history` keeps the trend without DMV permissions, tables with issues in the latest snapshot appear in `v_operational_alerts` as low-severity `table_maintenance` alerts, and `v_health_summary` shows `tables_needing_maintenance`. Thresholds: `sentinel_skew_threshold_pct`, `sentinel_skew_min_rows`, `sentinel_cci_min_table_rows`, `sentinel_cci_min_avg_rows`, `sentinel_cci_small_rowgroup_rows`, `sentinel_cci_max_delta_pct`, `sentinel_cci_max_deleted_pct`, `sentinel_stats_max_diff_pct`, `sentinel_stats_min_rows` (redeploy views after changing).

### Query activity by user

`sentinel_sample_requests` copies finished requests (Completed, Failed, Cancelled) from `sys.dm_pdw_exec_requests`, joined to `sys.dm_pdw_exec_sessions` for `login_name` and `app_name`, into `query_samples`. It is incremental on end time, so run it often enough that fewer than ~10,000 requests (the DMV's retention) finish between runs; requests that age out of the DMV or are lost to a pause/scale before sampling are not recoverable. `v_query_history` and `v_user_activity_daily` read the sampled table and need no DMV permission, so Power BI readers can see activity without `VIEW DATABASE STATE`.

```shell
dbt run-operation sentinel_sample_requests
```

| Var | Default | Effect |
| --- | --- | --- |
| `sentinel_capture_query_text` | `false` | Store (and show in `v_user_queries`) the SQL text. Off by default: query text can contain personal or sensitive literals. |
| `sentinel_query_text_max_length` | `1000` | Characters of SQL text kept when capture is on. |
| `sentinel_query_exclude_logins` | `[]` | Logins to leave out (e.g. high-volume service accounts). `System` is always excluded. |

`statement_type` is the first SQL keyword after any leading comment (e.g. `SELECT`, `INSERT`, `CREATE`), which classifies activity without storing text. Login-level history records staff activity: confirm it is covered by your agency's monitoring and privacy arrangements, restrict access to `v_query_history`/`v_user_activity_daily`, and set retention with `sentinel_purge_history`. For audit-grade, tamper-resistant records use Synapse SQL Auditing or diagnostic settings (ExecRequests to Log Analytics) instead.

Optional retention maintenance:

```shell
dbt run-operation sentinel_purge_history --args '{"keep_days": 180}'
```

The purge does **not** automatically remove manifest snapshots or their dependency graph (they are deployment/audit metadata). Plan separate manifest-snapshot lifecycle management when the package is expanded.

## 3. Integrate Bronze/Spark and Azure DevOps

The dbt hook sees only dbt. To extend observability across Landing, Bronze (Synapse Spark), `_SRC` loading, and Silver/Gold, have each orchestrator stage report status:

```shell
dbt run-operation sentinel_record_stage --args '{"pipeline_name":"TDI", "pipeline_run_id":"1234", "stage":"bronze", "source_name":"ABR", "status":"success", "rows_loaded":100000}'
```

Also report pipeline-level status in an Azure DevOps `always()` finalizer. A dbt failure can prevent an end hook or an entire job from running, so an independent finalizer is important. Its own failure should not mask the original dbt result; always preserve the dbt task's exit code as authoritative.

Log source freshness after source checks:

```shell
dbt run-operation sentinel_record_freshness --args '{"source_id":"source.tdi.abr.organisations", "status":"pass", "age_minutes":45, "threshold_minutes":180}'
```

Or forward every result from `dbt source freshness` (batched `sentinel_record_freshness_batch` calls):

```shell
dbt source freshness
python dbt_packages/dbt_sentinel/scripts/freshness_to_sentinel.py target/sources.json --execute
```

Stage statuses: `success`, `warning`, `failed`, `running`, `skipped`, `cancelled` (Azure DevOps `Agent.JobStatus` values such as `Succeeded`, `SucceededWithIssues`, `Failed`, `Canceled` are normalised). Freshness statuses: `pass`, `warn`, `error`, `runtime error`. Timestamps must be ISO-8601 UTC (`Z` or `+00:00`); other offsets are rejected.

All timestamps are UTC. Stage and freshness emitters accept optional timestamps and descriptions. **Do not pass tokens, credentials, full SQL text, or sensitive row values** in the status/message fields.

## 4. Dashboard views

| View | Grain | Purpose |
| --- | --- | --- |
| `v_health_summary` | Current pool | Executive operational summary |
| `v_run_history` | Invocation | Start, completion, pipeline/commit ID, missed completion |
| `v_pipeline_health` | Project × target | Latest invocation health and schedule staleness |
| `v_daily_trend` | Project × target × UTC day | Run success rate and duration trend |
| `v_node_history` | Invocation × node | Historical model/test execution details |
| `v_node_latest` | Project × target × node | Latest observed model/test result |
| `v_model_inventory` | Node at latest manifest deployment | Documentation and ownership inventory |
| `v_test_coverage` | Model/source | Tests attached to each node, has_owner |
| `v_model_health` | Model × observed project/target | Last status, testing/ownership, runtime |
| `v_test_failures` | Failed/warning test result | Recent test issues, including dbt unit tests |
| `v_duration_anomalies` | Successful model execution | Current time vs mean of 10 previous observed executions |
| `v_warehouse_requests` | Synapse recent query | Query queue/elapsed time, label, resource class |
| `v_warehouse_waits` | Current wait record | Wait type/state and request ID |
| `v_warehouse_pressure` | Current pool | Last 15 minutes' failed, running, suspended requests |
| `v_warehouse_history` | Sampled time | Pressure samples over time (no DMV permission needed) |
| `v_user_queries` | Synapse recent query | Who ran what: login, client app, status, timing, statement type (live DMV) |
| `v_query_history` | Sampled finished query | Persistent login-level query history from `sentinel_sample_requests` |
| `v_user_activity_daily` | Login × app × UTC day | Query counts, failures, elapsed and queue time per user |
| `v_table_storage` | Physical user table | Approximate rows and reserved MB |
| `v_table_skew` | Distributed user table | Rows per distribution, skew %, empty distributions, distribution column (live DMV) |
| `v_columnstore_health` | Columnstore table | Row-group count/size, small and memory-trimmed groups, delta-store and deleted % (live DMV) |
| `v_table_statistics` | User table | Statistics count/age and optimizer vs actual row-count drift (live DMV) |
| `v_table_health` | User table | The three checks combined, issue count and recommended fix (live DMV) |
| `v_table_health_history` | Table × sample | Daily table-health snapshots from `sentinel_sample_table_health` |
| `v_table_growth` | Table × sampled time | Row deltas and approximate growth percentages |
| `v_source_freshness` | Latest check per source × target | Last loaded time, status, age and threshold |
| `v_stage_health` | Latest pipeline/stage/source | Bronze/other stage health provided by orchestrator |
| `v_operational_alerts` | One alert occurrence | Latest unhealthy stages, runs, sources; failed tests in 24h |

DMV-backed views (need `VIEW DATABASE STATE`): `v_warehouse_requests`, `v_warehouse_waits`, `v_warehouse_pressure`, `v_table_storage`, `v_user_queries`, `v_table_skew`, `v_columnstore_health`, `v_table_statistics`, `v_table_health`. All others read only Sentinel tables.

Power BI can connect to **views only**, ideally via Import with scheduled refresh. Treat DMV views separately if live operational freshness is required; don't run unnecessarily frequent DirectQuery queries against a DW500 pool.

## 5. Dashboard pages

**Command centre:** overall state, recent run success, last completed job, outstanding test failures, source freshness and active warehouse requests.

**dbt performance:** duration trend by node, 10-run baseline, elapsed-time anomaly, executions by materialization, longest-running models.

**Data quality and governance:** pass/fail history, tests per Silver/Gold model, models without owners or documentation, sources not recently checked.

**Platform:** queue time, suspended requests, failed SQL requests, sampled pressure over time, storage distribution and growth by schema/table, table health (skew, columnstore quality, stale statistics) with recommended fixes.

**Pipeline flow:** Azure DevOps stage status across Landing → Bronze → `_SRC` → Silver → Gold, with recent failure stage, elapsed time and rows loaded for each source.

## 6. Security and operational considerations

- Use a dedicated deployment identity with `CREATE SCHEMA`, `CREATE TABLE`, `CREATE VIEW`, and write rights restricted to the Sentinel schema. Role implementation varies across deployments; test rights instead of giving blanket database ownership.
- Synapse monitoring DMVs require `VIEW DATABASE STATE` or `CONTROL`; prefer `VIEW DATABASE STATE`. That permission exposes information about workloads beyond the telemetry schema. Prefer a privileged, scheduled snapshot job and Power BI read-only access to pre-aggregated tables/views if access separation is strict.
- `sentinel_install` preserves telemetry tables and replaces view definitions (drop/create); run during an agreed deployment window to avoid a short Power BI object gap and reapply view-specific grants if needed.
- For a large number of executed nodes, the batch SQL hook adds compute overhead and can itself fail the dbt job. Tune `sentinel_batch_size` and retain `run_results.json` + `manifest.json` in Azure DevOps as a recovery source. A future high-volume release should bulk load artifacts rather than issue repeated insert batches.
- Never treat a blank source/pipeline event table as proof of health. It indicates missing integration. Provide an explicit signal/data-coverage indicator in the dashboard.
- Review retention, protection of error messages and query request metadata, operational access controls and service availability before using in production.

## 7. Validation and acceptance tests

Run static checks:

```shell
python tests/check_package.py            # needs jinja2; sqlglot optional for T-SQL parsing
python tests/check_package.py --dump-sql rendered_sql   # inspect every generated statement
```

With dbt-core, dbt-synapse and the unixODBC runtime installed, `tests/dbt_fake_pool.py` runs the real dbt CLI (install, build with a forced test failure, manifest sync, samplers, writers, purge, warn-mode resilience) against a fake connection that records SQL instead of sending it:

```shell
cd integration_tests
DBT_PROFILES_DIR=<dir with a synapse profile, authentication: sql> python ../tests/dbt_fake_pool.py
```

In a **development Synapse Dedicated SQL Pool** (scripted in `integration_tests/README.md` and `integration_tests/acceptance_queries.sql`) test: install twice (idempotent table creation), smoke-check views, run a passing model and a failing test, validate exactly one run row per invocation and corresponding result rows, resync manifest and check test coverage, schedule warehouse/storage snapshots, verify Power BI can query each view, and run a deliberately interrupted build to verify `missing_completion` handling. Test deployments under the precise dbt Core 1.12.6 + `dbt-synapse` adapter version and your real authentication method.

### SQL dialect and external references

- dbt 1.12 hooks: https://docs.getdbt.com/reference/project-configs/on-run-start-on-run-end
- dbt run artifacts: https://docs.getdbt.com/reference/artifacts/run-results-json
- Dedicated SQL Pool monitoring: https://learn.microsoft.com/en-us/azure/synapse-analytics/sql-data-warehouse/sql-data-warehouse-manage-monitor
- Dedicated SQL Pool T-SQL limits: https://learn.microsoft.com/en-us/sql/t-sql/statements/insert-transact-sql
- Dedicated SQL Pool DMV retention: https://learn.microsoft.com/en-us/azure/synapse-analytics/sql-data-warehouse/sql-data-warehouse-service-capacity-limits
