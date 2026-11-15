{#-
  dbt Sentinel - views.sql
  Managed, dashboard-ready view definitions (deployed by sentinel_install /
  sentinel_deploy_views). Thresholds from vars are rendered into the view text
  at deployment time: redeploy views after changing them.

  Written with derived tables rather than CTEs and without ORDER BY, CREATE OR
  ALTER or three-part names, to stay inside the Dedicated SQL Pool view subset.
  DMV-backed views (sentinel_dmv_view_names) require VIEW DATABASE STATE.
-#}

{% macro sentinel_view_names() -%}
  {#- Deployment (dependency) order. -#}
  {{ return([
      'v_run_history',
      'v_pipeline_health',
      'v_daily_trend',
      'v_node_history',
      'v_node_latest',
      'v_model_inventory',
      'v_test_coverage',
      'v_model_health',
      'v_test_failures',
      'v_duration_anomalies',
      'v_warehouse_requests',
      'v_warehouse_waits',
      'v_warehouse_pressure',
      'v_warehouse_history',
      'v_user_queries',
      'v_query_history',
      'v_user_activity_daily',
      'v_table_storage',
      'v_table_skew',
      'v_columnstore_health',
      'v_table_statistics',
      'v_table_health',
      'v_table_growth',
      'v_table_health_history',
      'v_source_freshness',
      'v_stage_health',
      'v_operational_alerts',
      'v_health_summary'
  ]) }}
{%- endmacro %}

{% macro sentinel_dmv_view_names() -%}
  {{ return(['v_warehouse_requests', 'v_warehouse_waits', 'v_warehouse_pressure', 'v_table_storage', 'v_user_queries',
              'v_table_skew', 'v_columnstore_health', 'v_table_statistics', 'v_table_health']) }}
{%- endmacro %}

{% macro sentinel_view_sql(name) -%}
  {%- if name == 'v_run_history' -%}{{ return(dbt_sentinel.sentinel_view_run_history()) }}
  {%- elif name == 'v_pipeline_health' -%}{{ return(dbt_sentinel.sentinel_view_pipeline_health()) }}
  {%- elif name == 'v_daily_trend' -%}{{ return(dbt_sentinel.sentinel_view_daily_trend()) }}
  {%- elif name == 'v_node_history' -%}{{ return(dbt_sentinel.sentinel_view_node_history()) }}
  {%- elif name == 'v_node_latest' -%}{{ return(dbt_sentinel.sentinel_view_node_latest()) }}
  {%- elif name == 'v_model_inventory' -%}{{ return(dbt_sentinel.sentinel_view_model_inventory()) }}
  {%- elif name == 'v_test_coverage' -%}{{ return(dbt_sentinel.sentinel_view_test_coverage()) }}
  {%- elif name == 'v_model_health' -%}{{ return(dbt_sentinel.sentinel_view_model_health()) }}
  {%- elif name == 'v_test_failures' -%}{{ return(dbt_sentinel.sentinel_view_test_failures()) }}
  {%- elif name == 'v_duration_anomalies' -%}{{ return(dbt_sentinel.sentinel_view_duration_anomalies()) }}
  {%- elif name == 'v_warehouse_requests' -%}{{ return(dbt_sentinel.sentinel_view_warehouse_requests()) }}
  {%- elif name == 'v_warehouse_waits' -%}{{ return(dbt_sentinel.sentinel_view_warehouse_waits()) }}
  {%- elif name == 'v_warehouse_pressure' -%}{{ return(dbt_sentinel.sentinel_view_warehouse_pressure()) }}
  {%- elif name == 'v_warehouse_history' -%}{{ return(dbt_sentinel.sentinel_view_warehouse_history()) }}
  {%- elif name == 'v_user_queries' -%}{{ return(dbt_sentinel.sentinel_view_user_queries()) }}
  {%- elif name == 'v_query_history' -%}{{ return(dbt_sentinel.sentinel_view_query_history()) }}
  {%- elif name == 'v_user_activity_daily' -%}{{ return(dbt_sentinel.sentinel_view_user_activity_daily()) }}
  {%- elif name == 'v_table_storage' -%}{{ return(dbt_sentinel.sentinel_view_table_storage()) }}
  {%- elif name == 'v_table_skew' -%}{{ return(dbt_sentinel.sentinel__table_skew_select()) }}
  {%- elif name == 'v_columnstore_health' -%}{{ return(dbt_sentinel.sentinel__columnstore_select()) }}
  {%- elif name == 'v_table_statistics' -%}{{ return(dbt_sentinel.sentinel__table_stats_select()) }}
  {%- elif name == 'v_table_health' -%}{{ return(dbt_sentinel.sentinel__table_health_select()) }}
  {%- elif name == 'v_table_health_history' -%}{{ return(dbt_sentinel.sentinel_view_table_health_history()) }}
  {%- elif name == 'v_table_growth' -%}{{ return(dbt_sentinel.sentinel_view_table_growth()) }}
  {%- elif name == 'v_source_freshness' -%}{{ return(dbt_sentinel.sentinel_view_source_freshness()) }}
  {%- elif name == 'v_stage_health' -%}{{ return(dbt_sentinel.sentinel_view_stage_health()) }}
  {%- elif name == 'v_operational_alerts' -%}{{ return(dbt_sentinel.sentinel_view_operational_alerts()) }}
  {%- elif name == 'v_health_summary' -%}{{ return(dbt_sentinel.sentinel_view_health_summary()) }}
  {%- else -%}{{ exceptions.raise_compiler_error('dbt_sentinel: unknown view ' ~ name) }}
  {%- endif -%}
{%- endmacro %}


{# ================================================================ shared SQL #}

{% macro sentinel__latest_snapshots_sql() -%}
  {#- Latest complete manifest snapshot per project x target. -#}
  {%- set sql -%}
SELECT ls.snapshot_id, ls.project_name, ls.target_name, ls.captured_at_utc
FROM (
    SELECT ms.snapshot_id, ms.project_name, ms.target_name, ms.captured_at_utc,
           ROW_NUMBER() OVER (PARTITION BY ms.project_name, ms.target_name ORDER BY ms.captured_at_utc DESC) AS rn
    FROM {{ dbt_sentinel.sentinel_rel('manifest_snapshots') }} AS ms
) AS ls
WHERE ls.rn = 1
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__test_links_sql() -%}
  {#- (snapshot_id, node_id, test_id, test_type): a test is linked to its
      attached_node when dbt recorded one, otherwise to each parent node.
      dbt unit tests ('unit_test', test_type 'unit') link to the model they
      depend on. -#}
  {%- set sql -%}
SELECT t.snapshot_id, t.attached_node AS node_id, t.unique_id AS test_id, t.test_type
FROM {{ dbt_sentinel.sentinel_rel('manifest_nodes') }} AS t
WHERE t.resource_type IN ('test', 'unit_test') AND t.attached_node IS NOT NULL
UNION ALL
SELECT e.snapshot_id, e.parent_id AS node_id, t.unique_id AS test_id, t.test_type
FROM {{ dbt_sentinel.sentinel_rel('manifest_edges') }} AS e
JOIN {{ dbt_sentinel.sentinel_rel('manifest_nodes') }} AS t
  ON t.snapshot_id = e.snapshot_id AND t.unique_id = e.child_id
WHERE t.resource_type IN ('test', 'unit_test') AND t.attached_node IS NULL
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__target_filter(alias) -%}
  {#- Optional var sentinel_summary_target limits v_health_summary to one target. -#}
  {%- set t = var('sentinel_summary_target', none) -%}
  {{ return(('(' ~ alias ~ '.target_name = ' ~ dbt_sentinel.sentinel_nstring(t) ~ ')') if t else '(1 = 1)') }}
{%- endmacro %}

{% macro sentinel__safe_ms(start_expr, end_expr) -%}
  {#- DATEDIFF(millisecond) overflows after ~24 days; return NULL beyond 20. -#}
  {{ return('CASE WHEN ' ~ start_expr ~ ' IS NULL THEN NULL WHEN DATEDIFF(day, ' ~ start_expr ~ ', ' ~ end_expr ~ ') > 20 THEN NULL ELSE CAST(DATEDIFF(millisecond, ' ~ start_expr ~ ', ' ~ end_expr ~ ') AS bigint) END') }}
{%- endmacro %}

{% macro sentinel__pressure_select() -%}
  {#- One row of current pool pressure. Shared by v_warehouse_pressure and
      sentinel_sample_warehouse. Excludes the observing session. -#}
  {%- set sql -%}
SELECT
    GETDATE() AS observed_at_utc,
    SUM(CASE WHEN r.status = 'Running' THEN 1 ELSE 0 END) AS running_requests,
    SUM(CASE WHEN r.status = 'Suspended' THEN 1 ELSE 0 END) AS suspended_requests,
    SUM(CASE WHEN r.status = 'Failed' AND r.end_time >= DATEADD(minute, -15, GETDATE()) THEN 1 ELSE 0 END) AS failed_requests_15m,
    SUM(CASE WHEN r.status = 'Cancelled' AND r.end_time >= DATEADD(minute, -15, GETDATE()) THEN 1 ELSE 0 END) AS cancelled_requests_15m,
    SUM(CASE WHEN r.status = 'Completed' AND r.end_time >= DATEADD(minute, -15, GETDATE()) THEN 1 ELSE 0 END) AS completed_requests_15m,
    AVG(CASE WHEN r.submit_time >= DATEADD(minute, -15, GETDATE()) AND r.start_time IS NOT NULL
             THEN CAST(DATEDIFF(millisecond, r.submit_time, r.start_time) AS float) END) AS avg_queue_ms_15m,
    MAX(CASE WHEN r.submit_time >= DATEADD(minute, -15, GETDATE())
             THEN {{ dbt_sentinel.sentinel__safe_ms('r.submit_time', 'COALESCE(r.start_time, GETDATE())') }} END) AS max_queue_ms_15m,
    MAX(CASE WHEN r.status = 'Running' THEN CAST(r.total_elapsed_time AS bigint) END) AS longest_running_ms,
    MAX(w.queued_waits) AS queued_waits,
    MAX(se.active_sessions) AS active_sessions
FROM sys.dm_pdw_exec_requests AS r
CROSS JOIN (
    SELECT SUM(CASE WHEN dw.state = 'Queued' THEN 1 ELSE 0 END) AS queued_waits
    FROM sys.dm_pdw_waits AS dw
    WHERE dw.session_id <> SESSION_ID()
) AS w
CROSS JOIN (
    SELECT SUM(CASE WHEN ds.status = 'ACTIVE' THEN 1 ELSE 0 END) AS active_sessions
    FROM sys.dm_pdw_exec_sessions AS ds
    WHERE ds.session_id <> SESSION_ID()
) AS se
WHERE r.session_id <> SESSION_ID()
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__requests_select(finished_only=false) -%}
  {#- Warehouse requests with the session's login and client application.
      Shared by v_user_queries and sentinel_sample_requests. Excludes the
      observing session, System sessions and var sentinel_query_exclude_logins.
      statement_type is the first keyword after any leading /* comment */ (such
      as dbt's query comment), so activity can be classified without storing
      SQL text. -#}
  {%- set capture = dbt_sentinel.sentinel_bool_var('sentinel_capture_query_text', false) -%}
  {%- set text_len = dbt_sentinel.sentinel_int_var('sentinel_query_text_max_length', 1000, 1) -%}
  {%- set excluded = ["N'System'"] -%}
  {%- for l in var('sentinel_query_exclude_logins', []) -%}{%- do excluded.append(dbt_sentinel.sentinel_nstring(l)) -%}{%- endfor -%}
  {%- set sql -%}
SELECT
    c.request_id,
    c.session_id,
    c.login_name,
    c.app_name,
    c.status,
    c.submit_time_utc,
    c.start_time_utc,
    c.end_time_utc,
    c.total_elapsed_ms,
    c.queue_ms,
    CAST(UPPER(LEFT(c.body, CHARINDEX(' ', c.body + ' ') - 1)) AS nvarchar(32)) AS statement_type,
    c.label,
    c.resource_class,
    c.importance,
    c.group_name,
    c.error_id,
    c.result_cache_hit,
    c.command_text
FROM (
    SELECT
        r.request_id,
        r.session_id,
        s.login_name,
        s.app_name,
        r.status,
        r.submit_time AS submit_time_utc,
        r.start_time AS start_time_utc,
        r.end_time AS end_time_utc,
        CAST(r.total_elapsed_time AS bigint) AS total_elapsed_ms,
        {{ dbt_sentinel.sentinel__safe_ms('r.submit_time', 'COALESCE(r.start_time, GETDATE())') }} AS queue_ms,
        LTRIM(REPLACE(REPLACE(REPLACE(
            CASE WHEN LTRIM(r.command) LIKE '/*%' AND CHARINDEX('*/', r.command) > 0
                 THEN SUBSTRING(r.command, CHARINDEX('*/', r.command) + 2, 4000)
                 ELSE COALESCE(r.command, N'') END,
            CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')) AS body,
        r.label,
        r.resource_class,
        r.importance,
        r.group_name,
        r.error_id,
        CAST(r.result_cache_hit AS int) AS result_cache_hit,
        {% if capture %}CAST(LEFT(r.command, {{ text_len }}) AS nvarchar(4000)){% else %}CAST(NULL AS nvarchar(4000)){% endif %} AS command_text
    FROM sys.dm_pdw_exec_requests AS r
    LEFT JOIN sys.dm_pdw_exec_sessions AS s
      ON s.session_id = r.session_id
    WHERE r.session_id <> SESSION_ID()
      AND COALESCE(s.login_name, N'') NOT IN ({{ excluded | join(', ') }})
      {% if finished_only %}AND r.status IN ('Completed', 'Failed', 'Cancelled') AND r.end_time IS NOT NULL{% endif %}
) AS c
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{# ------------------------------------------------- physical table health #}

{% macro sentinel__table_skew_select() -%}
  {#- Rows per distribution for HASH and ROUND_ROBIN tables (replicated
      tables have no distribution skew). skew_pct = 100 * (1 - avg/max): 0 is
      perfectly even; a value of 50 means the busiest distribution holds twice
      the average, so it works twice as long on every scan. -#}
  {%- set thr = dbt_sentinel.sentinel_float_var('sentinel_skew_threshold_pct', 10) -%}
  {%- set min_rows = dbt_sentinel.sentinel_int_var('sentinel_skew_min_rows', 1000000, 0) -%}
  {%- set sql -%}
SELECT
    k.schema_name,
    k.table_name,
    k.distribution_policy,
    k.distribution_column,
    k.actual_row_count,
    k.distributions,
    k.empty_distributions,
    k.min_distribution_rows,
    k.max_distribution_rows,
    k.avg_distribution_rows,
    k.skew_pct,
    CASE WHEN k.actual_row_count >= {{ min_rows }} AND k.skew_pct >= {{ thr }} THEN 1 ELSE 0 END AS is_skewed
FROM (
    SELECT
        d.schema_name,
        d.table_name,
        d.distribution_policy,
        d.distribution_column,
        SUM(d.dist_rows) AS actual_row_count,
        COUNT(*) AS distributions,
        SUM(CASE WHEN d.dist_rows = 0 THEN 1 ELSE 0 END) AS empty_distributions,
        MIN(d.dist_rows) AS min_distribution_rows,
        MAX(d.dist_rows) AS max_distribution_rows,
        AVG(CAST(d.dist_rows AS float)) AS avg_distribution_rows,
        CASE WHEN MAX(d.dist_rows) > 0
             THEN 100.0 * (1.0 - AVG(CAST(d.dist_rows AS float)) / MAX(d.dist_rows))
             ELSE 0 END AS skew_pct
    FROM (
        SELECT
            s.name AS schema_name,
            t.name AS table_name,
            tdp.distribution_policy_desc AS distribution_policy,
            dc.column_name AS distribution_column,
            nps.distribution_id,
            SUM(CASE WHEN nps.index_id < 2 THEN nps.row_count ELSE 0 END) AS dist_rows
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        JOIN sys.pdw_table_distribution_properties AS tdp ON tdp.object_id = t.object_id
        JOIN sys.pdw_table_mappings AS tm ON tm.object_id = t.object_id
        JOIN sys.pdw_nodes_tables AS nt ON nt.name = tm.physical_name
        JOIN sys.dm_pdw_nodes_db_partition_stats AS nps
          ON nps.object_id = nt.object_id
         AND nps.pdw_node_id = nt.pdw_node_id
         AND nps.distribution_id = nt.distribution_id
        LEFT JOIN (
            SELECT cdp.object_id, c.name AS column_name
            FROM sys.pdw_column_distribution_properties AS cdp
            JOIN sys.columns AS c ON c.object_id = cdp.object_id AND c.column_id = cdp.column_id
            WHERE cdp.distribution_ordinal = 1
        ) AS dc
          ON dc.object_id = t.object_id
        WHERE t.is_external = 0
          AND tdp.distribution_policy_desc <> 'REPLICATE'
        GROUP BY s.name, t.name, tdp.distribution_policy_desc, dc.column_name, nps.distribution_id
    ) AS d
    GROUP BY d.schema_name, d.table_name, d.distribution_policy, d.distribution_column
) AS k
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__columnstore_select() -%}
  {#- Clustered columnstore row-group quality. Ideal compressed row groups hold
      ~1,048,576 rows; small groups (memory pressure, trickle loads) and large
      delta stores or deleted fractions slow scans. Rebuild with a larger
      resource class to fix. Tables under sentinel_cci_min_table_rows cannot
      fill row groups across 60 distributions and are only flagged for
      delta-store or deleted-row problems. -#}
  {%- set small = dbt_sentinel.sentinel_int_var('sentinel_cci_small_rowgroup_rows', 100000, 1) -%}
  {%- set min_avg = dbt_sentinel.sentinel_int_var('sentinel_cci_min_avg_rows', 100000, 1) -%}
  {%- set min_table = dbt_sentinel.sentinel_int_var('sentinel_cci_min_table_rows', 6000000, 0) -%}
  {%- set max_delta = dbt_sentinel.sentinel_float_var('sentinel_cci_max_delta_pct', 10) -%}
  {%- set max_deleted = dbt_sentinel.sentinel_float_var('sentinel_cci_max_deleted_pct', 10) -%}
  {%- set sql -%}
SELECT
    c.schema_name,
    c.table_name,
    c.compressed_rowgroups,
    c.delta_rowgroups,
    c.small_rowgroups,
    c.memory_trimmed_rowgroups,
    c.total_rows,
    c.compressed_rows,
    c.delta_store_rows,
    c.deleted_rows,
    CAST(c.compressed_rows AS float) / NULLIF(c.compressed_rowgroups, 0) AS avg_rows_per_rowgroup,
    100.0 * c.small_rowgroups / NULLIF(c.compressed_rowgroups, 0) AS small_rowgroup_pct,
    100.0 * c.delta_store_rows / NULLIF(c.total_rows, 0) AS delta_store_pct,
    100.0 * c.deleted_rows / NULLIF(c.total_rows, 0) AS deleted_rows_pct,
    CASE
        WHEN c.total_rows >= {{ min_table }}
         AND CAST(c.compressed_rows AS float) / NULLIF(c.compressed_rowgroups, 0) < {{ min_avg }} THEN 1
        WHEN c.total_rows >= 1000000 AND 100.0 * c.delta_store_rows / NULLIF(c.total_rows, 0) >= {{ max_delta }} THEN 1
        WHEN c.total_rows > 0 AND 100.0 * c.deleted_rows / NULLIF(c.total_rows, 0) >= {{ max_deleted }} THEN 1
        ELSE 0
    END AS is_poor_columnstore
FROM (
    SELECT
        s.name AS schema_name,
        t.name AS table_name,
        SUM(CASE WHEN rg.state_desc = 'COMPRESSED' THEN 1 ELSE 0 END) AS compressed_rowgroups,
        SUM(CASE WHEN rg.state_desc IN ('OPEN', 'CLOSED') THEN 1 ELSE 0 END) AS delta_rowgroups,
        SUM(CASE WHEN rg.state_desc = 'COMPRESSED' AND rg.total_rows < {{ small }} THEN 1 ELSE 0 END) AS small_rowgroups,
        SUM(CASE WHEN rg.trim_reason_desc IN ('MEMORY_LIMITATION', 'DICTIONARY_SIZE') THEN 1 ELSE 0 END) AS memory_trimmed_rowgroups,
        SUM(CAST(rg.total_rows AS bigint)) AS total_rows,
        SUM(CASE WHEN rg.state_desc = 'COMPRESSED' THEN CAST(rg.total_rows AS bigint) ELSE 0 END) AS compressed_rows,
        SUM(CASE WHEN rg.state_desc IN ('OPEN', 'CLOSED') THEN CAST(rg.total_rows AS bigint) ELSE 0 END) AS delta_store_rows,
        SUM(CAST(COALESCE(rg.deleted_rows, 0) AS bigint)) AS deleted_rows
    FROM sys.dm_pdw_nodes_db_column_store_row_group_physical_stats AS rg
    JOIN sys.pdw_nodes_tables AS nt
      ON nt.object_id = rg.object_id
     AND nt.pdw_node_id = rg.pdw_node_id
     AND nt.distribution_id = rg.distribution_id
    JOIN sys.pdw_table_mappings AS tm ON tm.physical_name = nt.name
    JOIN sys.tables AS t ON t.object_id = tm.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE rg.state_desc <> 'TOMBSTONE'
    GROUP BY s.name, t.name
) AS c
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__table_stats_select() -%}
  {#- Statistics freshness. Dedicated SQL Pool can auto-create but does not
      auto-update statistics, so after loads the optimizer's row count (control
      node, sys.partitions) drifts from the real row count (compute nodes).
      Replicated tables are excluded from the drift comparison. -#}
  {%- set diff = dbt_sentinel.sentinel_float_var('sentinel_stats_max_diff_pct', 20) -%}
  {%- set min_rows = dbt_sentinel.sentinel_int_var('sentinel_stats_min_rows', 1000, 0) -%}
  {%- set sql -%}
SELECT
    x.schema_name,
    x.table_name,
    x.distribution_policy,
    x.index_type,
    x.actual_row_count,
    x.stats_row_count,
    x.stats_row_diff_pct,
    x.stats_count,
    x.oldest_stats_update_utc,
    x.newest_stats_update_utc,
    DATEDIFF(day, x.oldest_stats_update_utc, GETDATE()) AS oldest_stats_age_days,
    CASE
        WHEN COALESCE(x.actual_row_count, 0) < {{ min_rows }} THEN 0
        WHEN COALESCE(x.stats_count, 0) = 0 THEN 1
        WHEN x.stats_row_diff_pct >= {{ diff }} THEN 1
        ELSE 0
    END AS is_stale_stats
FROM (
    SELECT
        s.name AS schema_name,
        t.name AS table_name,
        tdp.distribution_policy_desc AS distribution_policy,
        ix.type_desc AS index_type,
        act.actual_row_count,
        cmp.stats_row_count,
        CASE WHEN tdp.distribution_policy_desc = 'REPLICATE' THEN NULL
             ELSE 100.0 * ABS(CAST(act.actual_row_count AS float) - COALESCE(cmp.stats_row_count, 0))
                  / NULLIF(act.actual_row_count, 0) END AS stats_row_diff_pct,
        COALESCE(st.stats_count, 0) AS stats_count,
        st.oldest_stats_update_utc,
        st.newest_stats_update_utc
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    JOIN sys.pdw_table_distribution_properties AS tdp ON tdp.object_id = t.object_id
    LEFT JOIN sys.indexes AS ix ON ix.object_id = t.object_id AND ix.index_id < 2
    LEFT JOIN (
        SELECT so.object_id, COUNT(*) AS stats_count,
               MIN(STATS_DATE(so.object_id, so.stats_id)) AS oldest_stats_update_utc,
               MAX(STATS_DATE(so.object_id, so.stats_id)) AS newest_stats_update_utc
        FROM sys.stats AS so
        GROUP BY so.object_id
    ) AS st
      ON st.object_id = t.object_id
    LEFT JOIN (
        SELECT idx.object_id, SUM(prt.rows) AS stats_row_count
        FROM sys.indexes AS idx
        JOIN sys.partitions AS prt ON prt.object_id = idx.object_id AND prt.index_id = idx.index_id
        WHERE idx.index_id < 2
        GROUP BY idx.object_id
    ) AS cmp
      ON cmp.object_id = t.object_id
    LEFT JOIN (
        SELECT tm.object_id, SUM(nps.row_count) AS actual_row_count
        FROM sys.pdw_table_mappings AS tm
        JOIN sys.pdw_nodes_tables AS nt ON nt.name = tm.physical_name
        JOIN sys.dm_pdw_nodes_db_partition_stats AS nps
          ON nps.object_id = nt.object_id
         AND nps.pdw_node_id = nt.pdw_node_id
         AND nps.distribution_id = nt.distribution_id
        WHERE nps.index_id < 2
        GROUP BY tm.object_id
    ) AS act
      ON act.object_id = t.object_id
    WHERE t.is_external = 0
) AS x
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__table_health_select() -%}
  {#- One row per user table combining the three checks, with a plain-language
      recommendation. Shared by v_table_health and sentinel_sample_table_health. -#}
  {%- set sql -%}
SELECT
    h.schema_name,
    h.table_name,
    h.distribution_policy,
    h.distribution_column,
    h.index_type,
    h.actual_row_count,
    h.skew_pct,
    h.empty_distributions,
    h.is_skewed,
    h.compressed_rowgroups,
    h.avg_rows_per_rowgroup,
    h.small_rowgroup_pct,
    h.delta_store_rows,
    h.deleted_rows_pct,
    h.is_poor_columnstore,
    h.stats_count,
    h.oldest_stats_update_utc,
    h.stats_row_count,
    h.stats_row_diff_pct,
    h.is_stale_stats,
    h.is_skewed + h.is_poor_columnstore + h.is_stale_stats AS issue_count,
    CAST(NULLIF(LTRIM(RTRIM(
        CASE WHEN h.is_skewed = 1
             THEN N'Distribution skew ' + CAST(CAST(ROUND(h.skew_pct, 0) AS int) AS nvarchar(10))
                  + N'%: review the distribution column' + COALESCE(N' (' + h.distribution_column + N')', N'')
                  + N' for a higher-cardinality, evenly spread key. ' ELSE N'' END
      + CASE WHEN h.is_poor_columnstore = 1
             THEN N'Columnstore quality: rebuild (ALTER INDEX ALL ON [' + h.schema_name + N'].[' + h.table_name
                  + N'] REBUILD) under a larger resource class. ' ELSE N'' END
      + CASE WHEN h.is_stale_stats = 1
             THEN N'Statistics stale or missing: UPDATE STATISTICS [' + h.schema_name + N'].[' + h.table_name + N']. ' ELSE N'' END
    )), N'') AS nvarchar(1000)) AS recommendation
FROM (
    SELECT
        b.schema_name,
        b.table_name,
        b.distribution_policy,
        k.distribution_column,
        b.index_type,
        b.actual_row_count,
        k.skew_pct,
        k.empty_distributions,
        COALESCE(k.is_skewed, 0) AS is_skewed,
        c.compressed_rowgroups,
        c.avg_rows_per_rowgroup,
        c.small_rowgroup_pct,
        c.delta_store_rows,
        c.deleted_rows_pct,
        COALESCE(c.is_poor_columnstore, 0) AS is_poor_columnstore,
        b.stats_count,
        b.oldest_stats_update_utc,
        b.stats_row_count,
        b.stats_row_diff_pct,
        b.is_stale_stats
    FROM (
{{ dbt_sentinel.sentinel__table_stats_select() }}
    ) AS b
    LEFT JOIN (
{{ dbt_sentinel.sentinel__table_skew_select() }}
    ) AS k
      ON k.schema_name = b.schema_name AND k.table_name = b.table_name
    LEFT JOIN (
{{ dbt_sentinel.sentinel__columnstore_select() }}
    ) AS c
      ON c.schema_name = b.schema_name AND c.table_name = b.table_name
) AS h
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel__storage_select() -%}
  {#- Physical user-table size from the distribution-level DMV. Replicated
      tables can include cached per-node copies, so treat them as approximate. -#}
  {%- set sql -%}
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    tdp.distribution_policy_desc AS distribution_policy,
    CASE WHEN tdp.distribution_policy_desc = 'REPLICATE' THEN 1 ELSE 0 END AS is_replicated,
    SUM(CASE WHEN nps.index_id < 2 THEN nps.row_count ELSE 0 END) AS approximate_row_count,
    CAST(SUM(nps.reserved_page_count) * 8.0 / 1024 AS decimal(19, 3)) AS reserved_mb,
    CAST(SUM(nps.in_row_data_page_count + nps.lob_used_page_count + nps.row_overflow_used_page_count) * 8.0 / 1024 AS decimal(19, 3)) AS data_mb,
    CAST(SUM(nps.used_page_count) * 8.0 / 1024 AS decimal(19, 3)) AS used_mb
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.pdw_table_distribution_properties AS tdp ON tdp.object_id = t.object_id
JOIN sys.pdw_table_mappings AS tm ON tm.object_id = t.object_id
JOIN sys.pdw_nodes_tables AS nt ON nt.name = tm.physical_name
JOIN sys.dm_pdw_nodes_db_partition_stats AS nps
  ON nps.object_id = nt.object_id
 AND nps.pdw_node_id = nt.pdw_node_id
 AND nps.distribution_id = nt.distribution_id
WHERE t.is_external = 0
GROUP BY s.name, t.name, tdp.distribution_policy_desc
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}


{# ===================================================================== views #}

{% macro sentinel_view_run_history() -%}
  {%- set mins = dbt_sentinel.sentinel_int_var('sentinel_missing_completion_minutes', 120, 1) -%}
  {%- set sql -%}
SELECT
    COALESCE(s.invocation_id, e.invocation_id) AS invocation_id,
    COALESCE(s.project_name, e.project_name) AS project_name,
    COALESCE(s.target_name, e.target_name) AS target_name,
    COALESCE(s.target_schema, e.target_schema) AS target_schema,
    COALESCE(s.command, e.command) AS command,
    COALESCE(s.dbt_version, e.dbt_version) AS dbt_version,
    COALESCE(s.run_started_at_utc, e.run_started_at_utc, s.event_at_utc) AS started_at_utc,
    e.event_at_utc AS completed_at_utc,
    CASE
        WHEN e.invocation_id IS NOT NULL THEN COALESCE(e.run_status, 'unknown')
        WHEN DATEDIFF(minute, s.event_at_utc, SYSUTCDATETIME()) >= {{ mins }} THEN 'missing_completion'
        ELSE 'running'
    END AS run_status,
    CASE WHEN e.invocation_id IS NULL AND DATEDIFF(minute, s.event_at_utc, SYSUTCDATETIME()) >= {{ mins }} THEN 1 ELSE 0 END AS is_missing_completion,
    CASE
        WHEN e.run_status = 'error' THEN 1
        WHEN e.invocation_id IS NULL AND DATEDIFF(minute, s.event_at_utc, SYSUTCDATETIME()) >= {{ mins }} THEN 1
        ELSE 0
    END AS is_failure,
    CASE WHEN s.invocation_id IS NULL THEN 1 ELSE 0 END AS is_missing_start,
    e.elapsed_seconds,
    e.nodes_total,
    e.nodes_success,
    e.nodes_error,
    e.nodes_fail,
    e.nodes_warn,
    e.nodes_skipped,
    COALESCE(s.selector, e.selector) AS selector,
    COALESCE(s.full_refresh, e.full_refresh) AS full_refresh,
    COALESCE(s.pipeline_name, e.pipeline_name) AS pipeline_name,
    COALESCE(s.pipeline_run_id, e.pipeline_run_id) AS pipeline_run_id,
    COALESCE(s.commit_id, e.commit_id) AS commit_id,
    COALESCE(s.branch_name, e.branch_name) AS branch_name,
    COALESCE(s.build_reason, e.build_reason) AS build_reason
FROM (
    SELECT x.*
    FROM (
        SELECT re.*, ROW_NUMBER() OVER (PARTITION BY re.invocation_id ORDER BY re.event_at_utc ASC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('run_events') }} AS re
        WHERE re.event_type = 'start'
    ) AS x
    WHERE x.rn = 1
) AS s
FULL OUTER JOIN (
    SELECT y.*
    FROM (
        SELECT re.*, ROW_NUMBER() OVER (PARTITION BY re.invocation_id ORDER BY re.event_at_utc DESC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('run_events') }} AS re
        WHERE re.event_type = 'end'
    ) AS y
    WHERE y.rn = 1
) AS e
  ON e.invocation_id = s.invocation_id
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_pipeline_health() -%}
  {%- set stale_minutes = (dbt_sentinel.sentinel_float_var('sentinel_run_stale_hours', 26) * 60) | int -%}
  {%- set sql -%}
SELECT
    l.project_name,
    l.target_name,
    l.invocation_id AS latest_invocation_id,
    l.command AS latest_command,
    l.started_at_utc AS latest_started_at_utc,
    l.completed_at_utc AS latest_completed_at_utc,
    l.run_status AS latest_run_status,
    l.elapsed_seconds AS latest_elapsed_seconds,
    l.pipeline_run_id AS latest_pipeline_run_id,
    l.commit_id AS latest_commit_id,
    a.last_success_at_utc,
    a.last_completed_at_utc,
    a.runs_24h,
    a.failed_runs_24h,
    a.missing_completions_24h,
    CAST(DATEDIFF(minute, a.last_success_at_utc, SYSUTCDATETIME()) AS float) / 60.0 AS hours_since_last_success,
    CASE WHEN a.last_success_at_utc IS NULL OR DATEDIFF(minute, a.last_success_at_utc, SYSUTCDATETIME()) > {{ stale_minutes }} THEN 1 ELSE 0 END AS is_stale,
    CASE
        WHEN l.run_status IN ('error', 'missing_completion') THEN 'unhealthy'
        WHEN a.last_success_at_utc IS NULL OR DATEDIFF(minute, a.last_success_at_utc, SYSUTCDATETIME()) > {{ stale_minutes }} THEN 'stale'
        WHEN l.run_status = 'warn' THEN 'warning'
        WHEN l.run_status = 'running' THEN 'running'
        ELSE 'healthy'
    END AS health_state
FROM (
    SELECT h.*, ROW_NUMBER() OVER (PARTITION BY h.project_name, h.target_name ORDER BY h.started_at_utc DESC) AS rn
    FROM {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS h
) AS l
JOIN (
    SELECT
        h.project_name,
        h.target_name,
        MAX(CASE WHEN h.run_status IN ('success', 'warn') THEN h.completed_at_utc END) AS last_success_at_utc,
        MAX(h.completed_at_utc) AS last_completed_at_utc,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) AND h.is_failure = 1 THEN 1 ELSE 0 END) AS failed_runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) AND h.is_missing_completion = 1 THEN 1 ELSE 0 END) AS missing_completions_24h
    FROM {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS h
    GROUP BY h.project_name, h.target_name
) AS a
  ON a.project_name = l.project_name AND a.target_name = l.target_name
WHERE l.rn = 1
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_daily_trend() -%}
  {%- set sql -%}
SELECT
    h.project_name,
    h.target_name,
    CAST(h.started_at_utc AS date) AS run_date_utc,
    COUNT(*) AS runs,
    SUM(CASE WHEN h.run_status IN ('success', 'warn') THEN 1 ELSE 0 END) AS successful_runs,
    SUM(CASE WHEN h.run_status = 'error' THEN 1 ELSE 0 END) AS failed_runs,
    SUM(h.is_missing_completion) AS missing_completion_runs,
    CAST(SUM(CASE WHEN h.run_status IN ('success', 'warn') THEN 1 ELSE 0 END) AS float)
        / NULLIF(SUM(CASE WHEN h.run_status <> 'running' THEN 1 ELSE 0 END), 0) AS success_rate,
    AVG(h.elapsed_seconds) AS avg_elapsed_seconds,
    MAX(h.elapsed_seconds) AS max_elapsed_seconds,
    SUM(COALESCE(h.nodes_total, 0)) AS nodes_executed,
    SUM(COALESCE(h.nodes_error, 0) + COALESCE(h.nodes_fail, 0)) AS node_failures
FROM {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS h
GROUP BY h.project_name, h.target_name, CAST(h.started_at_utc AS date)
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_node_history() -%}
  {%- set sql -%}
SELECT
    n.invocation_id,
    n.project_name,
    n.target_name,
    n.unique_id,
    n.resource_type,
    n.node_name,
    n.package_name,
    n.schema_name,
    n.alias_name,
    n.materialized,
    n.status,
    CASE WHEN n.status IN ('error', 'fail') THEN 1 ELSE 0 END AS is_failure,
    n.execution_seconds,
    n.started_at_utc,
    n.completed_at_utc,
    COALESCE(n.completed_at_utc, n.recorded_at_utc) AS observed_at_utc,
    n.rows_affected,
    n.failures,
    n.message,
    n.thread_id,
    r.command,
    r.started_at_utc AS run_started_at_utc,
    r.pipeline_name,
    r.pipeline_run_id,
    r.commit_id,
    r.branch_name
FROM {{ dbt_sentinel.sentinel_rel('node_results') }} AS n
LEFT JOIN {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS r
  ON r.invocation_id = n.invocation_id
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_node_latest() -%}
  {%- set sql -%}
SELECT
    l.project_name,
    l.target_name,
    l.unique_id,
    l.resource_type,
    l.node_name,
    l.schema_name,
    l.materialized,
    l.invocation_id AS latest_invocation_id,
    l.status,
    l.execution_seconds,
    l.observed_at_utc,
    l.rows_affected,
    l.failures,
    l.message,
    a.executions,
    a.last_success_at_utc,
    a.last_failure_at_utc
FROM (
    SELECT n.*, COALESCE(n.completed_at_utc, n.recorded_at_utc) AS observed_at_utc,
           ROW_NUMBER() OVER (PARTITION BY n.project_name, n.target_name, n.unique_id
                              ORDER BY COALESCE(n.completed_at_utc, n.recorded_at_utc) DESC, n.recorded_at_utc DESC) AS rn
    FROM {{ dbt_sentinel.sentinel_rel('node_results') }} AS n
    WHERE n.status <> 'skipped'
) AS l
JOIN (
    SELECT
        n.project_name,
        n.target_name,
        n.unique_id,
        COUNT(*) AS executions,
        MAX(CASE WHEN n.status IN ('success', 'pass') THEN COALESCE(n.completed_at_utc, n.recorded_at_utc) END) AS last_success_at_utc,
        MAX(CASE WHEN n.status IN ('error', 'fail') THEN COALESCE(n.completed_at_utc, n.recorded_at_utc) END) AS last_failure_at_utc
    FROM {{ dbt_sentinel.sentinel_rel('node_results') }} AS n
    WHERE n.status <> 'skipped'
    GROUP BY n.project_name, n.target_name, n.unique_id
) AS a
  ON a.project_name = l.project_name AND a.target_name = l.target_name AND a.unique_id = l.unique_id
WHERE l.rn = 1
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_model_inventory() -%}
  {%- set sql -%}
SELECT
    ls.snapshot_id,
    ls.captured_at_utc AS manifest_captured_at_utc,
    ls.project_name,
    ls.target_name,
    m.unique_id,
    m.resource_type,
    m.node_name,
    m.package_name,
    m.database_name,
    m.schema_name,
    m.alias_name,
    m.materialized,
    m.owner_name,
    CASE WHEN m.owner_name IS NULL OR LTRIM(RTRIM(m.owner_name)) = '' THEN 0 ELSE 1 END AS has_owner,
    CAST(COALESCE(m.has_description, 0) AS int) AS has_description,
    m.description,
    m.tags,
    m.file_path,
    m.test_type,
    m.attached_node,
    m.source_name,
    m.loaded_at_field,
    CAST(COALESCE(m.has_freshness, 0) AS int) AS has_freshness,
    COALESCE(up.upstream_count, 0) AS upstream_count,
    COALESCE(dn.downstream_count, 0) AS downstream_count,
    COALESCE(tl.test_count, 0) AS test_count
FROM {{ dbt_sentinel.sentinel_rel('manifest_nodes') }} AS m
JOIN (
{{ dbt_sentinel.sentinel__latest_snapshots_sql() }}
) AS ls
  ON ls.snapshot_id = m.snapshot_id
LEFT JOIN (
    SELECT e.snapshot_id, e.child_id, COUNT(*) AS upstream_count
    FROM {{ dbt_sentinel.sentinel_rel('manifest_edges') }} AS e
    GROUP BY e.snapshot_id, e.child_id
) AS up
  ON up.snapshot_id = m.snapshot_id AND up.child_id = m.unique_id
LEFT JOIN (
    SELECT e.snapshot_id, e.parent_id, COUNT(*) AS downstream_count
    FROM {{ dbt_sentinel.sentinel_rel('manifest_edges') }} AS e
    JOIN {{ dbt_sentinel.sentinel_rel('manifest_nodes') }} AS c
      ON c.snapshot_id = e.snapshot_id AND c.unique_id = e.child_id
    WHERE c.resource_type NOT IN ('test', 'unit_test')
    GROUP BY e.snapshot_id, e.parent_id
) AS dn
  ON dn.snapshot_id = m.snapshot_id AND dn.parent_id = m.unique_id
LEFT JOIN (
    SELECT k.snapshot_id, k.node_id, COUNT(DISTINCT k.test_id) AS test_count
    FROM (
{{ dbt_sentinel.sentinel__test_links_sql() }}
    ) AS k
    GROUP BY k.snapshot_id, k.node_id
) AS tl
  ON tl.snapshot_id = m.snapshot_id AND tl.node_id = m.unique_id
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_test_coverage() -%}
  {%- set sql -%}
SELECT
    i.project_name,
    i.target_name,
    i.snapshot_id,
    i.unique_id,
    i.resource_type,
    i.node_name,
    i.schema_name,
    i.materialized,
    i.owner_name,
    i.has_owner,
    i.has_description,
    COALESCE(c.test_count, 0) AS test_count,
    COALESCE(c.unique_tests, 0) AS unique_tests,
    COALESCE(c.not_null_tests, 0) AS not_null_tests,
    COALESCE(c.relationships_tests, 0) AS relationships_tests,
    COALESCE(c.accepted_values_tests, 0) AS accepted_values_tests,
    COALESCE(c.singular_tests, 0) AS singular_tests,
    COALESCE(c.other_generic_tests, 0) AS other_generic_tests,
    CASE WHEN COALESCE(c.test_count, 0) > 0 THEN 1 ELSE 0 END AS has_tests,
    COALESCE(c.unit_tests, 0) AS unit_tests
FROM {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS i
LEFT JOIN (
    SELECT
        d.snapshot_id,
        d.node_id,
        COUNT(*) AS test_count,
        SUM(CASE WHEN d.test_type = 'unique' THEN 1 ELSE 0 END) AS unique_tests,
        SUM(CASE WHEN d.test_type = 'not_null' THEN 1 ELSE 0 END) AS not_null_tests,
        SUM(CASE WHEN d.test_type = 'relationships' THEN 1 ELSE 0 END) AS relationships_tests,
        SUM(CASE WHEN d.test_type = 'accepted_values' THEN 1 ELSE 0 END) AS accepted_values_tests,
        SUM(CASE WHEN d.test_type = 'singular' THEN 1 ELSE 0 END) AS singular_tests,
        SUM(CASE WHEN d.test_type NOT IN ('unique', 'not_null', 'relationships', 'accepted_values', 'singular', 'unit') THEN 1 ELSE 0 END) AS other_generic_tests,
        SUM(CASE WHEN d.test_type = 'unit' THEN 1 ELSE 0 END) AS unit_tests
    FROM (
        SELECT DISTINCT k.snapshot_id, k.node_id, k.test_id, COALESCE(k.test_type, 'singular') AS test_type
        FROM (
{{ dbt_sentinel.sentinel__test_links_sql() }}
        ) AS k
    ) AS d
    GROUP BY d.snapshot_id, d.node_id
) AS c
  ON c.snapshot_id = i.snapshot_id AND c.node_id = i.unique_id
WHERE i.resource_type IN ('model', 'source', 'seed', 'snapshot')
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_model_health() -%}
  {%- set sql -%}
SELECT
    i.project_name,
    i.target_name,
    i.unique_id,
    i.node_name,
    i.schema_name,
    i.materialized,
    i.owner_name,
    i.has_owner,
    i.has_description,
    i.test_count,
    nl.status AS last_status,
    nl.observed_at_utc AS last_run_at_utc,
    nl.execution_seconds AS last_execution_seconds,
    nl.last_success_at_utc,
    nl.last_failure_at_utc,
    perf.avg_execution_seconds_10,
    perf.max_execution_seconds_10,
    COALESCE(tf.failing_tests, 0) AS failing_tests,
    COALESCE(tf.warning_tests, 0) AS warning_tests,
    CASE
        WHEN nl.status = 'error' OR COALESCE(tf.failing_tests, 0) > 0 THEN 'unhealthy'
        WHEN nl.status IS NULL THEN 'not_run'
        WHEN COALESCE(tf.warning_tests, 0) > 0 THEN 'warning'
        ELSE 'healthy'
    END AS health_state
FROM {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS i
LEFT JOIN {{ dbt_sentinel.sentinel_rel('v_node_latest') }} AS nl
  ON nl.project_name = i.project_name AND nl.target_name = i.target_name AND nl.unique_id = i.unique_id
LEFT JOIN (
    SELECT p.project_name, p.target_name, p.unique_id,
           AVG(p.execution_seconds) AS avg_execution_seconds_10,
           MAX(p.execution_seconds) AS max_execution_seconds_10
    FROM (
        SELECT n.project_name, n.target_name, n.unique_id, n.execution_seconds,
               ROW_NUMBER() OVER (PARTITION BY n.project_name, n.target_name, n.unique_id
                                  ORDER BY COALESCE(n.completed_at_utc, n.recorded_at_utc) DESC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('node_results') }} AS n
        WHERE n.resource_type = 'model' AND n.status = 'success'
    ) AS p
    WHERE p.rn <= 10
    GROUP BY p.project_name, p.target_name, p.unique_id
) AS perf
  ON perf.project_name = i.project_name AND perf.target_name = i.target_name AND perf.unique_id = i.unique_id
LEFT JOIN (
    SELECT k.snapshot_id, k.node_id,
           SUM(CASE WHEN tl.status IN ('fail', 'error') THEN 1 ELSE 0 END) AS failing_tests,
           SUM(CASE WHEN tl.status = 'warn' THEN 1 ELSE 0 END) AS warning_tests
    FROM (
        SELECT DISTINCT k0.snapshot_id, k0.node_id, k0.test_id
        FROM (
{{ dbt_sentinel.sentinel__test_links_sql() }}
        ) AS k0
    ) AS k
    JOIN (
{{ dbt_sentinel.sentinel__latest_snapshots_sql() }}
    ) AS ls
      ON ls.snapshot_id = k.snapshot_id
    JOIN {{ dbt_sentinel.sentinel_rel('v_node_latest') }} AS tl
      ON tl.project_name = ls.project_name AND tl.target_name = ls.target_name AND tl.unique_id = k.test_id
    GROUP BY k.snapshot_id, k.node_id
) AS tf
  ON tf.snapshot_id = i.snapshot_id AND tf.node_id = i.unique_id
WHERE i.resource_type = 'model'
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_test_failures() -%}
  {%- set days = dbt_sentinel.sentinel_int_var('sentinel_test_failure_days', 30, 1) -%}
  {%- set sql -%}
SELECT
    h.invocation_id,
    h.project_name,
    h.target_name,
    h.unique_id AS test_id,
    h.node_name AS test_name,
    h.status,
    CASE WHEN h.status = 'warn' THEN 'warn' ELSE 'error' END AS severity,
    h.failures,
    h.message,
    h.execution_seconds,
    h.observed_at_utc,
    h.command,
    h.pipeline_run_id,
    h.commit_id,
    COALESCE(ti.test_type, CASE WHEN h.resource_type = 'unit_test' THEN 'unit' END) AS test_type,
    COALESCE(ti.attached_node, ue.parent_id) AS tested_node_id,
    tn.node_name AS tested_node_name,
    tn.resource_type AS tested_resource_type,
    tn.owner_name AS tested_node_owner
FROM {{ dbt_sentinel.sentinel_rel('v_node_history') }} AS h
LEFT JOIN {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS ti
  ON ti.project_name = h.project_name AND ti.target_name = h.target_name AND ti.unique_id = h.unique_id
LEFT JOIN (
    {#- A unit test has no attached_node; its model is its (single) parent. -#}
    SELECT e.snapshot_id, e.child_id, MIN(e.parent_id) AS parent_id
    FROM {{ dbt_sentinel.sentinel_rel('manifest_edges') }} AS e
    GROUP BY e.snapshot_id, e.child_id
) AS ue
  ON ti.resource_type = 'unit_test' AND ue.snapshot_id = ti.snapshot_id AND ue.child_id = ti.unique_id
LEFT JOIN {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS tn
  ON tn.project_name = ti.project_name AND tn.target_name = ti.target_name
 AND tn.unique_id = COALESCE(ti.attached_node, ue.parent_id)
WHERE h.resource_type IN ('test', 'unit_test')
  AND h.status IN ('fail', 'error', 'warn')
  AND h.observed_at_utc >= DATEADD(day, -{{ days }}, SYSUTCDATETIME())
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_duration_anomalies() -%}
  {%- set factor = dbt_sentinel.sentinel_float_var('sentinel_model_slowdown_factor', 2.0) -%}
  {%- set min_runs = dbt_sentinel.sentinel_int_var('sentinel_anomaly_min_baseline_runs', 5, 1) -%}
  {%- set min_delta = dbt_sentinel.sentinel_float_var('sentinel_anomaly_min_delta_seconds', 30) -%}
  {%- set sql -%}
SELECT
    x.invocation_id,
    x.project_name,
    x.target_name,
    x.unique_id,
    x.node_name,
    x.schema_name,
    x.materialized,
    x.observed_at_utc,
    x.execution_seconds,
    x.baseline_runs,
    x.baseline_mean_seconds,
    x.baseline_stdev_seconds,
    x.execution_seconds / NULLIF(x.baseline_mean_seconds, 0) AS slowdown_ratio,
    x.execution_seconds - x.baseline_mean_seconds AS delta_seconds,
    CASE
        WHEN x.baseline_runs >= {{ min_runs }}
         AND x.baseline_mean_seconds > 0
         AND x.execution_seconds >= x.baseline_mean_seconds * {{ factor }}
         AND x.execution_seconds - x.baseline_mean_seconds >= {{ min_delta }}
        THEN 1 ELSE 0
    END AS is_anomaly
FROM (
    SELECT
        n.invocation_id,
        n.project_name,
        n.target_name,
        n.unique_id,
        n.node_name,
        n.schema_name,
        n.materialized,
        COALESCE(n.completed_at_utc, n.recorded_at_utc) AS observed_at_utc,
        n.execution_seconds,
        COUNT(n.execution_seconds) OVER (
            PARTITION BY n.project_name, n.target_name, n.unique_id
            ORDER BY COALESCE(n.completed_at_utc, n.recorded_at_utc), n.invocation_id
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING) AS baseline_runs,
        AVG(n.execution_seconds) OVER (
            PARTITION BY n.project_name, n.target_name, n.unique_id
            ORDER BY COALESCE(n.completed_at_utc, n.recorded_at_utc), n.invocation_id
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING) AS baseline_mean_seconds,
        STDEV(n.execution_seconds) OVER (
            PARTITION BY n.project_name, n.target_name, n.unique_id
            ORDER BY COALESCE(n.completed_at_utc, n.recorded_at_utc), n.invocation_id
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING) AS baseline_stdev_seconds
    FROM {{ dbt_sentinel.sentinel_rel('node_results') }} AS n
    WHERE n.resource_type = 'model'
      AND n.status = 'success'
      AND n.execution_seconds IS NOT NULL
) AS x
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_warehouse_requests() -%}
  {%- set expose = dbt_sentinel.sentinel_bool_var('sentinel_expose_command_text', false) -%}
  {%- set sql -%}
SELECT
    r.request_id,
    r.session_id,
    r.status,
    r.submit_time AS submit_time_utc,
    r.start_time AS start_time_utc,
    r.end_compile_time AS end_compile_time_utc,
    r.end_time AS end_time_utc,
    CAST(r.total_elapsed_time AS bigint) AS total_elapsed_ms,
    {{ dbt_sentinel.sentinel__safe_ms('r.submit_time', 'COALESCE(r.start_time, GETDATE())') }} AS queue_ms,
    r.label,
    r.resource_class,
    r.importance,
    r.group_name,
    r.classifier_name,
    r.resource_allocation_percentage,
    r.result_cache_hit,
    r.error_id,
    CASE WHEN r.status = 'Failed' THEN 1 ELSE 0 END AS is_failed,
    CASE WHEN r.status = 'Suspended' THEN 1 ELSE 0 END AS is_suspended,
    {% if expose %}CAST(LEFT(r.command, 200) AS nvarchar(200)){% else %}CAST(NULL AS nvarchar(200)){% endif %} AS command_preview
FROM sys.dm_pdw_exec_requests AS r
WHERE r.session_id <> SESSION_ID()
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_warehouse_waits() -%}
  {%- set sql -%}
SELECT
    w.wait_id,
    w.session_id,
    w.request_id,
    w.type AS wait_type,
    w.object_type,
    w.object_name,
    w.state AS wait_state,
    w.priority,
    w.request_time AS request_time_utc,
    w.acquire_time AS acquire_time_utc,
    {{ dbt_sentinel.sentinel__safe_ms('w.request_time', 'COALESCE(w.acquire_time, GETDATE())') }} AS wait_ms,
    r.status AS request_status,
    r.label,
    r.resource_class,
    r.group_name
FROM sys.dm_pdw_waits AS w
LEFT JOIN sys.dm_pdw_exec_requests AS r
  ON r.request_id = w.request_id
WHERE w.session_id <> SESSION_ID()
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_warehouse_pressure() -%}
  {%- set sql -%}
SELECT
    p.observed_at_utc,
    p.running_requests,
    p.suspended_requests,
    p.failed_requests_15m,
    p.cancelled_requests_15m,
    p.completed_requests_15m,
    p.avg_queue_ms_15m,
    p.max_queue_ms_15m,
    p.longest_running_ms,
    p.queued_waits,
    p.active_sessions,
    CASE
        WHEN p.suspended_requests > 0 OR p.queued_waits > 0 THEN 'queuing'
        WHEN p.failed_requests_15m > 0 THEN 'errors'
        ELSE 'normal'
    END AS pressure_state
FROM (
{{ dbt_sentinel.sentinel__pressure_select() }}
) AS p
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_warehouse_history() -%}
  {#- Sampled pressure over time (sentinel_sample_warehouse). No DMV access needed. -#}
  {%- set sql -%}
SELECT
    w.sampled_at_utc,
    CAST(w.sampled_at_utc AS date) AS sample_date_utc,
    w.running_requests,
    w.suspended_requests,
    w.failed_requests_15m,
    w.cancelled_requests_15m,
    w.completed_requests_15m,
    w.avg_queue_ms_15m,
    w.max_queue_ms_15m,
    w.longest_running_ms,
    w.queued_waits,
    w.active_sessions,
    CASE
        WHEN w.suspended_requests > 0 OR w.queued_waits > 0 THEN 'queuing'
        WHEN w.failed_requests_15m > 0 THEN 'errors'
        ELSE 'normal'
    END AS pressure_state
FROM {{ dbt_sentinel.sentinel_rel('warehouse_samples') }} AS w
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_user_queries() -%}
  {#- Live: queries currently in the DMV (recent only, reset by pause/scale). -#}
  {%- set sql -%}
SELECT
    q.request_id,
    q.session_id,
    q.login_name,
    q.app_name,
    q.status,
    q.submit_time_utc,
    q.start_time_utc,
    q.end_time_utc,
    q.total_elapsed_ms,
    CAST(q.total_elapsed_ms AS float) / 1000.0 AS elapsed_seconds,
    q.queue_ms,
    q.statement_type,
    q.label,
    q.resource_class,
    q.importance,
    q.group_name,
    q.error_id,
    q.result_cache_hit,
    CASE WHEN q.status = 'Failed' THEN 1 ELSE 0 END AS is_failed,
    CASE WHEN q.status IN ('Running', 'Suspended') THEN 1 ELSE 0 END AS is_active,
    q.command_text
FROM (
{{ dbt_sentinel.sentinel__requests_select(finished_only=false) }}
) AS q
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_query_history() -%}
  {#- Sampled history of finished queries (sentinel_sample_requests). Reading it
      needs no DMV permission. -#}
  {%- set sql -%}
SELECT
    h.request_id,
    h.session_id,
    h.login_name,
    h.app_name,
    h.status,
    h.submit_time_utc,
    h.start_time_utc,
    h.end_time_utc,
    CAST(h.end_time_utc AS date) AS query_date_utc,
    h.total_elapsed_ms,
    CAST(h.total_elapsed_ms AS float) / 1000.0 AS elapsed_seconds,
    h.queue_ms,
    h.statement_type,
    h.label,
    h.resource_class,
    h.importance,
    h.group_name,
    h.error_id,
    h.result_cache_hit,
    CASE WHEN h.status = 'Failed' THEN 1 ELSE 0 END AS is_failed,
    CASE WHEN h.status = 'Cancelled' THEN 1 ELSE 0 END AS is_cancelled,
    h.command_text,
    h.sampled_at_utc
FROM {{ dbt_sentinel.sentinel_rel('query_samples') }} AS h
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_user_activity_daily() -%}
  {%- set sql -%}
SELECT
    h.login_name,
    h.app_name,
    CAST(h.end_time_utc AS date) AS query_date_utc,
    COUNT(*) AS queries,
    COUNT(DISTINCT h.session_id) AS sessions,
    SUM(CASE WHEN h.status = 'Failed' THEN 1 ELSE 0 END) AS failed_queries,
    SUM(CASE WHEN h.status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled_queries,
    SUM(CAST(h.total_elapsed_ms AS float)) / 1000.0 AS total_elapsed_seconds,
    AVG(CAST(h.total_elapsed_ms AS float)) / 1000.0 AS avg_elapsed_seconds,
    MAX(CAST(h.total_elapsed_ms AS float)) / 1000.0 AS max_elapsed_seconds,
    AVG(CAST(h.queue_ms AS float)) AS avg_queue_ms,
    MAX(h.queue_ms) AS max_queue_ms,
    SUM(CASE WHEN h.result_cache_hit = 1 THEN 1 ELSE 0 END) AS result_cache_hits,
    MIN(h.submit_time_utc) AS first_query_at_utc,
    MAX(h.end_time_utc) AS last_query_at_utc
FROM {{ dbt_sentinel.sentinel_rel('query_samples') }} AS h
GROUP BY h.login_name, h.app_name, CAST(h.end_time_utc AS date)
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_table_storage() -%}
  {%- set sql -%}
SELECT
    st.schema_name,
    st.table_name,
    st.distribution_policy,
    st.is_replicated,
    st.approximate_row_count,
    st.reserved_mb,
    st.data_mb,
    st.used_mb,
    GETDATE() AS observed_at_utc
FROM (
{{ dbt_sentinel.sentinel__storage_select() }}
) AS st
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_table_health_history() -%}
  {#- Daily table-health snapshots (sentinel_sample_table_health). No DMV
      permission needed. is_latest marks each table's most recent sample. -#}
  {%- set sql -%}
SELECT
    h.*,
    CAST(h.sampled_at_utc AS date) AS sample_date_utc,
    CASE WHEN h.sampled_at_utc = m.latest_sampled_at_utc THEN 1 ELSE 0 END AS is_latest
FROM {{ dbt_sentinel.sentinel_rel('table_health_samples') }} AS h
CROSS JOIN (
    SELECT MAX(x.sampled_at_utc) AS latest_sampled_at_utc
    FROM {{ dbt_sentinel.sentinel_rel('table_health_samples') }} AS x
) AS m
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_table_growth() -%}
  {%- set sql -%}
SELECT
    g.sampled_at_utc,
    g.schema_name,
    g.table_name,
    g.distribution_policy,
    g.row_count,
    g.reserved_mb,
    g.previous_sampled_at_utc,
    g.previous_row_count,
    g.previous_reserved_mb,
    g.row_count - g.previous_row_count AS row_delta,
    CAST(g.row_count - g.previous_row_count AS float) * 100.0 / NULLIF(g.previous_row_count, 0) AS row_growth_pct,
    g.reserved_mb - g.previous_reserved_mb AS reserved_mb_delta,
    CAST(g.reserved_mb - g.previous_reserved_mb AS float) * 100.0 / NULLIF(g.previous_reserved_mb, 0) AS reserved_growth_pct,
    CAST(DATEDIFF(minute, g.previous_sampled_at_utc, g.sampled_at_utc) AS float) / 60.0 AS hours_since_previous
FROM (
    SELECT
        s.sampled_at_utc,
        s.schema_name,
        s.table_name,
        s.distribution_policy,
        s.row_count,
        s.reserved_mb,
        LAG(s.sampled_at_utc) OVER (PARTITION BY s.schema_name, s.table_name ORDER BY s.sampled_at_utc) AS previous_sampled_at_utc,
        LAG(s.row_count) OVER (PARTITION BY s.schema_name, s.table_name ORDER BY s.sampled_at_utc) AS previous_row_count,
        LAG(s.reserved_mb) OVER (PARTITION BY s.schema_name, s.table_name ORDER BY s.sampled_at_utc) AS previous_reserved_mb
    FROM {{ dbt_sentinel.sentinel_rel('storage_samples') }} AS s
) AS g
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_source_freshness() -%}
  {%- set stale_minutes = (dbt_sentinel.sentinel_float_var('sentinel_freshness_check_stale_hours', 26) * 60) | int -%}
  {%- set sql -%}
SELECT
    COALESCE(f.source_id, src.unique_id) AS source_id,
    COALESCE(src.project_name, f.project_name) AS project_name,
    COALESCE(src.target_name, f.target_name) AS target_name,
    src.source_name,
    src.node_name AS table_name,
    src.owner_name,
    COALESCE(src.has_freshness, 0) AS has_freshness_config,
    src.loaded_at_field,
    f.status,
    f.max_loaded_at_utc,
    f.age_minutes,
    f.threshold_minutes,
    f.checked_at_utc AS last_checked_at_utc,
    f.message,
    f.pipeline_run_id,
    CAST(DATEDIFF(minute, f.checked_at_utc, SYSUTCDATETIME()) AS float) / 60.0 AS hours_since_check,
    CASE
        WHEN f.source_id IS NULL THEN 'not_checked'
        WHEN DATEDIFF(minute, f.checked_at_utc, SYSUTCDATETIME()) > {{ stale_minutes }} THEN 'check_stale'
        ELSE f.status
    END AS freshness_state
FROM (
    SELECT x.*
    FROM (
        {#- Latest check per source and target. Rows recorded before 0.2.1 have
            no target, cannot be attributed, and are ignored. -#}
        SELECT fe.*, ROW_NUMBER() OVER (PARTITION BY fe.source_id, fe.target_name ORDER BY fe.checked_at_utc DESC, fe.recorded_at_utc DESC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('freshness_events') }} AS fe
        WHERE fe.target_name IS NOT NULL
    ) AS x
    WHERE x.rn = 1
) AS f
FULL OUTER JOIN (
    SELECT i.project_name, i.target_name, i.unique_id, i.source_name, i.node_name, i.owner_name, i.has_freshness, i.loaded_at_field
    FROM {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS i
    WHERE i.resource_type = 'source'
) AS src
  ON src.unique_id = f.source_id AND src.target_name = f.target_name
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_stage_health() -%}
  {%- set stale_minutes = (dbt_sentinel.sentinel_float_var('sentinel_stage_stale_hours', var('sentinel_run_stale_hours', 26)) * 60) | int -%}
  {%- set sql -%}
SELECT
    l.pipeline_name,
    l.stage,
    l.source_name,
    l.pipeline_run_id AS latest_pipeline_run_id,
    l.status AS latest_status,
    l.started_at_utc,
    l.completed_at_utc,
    l.event_at_utc,
    l.rows_loaded,
    DATEDIFF(second, l.started_at_utc, l.completed_at_utc) AS duration_seconds,
    l.message,
    CAST(DATEDIFF(minute, l.event_at_utc, SYSUTCDATETIME()) AS float) / 60.0 AS hours_since_event,
    a.last_success_at_utc,
    a.events_7d,
    a.failures_7d,
    CASE WHEN a.last_success_at_utc IS NULL OR DATEDIFF(minute, a.last_success_at_utc, SYSUTCDATETIME()) > {{ stale_minutes }} THEN 1 ELSE 0 END AS is_stale,
    CASE
        WHEN l.status IN ('failed', 'cancelled') THEN 'unhealthy'
        WHEN l.status = 'warning' THEN 'warning'
        WHEN l.status = 'running' THEN 'running'
        WHEN l.status = 'skipped' THEN 'skipped'
        ELSE 'healthy'
    END AS health_state
FROM (
    SELECT se.*, ROW_NUMBER() OVER (PARTITION BY se.pipeline_name, se.stage, se.source_name
                                    ORDER BY se.event_at_utc DESC, se.recorded_at_utc DESC) AS rn
    FROM {{ dbt_sentinel.sentinel_rel('stage_events') }} AS se
) AS l
JOIN (
    SELECT
        se.pipeline_name,
        se.stage,
        COALESCE(se.source_name, N'') AS source_key,
        MAX(CASE WHEN se.status IN ('success', 'warning') THEN se.event_at_utc END) AS last_success_at_utc,
        SUM(CASE WHEN se.event_at_utc >= DATEADD(day, -7, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS events_7d,
        SUM(CASE WHEN se.event_at_utc >= DATEADD(day, -7, SYSUTCDATETIME()) AND se.status IN ('failed', 'cancelled') THEN 1 ELSE 0 END) AS failures_7d
    FROM {{ dbt_sentinel.sentinel_rel('stage_events') }} AS se
    GROUP BY se.pipeline_name, se.stage, COALESCE(se.source_name, N'')
) AS a
  ON a.pipeline_name = l.pipeline_name AND a.stage = l.stage AND a.source_key = COALESCE(l.source_name, N'')
WHERE l.rn = 1
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_operational_alerts() -%}
  {%- set sql -%}
SELECT
    CAST('stage_failure' AS nvarchar(64)) AS alert_type,
    CAST('high' AS nvarchar(16)) AS severity,
    CAST(NULL AS nvarchar(256)) AS project_name,
    CAST(NULL AS nvarchar(128)) AS target_name,
    CAST(sh.pipeline_name + N' / ' + sh.stage + COALESCE(N' / ' + sh.source_name, N'') AS nvarchar(1024)) AS subject,
    CAST(COALESCE(sh.message, sh.latest_status) AS nvarchar(2000)) AS detail,
    CAST(sh.event_at_utc AS datetime2(6)) AS observed_at_utc,
    CAST(sh.latest_pipeline_run_id AS nvarchar(512)) AS reference_id
FROM {{ dbt_sentinel.sentinel_rel('v_stage_health') }} AS sh
WHERE sh.latest_status IN ('failed', 'cancelled')
UNION ALL
SELECT
    CAST('stage_stale' AS nvarchar(64)), CAST('medium' AS nvarchar(16)),
    CAST(NULL AS nvarchar(256)), CAST(NULL AS nvarchar(128)),
    CAST(sh.pipeline_name + N' / ' + sh.stage + COALESCE(N' / ' + sh.source_name, N'') AS nvarchar(1024)),
    CAST(N'No successful stage event since ' + COALESCE(CONVERT(nvarchar(30), sh.last_success_at_utc, 126), N'(never)') AS nvarchar(2000)),
    CAST(sh.event_at_utc AS datetime2(6)),
    CAST(sh.latest_pipeline_run_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_stage_health') }} AS sh
WHERE sh.is_stale = 1 AND sh.latest_status NOT IN ('failed', 'cancelled')
UNION ALL
SELECT
    CAST(CASE WHEN ph.latest_run_status = 'missing_completion' THEN 'run_missing_completion' ELSE 'run_failure' END AS nvarchar(64)),
    CAST('high' AS nvarchar(16)),
    CAST(ph.project_name AS nvarchar(256)), CAST(ph.target_name AS nvarchar(128)),
    CAST(ph.project_name + N' / ' + ph.target_name + N' / ' + COALESCE(ph.latest_command, N'') AS nvarchar(1024)),
    CAST(N'Latest dbt invocation status: ' + ph.latest_run_status AS nvarchar(2000)),
    CAST(ph.latest_started_at_utc AS datetime2(6)),
    CAST(ph.latest_invocation_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_pipeline_health') }} AS ph
WHERE ph.latest_run_status IN ('error', 'missing_completion')
UNION ALL
SELECT
    CAST('run_stale' AS nvarchar(64)), CAST('medium' AS nvarchar(16)),
    CAST(ph.project_name AS nvarchar(256)), CAST(ph.target_name AS nvarchar(128)),
    CAST(ph.project_name + N' / ' + ph.target_name AS nvarchar(1024)),
    CAST(N'No successful dbt invocation since ' + COALESCE(CONVERT(nvarchar(30), ph.last_success_at_utc, 126), N'(never)') AS nvarchar(2000)),
    CAST(ph.latest_started_at_utc AS datetime2(6)),
    CAST(ph.latest_invocation_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_pipeline_health') }} AS ph
WHERE ph.is_stale = 1
UNION ALL
SELECT
    CAST('source_freshness' AS nvarchar(64)),
    CAST(CASE WHEN sf.freshness_state = 'warn' THEN 'medium' ELSE 'high' END AS nvarchar(16)),
    CAST(sf.project_name AS nvarchar(256)), CAST(sf.target_name AS nvarchar(128)),
    CAST(sf.source_id AS nvarchar(1024)),
    CAST(COALESCE(sf.message, N'Freshness ' + sf.freshness_state) AS nvarchar(2000)),
    CAST(sf.last_checked_at_utc AS datetime2(6)),
    CAST(sf.source_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_source_freshness') }} AS sf
WHERE sf.freshness_state IN ('warn', 'error', 'runtime error')
UNION ALL
SELECT
    CAST(CASE WHEN sf.freshness_state = 'not_checked' THEN 'source_not_checked' ELSE 'source_check_stale' END AS nvarchar(64)),
    CAST('low' AS nvarchar(16)),
    CAST(sf.project_name AS nvarchar(256)), CAST(sf.target_name AS nvarchar(128)),
    CAST(sf.source_id AS nvarchar(1024)),
    CAST(CASE WHEN sf.freshness_state = 'not_checked' THEN N'Source has a freshness policy but no recorded check'
              ELSE N'Last freshness check is older than the expected interval' END AS nvarchar(2000)),
    CAST(sf.last_checked_at_utc AS datetime2(6)),
    CAST(sf.source_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_source_freshness') }} AS sf
WHERE (sf.freshness_state = 'not_checked' AND sf.has_freshness_config = 1) OR sf.freshness_state = 'check_stale'
UNION ALL
SELECT
    CAST('test_failure' AS nvarchar(64)),
    CAST(CASE WHEN tf.status = 'warn' THEN 'medium' ELSE 'high' END AS nvarchar(16)),
    CAST(tf.project_name AS nvarchar(256)), CAST(tf.target_name AS nvarchar(128)),
    CAST(COALESCE(tf.tested_node_name + N' / ', N'') + tf.test_name AS nvarchar(1024)),
    CAST(COALESCE(tf.message, tf.status) AS nvarchar(2000)),
    CAST(tf.observed_at_utc AS datetime2(6)),
    CAST(tf.test_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_test_failures') }} AS tf
WHERE tf.observed_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME())
UNION ALL
SELECT
    CAST('table_maintenance' AS nvarchar(64)), CAST('low' AS nvarchar(16)),
    CAST(NULL AS nvarchar(256)), CAST(NULL AS nvarchar(128)),
    CAST(th.schema_name + N'.' + th.table_name AS nvarchar(1024)),
    CAST(th.recommendation AS nvarchar(2000)),
    CAST(th.sampled_at_utc AS datetime2(6)),
    CAST(th.schema_name + N'.' + th.table_name AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_table_health_history') }} AS th
WHERE th.is_latest = 1 AND th.issue_count > 0
UNION ALL
SELECT
    CAST('node_error' AS nvarchar(64)), CAST('high' AS nvarchar(16)),
    CAST(nh.project_name AS nvarchar(256)), CAST(nh.target_name AS nvarchar(128)),
    CAST(nh.resource_type + N' / ' + nh.node_name AS nvarchar(1024)),
    CAST(COALESCE(nh.message, nh.status) AS nvarchar(2000)),
    CAST(nh.observed_at_utc AS datetime2(6)),
    CAST(nh.unique_id AS nvarchar(512))
FROM {{ dbt_sentinel.sentinel_rel('v_node_history') }} AS nh
WHERE nh.resource_type IN ('model', 'seed', 'snapshot')
  AND nh.status = 'error'
  AND nh.observed_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME())
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}

{% macro sentinel_view_health_summary() -%}
  {%- set stale_minutes = (dbt_sentinel.sentinel_float_var('sentinel_run_stale_hours', 26) * 60) | int -%}
  {%- set sql -%}
SELECT
    SYSUTCDATETIME() AS evaluated_at_utc,
    {#- Alerts first: a stopped scheduler raises run_stale (medium) and must not
        hide behind 'unknown'. 'unknown' means no dbt run was ever recorded. -#}
    CASE
        WHEN COALESCE(al.high_alerts, 0) > 0 THEN 'red'
        WHEN COALESCE(al.medium_alerts, 0) > 0 THEN 'amber'
        WHEN COALESCE(rs.runs_total, 0) = 0 THEN 'unknown'
        WHEN COALESCE(rs.runs_in_stale_window, 0) = 0 THEN 'amber'
        ELSE 'green'
    END AS overall_state,
    rs.runs_24h,
    rs.successful_runs_24h,
    rs.failed_runs_24h,
    CAST(rs.successful_runs_24h AS float) / NULLIF(rs.finished_runs_24h, 0) AS success_rate_24h,
    rs.last_completed_at_utc,
    lc.run_status AS last_completed_status,
    lc.project_name AS last_completed_project,
    lc.target_name AS last_completed_target,
    COALESCE(al.high_alerts, 0) AS high_alerts,
    COALESCE(al.medium_alerts, 0) AS medium_alerts,
    COALESCE(al.low_alerts, 0) AS low_alerts,
    COALESCE(al.test_failures_24h, 0) AS test_failures_24h,
    COALESCE(fr.sources_failing, 0) AS sources_failing,
    COALESCE(fr.sources_unchecked_or_stale, 0) AS sources_unchecked_or_stale,
    ws.sampled_at_utc AS last_warehouse_sample_utc,
    ws.running_requests AS sampled_running_requests,
    ws.suspended_requests AS sampled_suspended_requests,
    ws.failed_requests_15m AS sampled_failed_requests_15m,
    inv.last_manifest_sync_utc,
    COALESCE(inv.models_total, 0) AS models_total,
    COALESCE(inv.models_without_owner, 0) AS models_without_owner,
    COALESCE(inv.models_without_description, 0) AS models_without_description,
    COALESCE(inv.models_without_tests, 0) AS models_without_tests,
    COALESCE(tm.tables_needing_maintenance, 0) AS tables_needing_maintenance,
    tm.last_table_health_sample_utc,
    CASE WHEN COALESCE(rs.runs_in_stale_window, 0) > 0 THEN 1 ELSE 0 END AS has_run_signal,
    CASE WHEN sg.last_stage_event_utc >= DATEADD(day, -7, SYSUTCDATETIME()) THEN 1 ELSE 0 END AS has_stage_signal,
    CASE WHEN fr.last_check_utc >= DATEADD(day, -7, SYSUTCDATETIME()) THEN 1 ELSE 0 END AS has_freshness_signal,
    CASE WHEN ws.sampled_at_utc >= DATEADD(hour, -2, SYSUTCDATETIME()) THEN 1 ELSE 0 END AS has_warehouse_signal,
    CASE WHEN inv.last_manifest_sync_utc IS NOT NULL THEN 1 ELSE 0 END AS has_manifest_signal
FROM (
    SELECT
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) AND h.run_status IN ('success', 'warn') THEN 1 ELSE 0 END) AS successful_runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) AND h.is_failure = 1 THEN 1 ELSE 0 END) AS failed_runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(hour, -24, SYSUTCDATETIME()) AND h.run_status <> 'running' THEN 1 ELSE 0 END) AS finished_runs_24h,
        SUM(CASE WHEN h.started_at_utc >= DATEADD(minute, -{{ stale_minutes }}, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS runs_in_stale_window,
        COUNT(*) AS runs_total,
        MAX(h.completed_at_utc) AS last_completed_at_utc
    FROM {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS h
    WHERE {{ dbt_sentinel.sentinel__target_filter('h') }}
) AS rs
LEFT JOIN (
    SELECT z.run_status, z.project_name, z.target_name
    FROM (
        SELECT h.run_status, h.project_name, h.target_name,
               ROW_NUMBER() OVER (ORDER BY h.completed_at_utc DESC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('v_run_history') }} AS h
        WHERE h.completed_at_utc IS NOT NULL AND {{ dbt_sentinel.sentinel__target_filter('h') }}
    ) AS z
    WHERE z.rn = 1
) AS lc
  ON 1 = 1
CROSS JOIN (
    SELECT
        SUM(CASE WHEN a.severity = 'high' THEN 1 ELSE 0 END) AS high_alerts,
        SUM(CASE WHEN a.severity = 'medium' THEN 1 ELSE 0 END) AS medium_alerts,
        SUM(CASE WHEN a.severity = 'low' THEN 1 ELSE 0 END) AS low_alerts,
        SUM(CASE WHEN a.alert_type = 'test_failure' THEN 1 ELSE 0 END) AS test_failures_24h
    FROM {{ dbt_sentinel.sentinel_rel('v_operational_alerts') }} AS a
    WHERE a.target_name IS NULL OR {{ dbt_sentinel.sentinel__target_filter('a') }}
) AS al
CROSS JOIN (
    SELECT
        SUM(CASE WHEN f.freshness_state IN ('error', 'runtime error') THEN 1 ELSE 0 END) AS sources_failing,
        SUM(CASE WHEN f.freshness_state IN ('not_checked', 'check_stale') THEN 1 ELSE 0 END) AS sources_unchecked_or_stale,
        MAX(f.last_checked_at_utc) AS last_check_utc
    FROM {{ dbt_sentinel.sentinel_rel('v_source_freshness') }} AS f
    WHERE f.target_name IS NULL OR {{ dbt_sentinel.sentinel__target_filter('f') }}
) AS fr
CROSS JOIN (
    SELECT MAX(se.event_at_utc) AS last_stage_event_utc
    FROM {{ dbt_sentinel.sentinel_rel('stage_events') }} AS se
) AS sg
LEFT JOIN (
    SELECT q.sampled_at_utc, q.running_requests, q.suspended_requests, q.failed_requests_15m
    FROM (
        SELECT w.sampled_at_utc, w.running_requests, w.suspended_requests, w.failed_requests_15m,
               ROW_NUMBER() OVER (ORDER BY w.sampled_at_utc DESC) AS rn
        FROM {{ dbt_sentinel.sentinel_rel('warehouse_samples') }} AS w
    ) AS q
    WHERE q.rn = 1
) AS ws
  ON 1 = 1
CROSS JOIN (
    SELECT
        MAX(c.manifest_captured_at_utc) AS last_manifest_sync_utc,
        SUM(CASE WHEN c.resource_type = 'model' THEN 1 ELSE 0 END) AS models_total,
        SUM(CASE WHEN c.resource_type = 'model' AND c.has_owner = 0 THEN 1 ELSE 0 END) AS models_without_owner,
        SUM(CASE WHEN c.resource_type = 'model' AND c.has_description = 0 THEN 1 ELSE 0 END) AS models_without_description,
        SUM(CASE WHEN c.resource_type = 'model' AND c.test_count = 0 THEN 1 ELSE 0 END) AS models_without_tests
    FROM {{ dbt_sentinel.sentinel_rel('v_model_inventory') }} AS c
    WHERE {{ dbt_sentinel.sentinel__target_filter('c') }}
) AS inv
CROSS JOIN (
    SELECT
        SUM(CASE WHEN th.is_latest = 1 AND th.issue_count > 0 THEN 1 ELSE 0 END) AS tables_needing_maintenance,
        MAX(th.sampled_at_utc) AS last_table_health_sample_utc
    FROM {{ dbt_sentinel.sentinel_rel('v_table_health_history') }} AS th
) AS tm
  {%- endset -%}
  {{ return(sql) }}
{%- endmacro %}
