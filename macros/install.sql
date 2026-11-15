{#-
  dbt Sentinel - install.sql
  Table registry, idempotent installation/redeployment and the smoke check.

    dbt run-operation sentinel_install          create schema/tables, add new columns, redeploy views
    dbt run-operation sentinel_deploy_views     redeploy views only (after changing view vars)
    dbt run-operation sentinel_check            verify tables and views are queryable

  Telemetry tables are never dropped or truncated by these macros.
-#}

{% macro sentinel_table_columns() -%}
  {#- [column, type, nullable]. Single source of truth for DDL and inserts. -#}
  {{ return({
    'install_log': [
      ['package_version', 'nvarchar(32)', false],
      ['schema_version', 'int', false],
      ['installed_at_utc', 'datetime2(6)', false],
      ['invocation_id', 'nvarchar(64)', true],
      ['dbt_version', 'nvarchar(32)', true],
      ['project_name', 'nvarchar(256)', true],
      ['target_name', 'nvarchar(128)', true]
    ],
    'run_events': [
      ['invocation_id', 'nvarchar(64)', false],
      ['event_type', 'nvarchar(16)', false],
      ['event_at_utc', 'datetime2(6)', false],
      ['run_started_at_utc', 'datetime2(6)', true],
      ['command', 'nvarchar(32)', true],
      ['project_name', 'nvarchar(256)', true],
      ['target_name', 'nvarchar(128)', true],
      ['target_schema', 'nvarchar(256)', true],
      ['dbt_version', 'nvarchar(32)', true],
      ['run_status', 'nvarchar(32)', true],
      ['elapsed_seconds', 'float', true],
      ['nodes_total', 'int', true],
      ['nodes_success', 'int', true],
      ['nodes_error', 'int', true],
      ['nodes_fail', 'int', true],
      ['nodes_warn', 'int', true],
      ['nodes_skipped', 'int', true],
      ['selector', 'nvarchar(1000)', true],
      ['full_refresh', 'bit', true],
      ['pipeline_name', 'nvarchar(256)', true],
      ['pipeline_run_id', 'nvarchar(128)', true],
      ['commit_id', 'nvarchar(64)', true],
      ['branch_name', 'nvarchar(256)', true],
      ['build_reason', 'nvarchar(64)', true],
      ['recorded_at_utc', 'datetime2(6)', false]
    ],
    'node_results': [
      ['invocation_id', 'nvarchar(64)', false],
      ['project_name', 'nvarchar(256)', true],
      ['target_name', 'nvarchar(128)', true],
      ['unique_id', 'nvarchar(512)', false],
      ['resource_type', 'nvarchar(32)', true],
      ['node_name', 'nvarchar(256)', true],
      ['package_name', 'nvarchar(256)', true],
      ['schema_name', 'nvarchar(256)', true],
      ['alias_name', 'nvarchar(256)', true],
      ['materialized', 'nvarchar(64)', true],
      ['status', 'nvarchar(32)', true],
      ['execution_seconds', 'float', true],
      ['started_at_utc', 'datetime2(6)', true],
      ['completed_at_utc', 'datetime2(6)', true],
      ['rows_affected', 'bigint', true],
      ['failures', 'bigint', true],
      ['message', 'nvarchar(2000)', true],
      ['thread_id', 'nvarchar(64)', true],
      ['recorded_at_utc', 'datetime2(6)', false]
    ],
    'manifest_snapshots': [
      ['snapshot_id', 'nvarchar(64)', false],
      ['project_name', 'nvarchar(256)', true],
      ['target_name', 'nvarchar(128)', true],
      ['dbt_version', 'nvarchar(32)', true],
      ['node_count', 'int', true],
      ['edge_count', 'int', true],
      ['pipeline_run_id', 'nvarchar(128)', true],
      ['commit_id', 'nvarchar(64)', true],
      ['captured_at_utc', 'datetime2(6)', false]
    ],
    'manifest_nodes': [
      ['snapshot_id', 'nvarchar(64)', false],
      ['unique_id', 'nvarchar(512)', false],
      ['resource_type', 'nvarchar(32)', true],
      ['node_name', 'nvarchar(256)', true],
      ['package_name', 'nvarchar(256)', true],
      ['database_name', 'nvarchar(256)', true],
      ['schema_name', 'nvarchar(256)', true],
      ['alias_name', 'nvarchar(256)', true],
      ['materialized', 'nvarchar(64)', true],
      ['owner_name', 'nvarchar(256)', true],
      ['description', 'nvarchar(2000)', true],
      ['has_description', 'bit', true],
      ['tags', 'nvarchar(1000)', true],
      ['file_path', 'nvarchar(1000)', true],
      ['test_type', 'nvarchar(256)', true],
      ['attached_node', 'nvarchar(512)', true],
      ['source_name', 'nvarchar(256)', true],
      ['loaded_at_field', 'nvarchar(256)', true],
      ['has_freshness', 'bit', true]
    ],
    'manifest_edges': [
      ['snapshot_id', 'nvarchar(64)', false],
      ['parent_id', 'nvarchar(512)', false],
      ['child_id', 'nvarchar(512)', false]
    ],
    'warehouse_samples': [
      ['sampled_at_utc', 'datetime2(6)', false],
      ['running_requests', 'int', true],
      ['suspended_requests', 'int', true],
      ['failed_requests_15m', 'int', true],
      ['cancelled_requests_15m', 'int', true],
      ['completed_requests_15m', 'int', true],
      ['avg_queue_ms_15m', 'float', true],
      ['max_queue_ms_15m', 'bigint', true],
      ['longest_running_ms', 'bigint', true],
      ['queued_waits', 'int', true],
      ['active_sessions', 'int', true]
    ],
    'query_samples': [
      ['sampled_at_utc', 'datetime2(6)', false],
      ['request_id', 'nvarchar(32)', false],
      ['session_id', 'nvarchar(32)', true],
      ['login_name', 'nvarchar(256)', true],
      ['app_name', 'nvarchar(256)', true],
      ['status', 'nvarchar(32)', true],
      ['submit_time_utc', 'datetime2(3)', true],
      ['start_time_utc', 'datetime2(3)', true],
      ['end_time_utc', 'datetime2(3)', true],
      ['total_elapsed_ms', 'bigint', true],
      ['queue_ms', 'bigint', true],
      ['statement_type', 'nvarchar(32)', true],
      ['label', 'nvarchar(255)', true],
      ['resource_class', 'nvarchar(64)', true],
      ['importance', 'nvarchar(128)', true],
      ['group_name', 'nvarchar(128)', true],
      ['error_id', 'nvarchar(64)', true],
      ['result_cache_hit', 'int', true],
      ['command_text', 'nvarchar(4000)', true]
    ],
    'table_health_samples': [
      ['sampled_at_utc', 'datetime2(6)', false],
      ['schema_name', 'nvarchar(256)', false],
      ['table_name', 'nvarchar(256)', false],
      ['distribution_policy', 'nvarchar(64)', true],
      ['distribution_column', 'nvarchar(256)', true],
      ['index_type', 'nvarchar(64)', true],
      ['actual_row_count', 'bigint', true],
      ['skew_pct', 'float', true],
      ['empty_distributions', 'int', true],
      ['is_skewed', 'int', true],
      ['compressed_rowgroups', 'int', true],
      ['avg_rows_per_rowgroup', 'float', true],
      ['small_rowgroup_pct', 'float', true],
      ['delta_store_rows', 'bigint', true],
      ['deleted_rows_pct', 'float', true],
      ['is_poor_columnstore', 'int', true],
      ['stats_count', 'int', true],
      ['oldest_stats_update_utc', 'datetime2(3)', true],
      ['stats_row_count', 'bigint', true],
      ['stats_row_diff_pct', 'float', true],
      ['is_stale_stats', 'int', true],
      ['issue_count', 'int', true],
      ['recommendation', 'nvarchar(1000)', true]
    ],
    'storage_samples': [
      ['sampled_at_utc', 'datetime2(6)', false],
      ['schema_name', 'nvarchar(256)', false],
      ['table_name', 'nvarchar(256)', false],
      ['distribution_policy', 'nvarchar(64)', true],
      ['row_count', 'bigint', true],
      ['reserved_mb', 'decimal(19,3)', true],
      ['data_mb', 'decimal(19,3)', true],
      ['used_mb', 'decimal(19,3)', true]
    ],
    'stage_events': [
      ['pipeline_name', 'nvarchar(256)', false],
      ['pipeline_run_id', 'nvarchar(128)', true],
      ['stage', 'nvarchar(64)', false],
      ['source_name', 'nvarchar(256)', true],
      ['status', 'nvarchar(32)', false],
      ['rows_loaded', 'bigint', true],
      ['started_at_utc', 'datetime2(6)', true],
      ['completed_at_utc', 'datetime2(6)', true],
      ['event_at_utc', 'datetime2(6)', false],
      ['message', 'nvarchar(2000)', true],
      ['recorded_at_utc', 'datetime2(6)', false]
    ],
    'freshness_events': [
      ['source_id', 'nvarchar(512)', false],
      ['status', 'nvarchar(32)', false],
      ['max_loaded_at_utc', 'datetime2(6)', true],
      ['age_minutes', 'float', true],
      ['threshold_minutes', 'float', true],
      ['checked_at_utc', 'datetime2(6)', false],
      ['message', 'nvarchar(2000)', true],
      ['pipeline_run_id', 'nvarchar(128)', true],
      ['recorded_at_utc', 'datetime2(6)', false],
      ['project_name', 'nvarchar(256)', true],
      ['target_name', 'nvarchar(128)', true]
    ]
  }) }}
{%- endmacro %}

{% macro sentinel_table_index_clause() -%}
  {%- set idx = var('sentinel_table_index', 'HEAP') | string | upper -%}
  {%- if idx not in ['HEAP', 'CLUSTERED COLUMNSTORE INDEX'] -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: sentinel_table_index must be 'HEAP' or 'CLUSTERED COLUMNSTORE INDEX'.") }}
  {%- endif -%}
  {{ return(idx) }}
{%- endmacro %}

{% macro sentinel_create_table_sql(table_name) -%}
  {%- set defs = [] -%}
  {%- for c in dbt_sentinel.sentinel_table_columns()[table_name] -%}
    {%- do defs.append('    [' ~ c[0] ~ '] ' ~ c[1] ~ (' NULL' if c[2] else ' NOT NULL')) -%}
  {%- endfor -%}
  {%- set sql -%}
CREATE TABLE {{ dbt_sentinel.sentinel_rel(table_name) }} (
{{ defs | join(',\n') }}
)
WITH (DISTRIBUTION = ROUND_ROBIN, {{ dbt_sentinel.sentinel_table_index_clause() }})
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_existing_columns() -%}
  {#- {table_name_lower: [column_name_lower, ...]} for the Sentinel schema. -#}
  {%- set sql -%}
SELECT LOWER(t.name) AS table_name, LOWER(c.name) AS column_name
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.columns AS c ON c.object_id = t.object_id
WHERE s.name = {{ dbt_sentinel.sentinel_nstring(dbt_sentinel.sentinel_schema()) }}
  {%- endset -%}
  {%- set found = {} -%}
  {%- set res = run_query(sql) -%}
  {%- for row in res.rows -%}
    {%- if row[0] not in found -%}{%- do found.update({row[0]: []}) -%}{%- endif -%}
    {%- do found[row[0]].append(row[1]) -%}
  {%- endfor -%}
  {{ return(found) }}
{%- endmacro %}

{% macro sentinel_install() -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set schema = dbt_sentinel.sentinel_schema() -%}

  {#- 1. Schema (CREATE SCHEMA must be the only statement in its batch). -#}
  {%- set res = run_query('SELECT COUNT(*) AS n FROM sys.schemas WHERE name = ' ~ dbt_sentinel.sentinel_nstring(schema)) -%}
  {%- if (res.rows[0][0] | int) == 0 -%}
    {%- set auth = var('sentinel_schema_owner', none) -%}
    {% do run_query('CREATE SCHEMA [' ~ schema ~ ']' ~ ((' AUTHORIZATION ' ~ dbt_sentinel.sentinel_quote_name(auth, 'sentinel_schema_owner')) if auth else '')) %}
    {% do log('dbt_sentinel: created schema [' ~ schema ~ ']', info=true) %}
  {%- endif -%}

  {#- 2. Tables: create when missing, add new nullable columns when present. -#}
  {%- set existing = dbt_sentinel.sentinel_existing_columns() -%}
  {%- set ns = namespace(created=0, altered=0) -%}
  {%- for table_name, cols in dbt_sentinel.sentinel_table_columns().items() -%}
    {%- if table_name | lower not in existing -%}
      {% do run_query(dbt_sentinel.sentinel_create_table_sql(table_name)) %}
      {%- set ns.created = ns.created + 1 -%}
    {%- else -%}
      {%- for c in cols -%}
        {%- if c[0] | lower not in existing[table_name | lower] -%}
          {% do run_query('ALTER TABLE ' ~ dbt_sentinel.sentinel_rel(table_name) ~ ' ADD [' ~ c[0] ~ '] ' ~ c[1] ~ ' NULL') %}
          {% do log('dbt_sentinel: added column ' ~ table_name ~ '.' ~ c[0], info=true) %}
          {%- set ns.altered = ns.altered + 1 -%}
        {%- endif -%}
      {%- endfor -%}
    {%- endif -%}
  {%- endfor -%}
  {% do log('dbt_sentinel: tables created=' ~ ns.created ~ ', columns added=' ~ ns.altered ~ ' (existing telemetry preserved)', info=true) %}

  {#- 3. Views (drop/create). -#}
  {% do dbt_sentinel.sentinel_deploy_views() %}

  {#- 4. Install record. -#}
  {% do dbt_sentinel.sentinel_insert('install_log', [{
      'package_version': dbt_sentinel.sentinel_version(),
      'schema_version': dbt_sentinel.sentinel_schema_version(),
      'installed_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()'),
      'invocation_id': invocation_id,
      'dbt_version': dbt_version,
      'project_name': project_name,
      'target_name': target.name
  }], 'fail') %}
  {% do log('dbt_sentinel ' ~ dbt_sentinel.sentinel_version() ~ ' installed in schema [' ~ schema ~ ']. Next: dbt run-operation sentinel_sync_manifest', info=true) %}
{%- endmacro %}

{% macro sentinel_deploy_views() -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set names = dbt_sentinel.sentinel_view_names() -%}
  {#- Validate configuration and render every view before anything is dropped,
      so a bad var cannot leave the views missing or without their grants. -#}
  {%- set grantee = var('sentinel_view_reader_role', none) -%}
  {%- set grantee_sql = dbt_sentinel.sentinel_quote_name(grantee, 'sentinel_view_reader_role') if grantee else none -%}
  {%- set view_sql = {} -%}
  {%- for v in names -%}{%- do view_sql.update({v: dbt_sentinel.sentinel_view_sql(v)}) -%}{%- endfor -%}
  {#- Drop in reverse dependency order, create in dependency order. -#}
  {%- for v in names | reverse -%}
    {% do run_query("IF OBJECT_ID(N'" ~ dbt_sentinel.sentinel_rel(v) ~ "', N'V') IS NOT NULL DROP VIEW " ~ dbt_sentinel.sentinel_rel(v)) %}
  {%- endfor -%}
  {%- for v in names -%}
    {% do run_query('CREATE VIEW ' ~ dbt_sentinel.sentinel_rel(v) ~ ' AS\n' ~ view_sql[v]) %}
  {%- endfor -%}
  {%- if grantee_sql -%}
    {%- for v in names -%}
      {% do run_query('GRANT SELECT ON ' ~ dbt_sentinel.sentinel_rel(v) ~ ' TO ' ~ grantee_sql) %}
    {%- endfor -%}
  {%- endif -%}
  {% do log('dbt_sentinel: deployed ' ~ names | length ~ ' views' ~ ((' and granted SELECT to ' ~ grantee_sql) if grantee_sql else ''), info=true) %}
{%- endmacro %}

{% macro sentinel_check(include_dmv_views=true) -%}
  {#-
    Smoke check. Every table and view must be selectable. DMV-backed views need
    VIEW DATABASE STATE; their failures are reported as warnings so the check
    can run under a least-privilege identity (pass include_dmv_views=false to
    skip them).
  -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set dmv_views = dbt_sentinel.sentinel_dmv_view_names() -%}
  {%- set objects = [] -%}
  {%- for t in dbt_sentinel.sentinel_table_columns().keys() -%}{%- do objects.append(t) -%}{%- endfor -%}
  {%- for v in dbt_sentinel.sentinel_view_names() -%}
    {%- if include_dmv_views or v not in dmv_views -%}{%- do objects.append(v) -%}{%- endif -%}
  {%- endfor -%}

  {%- set existing_sql -%}
SELECT LOWER(o.name) AS object_name
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE s.name = {{ dbt_sentinel.sentinel_nstring(dbt_sentinel.sentinel_schema()) }} AND o.type IN ('U', 'V')
  {%- endset -%}
  {%- set present = [] -%}
  {%- for row in run_query(existing_sql).rows -%}{%- do present.append(row[0]) -%}{%- endfor -%}

  {%- set ns = namespace(missing=[], failed=[], warned=[]) -%}
  {%- for o in objects -%}
    {%- if o | lower not in present -%}
      {%- do ns.missing.append(o) -%}
    {%- else -%}
      {#- Assign to a variable so the probe emits no result set of its own
          (Synapse does not support SELECT @v = ..., hence SET). -#}
      {%- set probe = 'DECLARE @sentinel_probe int;\nSET @sentinel_probe = (SELECT COUNT(*) FROM (SELECT TOP 1 1 AS x FROM ' ~ dbt_sentinel.sentinel_rel(o) ~ ') AS probe)' -%}
      {%- if dbt_sentinel.sentinel_execute(probe, 'warn') -%}
        {% do log('dbt_sentinel check: ok   ' ~ o, info=true) %}
      {%- elif o in dmv_views -%}
        {%- do ns.warned.append(o) -%}
      {%- else -%}
        {%- do ns.failed.append(o) -%}
      {%- endif -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if ns.warned | length > 0 -%}
    {% do dbt_sentinel.sentinel_warn('dbt_sentinel check: DMV views not queryable by this identity (needs VIEW DATABASE STATE): ' ~ ns.warned | join(', ')) %}
  {%- endif -%}
  {%- if ns.missing | length > 0 or ns.failed | length > 0 -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel check FAILED. Missing: [' ~ ns.missing | join(', ') ~ '] Not queryable: [' ~ ns.failed | join(', ') ~ ']. Run sentinel_install.') }}
  {%- endif -%}
  {% do log('dbt_sentinel check passed: ' ~ (objects | length - ns.warned | length) ~ ' objects queryable in [' ~ dbt_sentinel.sentinel_schema() ~ ']', info=true) %}
{%- endmacro %}
