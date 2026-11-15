# dbt Sentinel - integration tests

Acceptance tests for a **development** Azure Synapse Dedicated SQL Pool. They
use their own telemetry schema (`sentinel_it_telemetry`) and model schema, so
they never touch production telemetry.

## Setup

```shell
cd integration_tests
cp profiles.yml.example ~/.dbt/profiles.yml   # then edit host/database/auth
dbt deps
dbt debug
```

## Steps

| # | Command | Verifies |
|---|---------|----------|
| 1 | `dbt run-operation sentinel_install` | schema, tables, views created |
| 2 | `dbt run-operation sentinel_install` | idempotent redeploy (no errors, telemetry kept) |
| 3 | `dbt run-operation sentinel_check` | every table/view queryable (DMV views warn without VIEW DATABASE STATE) |
| 4 | `dbt build` | passing model and tests; one start + one end event |
| 5 | `dbt build --vars '{sentinel_it_force_failure: true}'` | failing test recorded, run status `error` |
| 6 | `dbt run-operation sentinel_sync_manifest` | inventory, edges, test coverage |
| 7 | `dbt run-operation sentinel_sample_warehouse`, `sentinel_sample_storage`, `sentinel_sample_table_health`, then `sentinel_sample_requests` twice | DMV sampling; query history is incremental (second run adds only newer requests) |
| 8 | `dbt run-operation sentinel_record_stage --args '{pipeline_name: IT, pipeline_run_id: "1", stage: bronze, source_name: ABR, status: success, rows_loaded: 10}'` | stage writer |
| 9 | `dbt source freshness` then `python ../scripts/freshness_to_sentinel.py target/sources.json --execute` | freshness writer |
| 10 | Start `dbt build` and hard-kill the process once models start (`kill -9` / `Stop-Process -Force`), wait > 1 minute | `missing_completion` handling |
| 11 | `dbt run-operation sentinel_purge_history --args '{keep_days: 180, dry_run: true}'` | purge reports counts only |
| 12 | Run `acceptance_queries.sql` | expected results stated per query |
| 13 | Connect Power BI (Import) to every view | grants and drivers |

Repeat with the production authentication method (service principal or
managed identity) and the exact dbt Core / dbt-synapse versions you deploy.
