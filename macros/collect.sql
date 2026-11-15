{#-
  dbt Sentinel - collect.sql
  Hooks, manifest sync, warehouse samplers, integration writers and purge.

  Hooks (host dbt_project.yml):
    on-run-start: "{{ dbt_sentinel.sentinel_start_run() }}"
    on-run-end:   "{{ dbt_sentinel.sentinel_capture_run() }}"     (or pass results explicitly:
                  "{{ dbt_sentinel.sentinel_capture_run(results) }}")

  Operations:
    sentinel_sync_manifest, sentinel_sample_warehouse, sentinel_sample_storage,
    sentinel_record_stage, sentinel_record_freshness, sentinel_record_freshness_batch,
    sentinel_purge_history

  Hook macros run their own statements and return an empty string, which dbt
  skips. With var sentinel_hook_on_error = 'warn' (default) a telemetry write
  failure (or a target where Sentinel is not installed) is logged and does not
  fail the build, including under --warn-error.
-#}


{# ===================================================================== hooks #}

{% macro sentinel__selector_text() -%}
  {%- set args = invocation_args_dict if invocation_args_dict is defined and invocation_args_dict else {} -%}
  {%- set parts = [] -%}
  {%- for key in ['select', 'exclude', 'selector', 'resource_types'] -%}
    {%- set v = args.get(key) -%}
    {%- if v -%}
      {%- do parts.append(key ~ '=' ~ ((v | join(' ')) if (v is iterable and v is not string) else v)) -%}
    {%- endif -%}
  {%- endfor -%}
  {{ return(parts | join('; ') if parts | length > 0 else none) }}
{%- endmacro %}

{% macro sentinel__full_refresh() -%}
  {%- set args = invocation_args_dict if invocation_args_dict is defined and invocation_args_dict else {} -%}
  {%- if args.get('full_refresh') -%}{{ return(true) }}{%- endif -%}
  {%- if flags is defined and flags.FULL_REFRESH is defined and flags.FULL_REFRESH -%}{{ return(true) }}{%- endif -%}
  {{ return(false) }}
{%- endmacro %}

{% macro sentinel__run_event(event_type) -%}
  {%- set p = dbt_sentinel.sentinel_pipeline_context() -%}
  {{ return({
      'invocation_id': invocation_id,
      'event_type': event_type,
      'event_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()'),
      'run_started_at_utc': run_started_at,
      'command': dbt_sentinel.sentinel_command(),
      'project_name': project_name,
      'target_name': target.name,
      'target_schema': target.schema,
      'dbt_version': dbt_version,
      'selector': dbt_sentinel.sentinel__selector_text(),
      'full_refresh': dbt_sentinel.sentinel__full_refresh(),
      'pipeline_name': p['pipeline_name'],
      'pipeline_run_id': p['pipeline_run_id'],
      'commit_id': p['commit_id'],
      'branch_name': p['branch_name'],
      'build_reason': p['build_reason'],
      'recorded_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()')
  }) }}
{%- endmacro %}

{% macro sentinel_start_run() -%}
  {%- if not dbt_sentinel.sentinel_hooks_active() -%}{{ return('') }}{%- endif -%}
  {%- set row = dbt_sentinel.sentinel__run_event('start') -%}
  {%- do row.update({'run_status': 'running'}) -%}
  {% do dbt_sentinel.sentinel_insert('run_events', [row], dbt_sentinel.sentinel_on_error_mode('hook')) %}
  {{ return('') }}
{%- endmacro %}

{% macro sentinel__normalise_result_status(status) -%}
  {%- set s = (status | string | lower | trim) if status is not none else 'unknown' -%}
  {%- if s.startswith('runstatus.') or s.startswith('teststatus.') or s.startswith('nodestatus.') -%}
    {%- set s = s.split('.')[1] -%}
  {%- endif -%}
  {%- if s == 'runtime error' or s == 'runtimeerr' -%}{%- set s = 'error' -%}{%- endif -%}
  {{ return(s) }}
{%- endmacro %}

{% macro sentinel_capture_run(run_results=none) -%}
  {%- if not dbt_sentinel.sentinel_hooks_active() -%}{{ return('') }}{%- endif -%}
  {%- set mode = dbt_sentinel.sentinel_on_error_mode('hook') -%}
  {%- if run_results is not none -%}
    {%- set rs = run_results -%}
  {%- elif results is defined and results is not none -%}
    {%- set rs = results -%}
  {%- else -%}
    {%- set rs = [] -%}
  {%- endif -%}

  {%- set capture_messages = dbt_sentinel.sentinel_bool_var('sentinel_capture_messages', true) -%}
  {%- set message_len = dbt_sentinel.sentinel_int_var('sentinel_message_max_length', 1000, 0) -%}
  {%- set ns = namespace(success=0, error=0, fail=0, warn=0, skipped=0) -%}
  {%- set rows = [] -%}

  {%- for r in rs -%}
    {%- set n = r.node -%}
    {%- set t = namespace(started=none, completed=none) -%}
    {%- for timing in (r.timing or []) -%}
      {%- if timing.name == 'execute' -%}
        {%- set t.started = timing.started_at -%}
        {%- set t.completed = timing.completed_at -%}
      {%- endif -%}
    {%- endfor -%}

    {%- set status = dbt_sentinel.sentinel__normalise_result_status(r.status) -%}
    {%- if status in ['success', 'pass'] -%}{%- set ns.success = ns.success + 1 -%}
    {%- elif status == 'error' -%}{%- set ns.error = ns.error + 1 -%}
    {%- elif status == 'fail' -%}{%- set ns.fail = ns.fail + 1 -%}
    {%- elif status == 'warn' -%}{%- set ns.warn = ns.warn + 1 -%}
    {%- elif status == 'skipped' -%}{%- set ns.skipped = ns.skipped + 1 -%}
    {%- endif -%}

    {%- set rows_affected = none -%}
    {%- if r.adapter_response is defined and r.adapter_response is mapping -%}
      {%- set ra = r.adapter_response.get('rows_affected') -%}
      {%- if ra is not none and ra is number and ra >= 0 -%}{%- set rows_affected = ra -%}{%- endif -%}
    {%- endif -%}

    {%- set message = none -%}
    {%- if capture_messages and r.message and message_len > 0 -%}
      {%- set message = (r.message | string)[:message_len] -%}
    {%- endif -%}

    {%- do rows.append({
        'invocation_id': invocation_id,
        'project_name': project_name,
        'target_name': target.name,
        'unique_id': n.unique_id,
        'resource_type': n.resource_type | string | lower,
        'node_name': n.name,
        'package_name': n.package_name,
        'schema_name': n.schema,
        'alias_name': (n.alias if n.alias is defined else n.name),
        'materialized': (n.config.materialized if n.config is defined and n.config.materialized is defined else none),
        'status': status,
        'execution_seconds': (r.execution_time if r.execution_time is defined else none),
        'started_at_utc': t.started,
        'completed_at_utc': t.completed,
        'rows_affected': rows_affected,
        'failures': (r.failures if r.failures is defined and r.failures is number else none),
        'message': message,
        'thread_id': (r.thread_id if r.thread_id is defined else none),
        'recorded_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()')
    }) -%}
  {%- endfor -%}

  {%- if rows | length > 0 -%}
    {%- set written = dbt_sentinel.sentinel_insert('node_results', rows, mode) -%}
    {%- if written == -1 -%}
      {#- Without its node rows a completed run would look complete but lose
          nodes from every node-level view; leave it without a completion
          event so it surfaces as missing_completion instead. -#}
      {% do dbt_sentinel.sentinel_warn('dbt_sentinel: node results for invocation ' ~ invocation_id ~ ' were not fully written; completion event skipped (the run will show as missing_completion).') %}
      {{ return('') }}
    {%- endif -%}
  {%- endif -%}

  {#- The completion event is written last so that a completed invocation always
      has its node rows in place before dashboards see it as finished. -#}
  {%- if ns.error + ns.fail > 0 -%}{%- set run_status = 'error' -%}
  {%- elif ns.warn > 0 -%}{%- set run_status = 'warn' -%}
  {%- else -%}{%- set run_status = 'success' -%}
  {%- endif -%}
  {%- set started_text = dbt_sentinel.sentinel_timestamp_text(run_started_at) -%}
  {%- set row = dbt_sentinel.sentinel__run_event('end') -%}
  {%- do row.update({
      'run_status': run_status,
      'elapsed_seconds': dbt_sentinel.sentinel_sql("CAST(DATEDIFF(millisecond, CAST(N'" ~ started_text ~ "' AS datetime2(6)), SYSUTCDATETIME()) AS float) / 1000.0"),
      'nodes_total': rows | length,
      'nodes_success': ns.success,
      'nodes_error': ns.error,
      'nodes_fail': ns.fail,
      'nodes_warn': ns.warn,
      'nodes_skipped': ns.skipped
  }) -%}
  {% do dbt_sentinel.sentinel_insert('run_events', [row], mode) %}
  {{ return('') }}
{%- endmacro %}


{# ============================================================ manifest sync #}

{% macro sentinel__meta_owner(node) -%}
  {%- set cfg = node.get('config') or {} -%}
  {%- set owner = (cfg.get('meta') or {}).get('owner') if cfg is mapping else none -%}
  {%- if not owner -%}{%- set owner = (node.get('meta') or {}).get('owner') -%}{%- endif -%}
  {%- if owner and owner is iterable and owner is not string -%}{%- set owner = owner | join(', ') -%}{%- endif -%}
  {{ return(owner if owner else none) }}
{%- endmacro %}

{% macro sentinel__node_row(snapshot_id, node) -%}
  {%- set cfg = node.get('config') or {} -%}
  {%- set desc = node.get('description') or '' -%}
  {%- set tags = node.get('tags') or [] -%}
  {%- set rtype = node.get('resource_type') | string | lower -%}
  {%- set test_type = none -%}
  {%- if rtype == 'test' -%}
    {%- set tm = node.get('test_metadata') -%}
    {%- set test_type = (tm.get('name') if tm else none) or 'singular' -%}
  {%- elif rtype == 'unit_test' -%}
    {%- set test_type = 'unit' -%}
  {%- endif -%}
  {%- set has_freshness = false -%}
  {%- set loaded_at_field = none -%}
  {%- if rtype == 'source' -%}
    {%- set fr = node.get('freshness') or (cfg.get('freshness') if cfg is mapping else none) or {} -%}
    {%- set warn_count = (fr.get('warn_after') or {}).get('count') if fr is mapping else none -%}
    {%- set error_count = (fr.get('error_after') or {}).get('count') if fr is mapping else none -%}
    {%- set has_freshness = (warn_count is not none) or (error_count is not none) -%}
    {%- set loaded_at_field = node.get('loaded_at_field') or (cfg.get('loaded_at_field') if cfg is mapping else none) -%}
  {%- endif -%}
  {{ return({
      'snapshot_id': snapshot_id,
      'unique_id': node.get('unique_id'),
      'resource_type': rtype,
      'node_name': node.get('name'),
      'package_name': node.get('package_name'),
      'database_name': node.get('database'),
      'schema_name': node.get('schema'),
      'alias_name': node.get('identifier') if rtype == 'source' else (node.get('alias') or node.get('name')),
      'materialized': cfg.get('materialized') if cfg is mapping else none,
      'owner_name': dbt_sentinel.sentinel__meta_owner(node),
      'description': desc[:2000] if desc else none,
      'has_description': (desc | trim | length) > 0,
      'tags': (tags | join(',')) if tags else none,
      'file_path': node.get('original_file_path'),
      'test_type': test_type,
      'attached_node': node.get('attached_node'),
      'source_name': node.get('source_name'),
      'loaded_at_field': loaded_at_field,
      'has_freshness': has_freshness
  }) }}
{%- endmacro %}

{% macro sentinel_sync_manifest() -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set include_packages = dbt_sentinel.sentinel_bool_var('sentinel_manifest_include_packages', false) -%}
  {%- set types = ['model', 'test', 'seed', 'snapshot'] -%}
  {%- set snapshot_id = invocation_id -%}
  {%- set node_rows = [] -%}
  {%- set edge_rows = [] -%}

  {%- for node in graph.nodes.values() -%}
    {%- if node.get('resource_type') in types and (include_packages or node.get('package_name') == project_name) -%}
      {%- do node_rows.append(dbt_sentinel.sentinel__node_row(snapshot_id, node)) -%}
      {%- for parent in ((node.get('depends_on') or {}).get('nodes') or []) | unique -%}
        {%- do edge_rows.append({'snapshot_id': snapshot_id, 'parent_id': parent, 'child_id': node.get('unique_id')}) -%}
      {%- endfor -%}
    {%- endif -%}
  {%- endfor -%}
  {#- dbt unit tests (dbt >= 1.8) live outside graph.nodes; their depends_on
      edges link them to the model under test. -#}
  {%- for ut in (graph.get('unit_tests') or {}).values() -%}
    {%- if include_packages or ut.get('package_name') == project_name -%}
      {%- do node_rows.append(dbt_sentinel.sentinel__node_row(snapshot_id, ut)) -%}
      {%- for parent in ((ut.get('depends_on') or {}).get('nodes') or []) | unique -%}
        {%- do edge_rows.append({'snapshot_id': snapshot_id, 'parent_id': parent, 'child_id': ut.get('unique_id')}) -%}
      {%- endfor -%}
    {%- endif -%}
  {%- endfor -%}
  {%- for src in graph.sources.values() -%}
    {%- if include_packages or src.get('package_name') == project_name -%}
      {%- do node_rows.append(dbt_sentinel.sentinel__node_row(snapshot_id, src)) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- set mode = dbt_sentinel.sentinel_on_error_mode('operation') -%}
  {%- set nodes_written = dbt_sentinel.sentinel_insert('manifest_nodes', node_rows, mode) -%}
  {%- set edges_written = dbt_sentinel.sentinel_insert('manifest_edges', edge_rows, mode) -%}
  {#- Snapshot header last: views only read snapshots whose header exists, so a
      partially loaded snapshot is never shown as the latest deployment. -#}
  {%- if nodes_written == -1 or edges_written == -1 -%}
    {% do dbt_sentinel.sentinel_warn('dbt_sentinel: manifest snapshot ' ~ snapshot_id ~ ' was not fully written; header skipped, the previous snapshot stays current. Re-run sentinel_sync_manifest.') %}
    {{ return('') }}
  {%- endif -%}
  {%- set p = dbt_sentinel.sentinel_pipeline_context() -%}
  {% do dbt_sentinel.sentinel_insert('manifest_snapshots', [{
      'snapshot_id': snapshot_id,
      'project_name': project_name,
      'target_name': target.name,
      'dbt_version': dbt_version,
      'node_count': node_rows | length,
      'edge_count': edge_rows | length,
      'pipeline_run_id': p['pipeline_run_id'],
      'commit_id': p['commit_id'],
      'captured_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()')
  }], mode) %}
  {% do log('dbt_sentinel: manifest snapshot ' ~ snapshot_id ~ ' stored (' ~ node_rows | length ~ ' nodes, ' ~ edge_rows | length ~ ' edges)', info=true) %}
{%- endmacro %}


{# ================================================================= samplers #}

{% macro sentinel_sample_warehouse() -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set sql -%}
INSERT INTO {{ dbt_sentinel.sentinel_rel('warehouse_samples') }}
    ([sampled_at_utc], [running_requests], [suspended_requests], [failed_requests_15m], [cancelled_requests_15m],
     [completed_requests_15m], [avg_queue_ms_15m], [max_queue_ms_15m], [longest_running_ms], [queued_waits], [active_sessions])
SELECT
    SYSUTCDATETIME(), p.running_requests, p.suspended_requests, p.failed_requests_15m, p.cancelled_requests_15m,
    p.completed_requests_15m, p.avg_queue_ms_15m, p.max_queue_ms_15m, p.longest_running_ms, p.queued_waits, p.active_sessions
FROM (
{{ dbt_sentinel.sentinel__pressure_select() }}
) AS p
  {%- endset -%}
  {% do dbt_sentinel.sentinel_execute(sql, dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: warehouse pressure sample stored', info=true) %}
{%- endmacro %}

{% macro sentinel_sample_storage() -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set excluded = dbt_sentinel.sentinel_list_var('sentinel_storage_exclude_schemas', []) -%}
  {%- set excluded_lits = [] -%}
  {%- for s in excluded -%}{%- do excluded_lits.append(dbt_sentinel.sentinel_nstring(s)) -%}{%- endfor -%}
  {%- set sql -%}
INSERT INTO {{ dbt_sentinel.sentinel_rel('storage_samples') }}
    ([sampled_at_utc], [schema_name], [table_name], [distribution_policy], [row_count], [reserved_mb], [data_mb], [used_mb])
SELECT
    SYSUTCDATETIME(), st.schema_name, st.table_name, st.distribution_policy,
    st.approximate_row_count, st.reserved_mb, st.data_mb, st.used_mb
FROM (
{{ dbt_sentinel.sentinel__storage_select() }}
) AS st
{% if excluded_lits | length > 0 %}WHERE st.schema_name NOT IN ({{ excluded_lits | join(', ') }}){% endif %}
  {%- endset -%}
  {% do dbt_sentinel.sentinel_execute(sql, dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: table storage sample stored', info=true) %}
{%- endmacro %}


{% macro sentinel_sample_table_health() -%}
  {#- Daily snapshot of distribution skew, columnstore quality and statistics
      health per user table (see v_table_health). Feeds v_table_health_history
      and the low-severity 'table_maintenance' alerts. -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set cols = [] -%}
  {%- set picks = [] -%}
  {%- for c in dbt_sentinel.sentinel_table_columns()['table_health_samples'] -%}
    {%- do cols.append('[' ~ c[0] ~ ']') -%}
    {%- do picks.append('SYSUTCDATETIME()' if c[0] == 'sampled_at_utc' else 'h.' ~ c[0]) -%}
  {%- endfor -%}
  {%- set sql -%}
INSERT INTO {{ dbt_sentinel.sentinel_rel('table_health_samples') }}
    ({{ cols | join(', ') }})
SELECT {{ picks | join(', ') }}
FROM (
{{ dbt_sentinel.sentinel__table_health_select() }}
) AS h
  {%- endset -%}
  {% do dbt_sentinel.sentinel_execute(sql, dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: table health sample stored', info=true) %}
{%- endmacro %}

{% macro sentinel_sample_requests() -%}
  {#-
    Copies finished warehouse requests (Completed / Failed / Cancelled) with the
    login and client application into query_samples. Incremental on end time,
    so it can run as often as needed; schedule it frequently enough that fewer
    than ~10,000 requests (the DMV retention) finish between runs. Query text
    is stored only when var sentinel_capture_query_text is true.
  -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set wm_res = run_query('SELECT CONVERT(nvarchar(30), MAX([end_time_utc]), 121) AS wm FROM ' ~ dbt_sentinel.sentinel_rel('query_samples')) -%}
  {%- set wm = wm_res.rows[0][0] if wm_res.rows | length > 0 else none -%}
  {%- set cols = [] -%}
  {%- for c in dbt_sentinel.sentinel_table_columns()['query_samples'] -%}{%- do cols.append('[' ~ c[0] ~ ']') -%}{%- endfor -%}
  {%- set sql -%}
INSERT INTO {{ dbt_sentinel.sentinel_rel('query_samples') }}
    ({{ cols | join(', ') }})
SELECT
    SYSUTCDATETIME(), q.request_id, q.session_id, q.login_name, q.app_name, q.status,
    q.submit_time_utc, q.start_time_utc, q.end_time_utc, q.total_elapsed_ms, q.queue_ms,
    q.statement_type, q.label, q.resource_class, q.[importance], q.group_name, q.error_id,
    q.result_cache_hit, q.command_text
FROM (
{{ dbt_sentinel.sentinel__requests_select(finished_only=true) }}
) AS q
{# end_time is datetime (1/300 s ticks) but is stored as datetime2(3); compare
   at the stored precision so the boundary request is not copied again. #}
{% if wm %}WHERE CAST(q.end_time_utc AS datetime2(3)) > CAST(N'{{ dbt_sentinel.sentinel_timestamp_text(wm) }}' AS datetime2(3)){% endif %}
  {%- endset -%}
  {% do dbt_sentinel.sentinel_execute(sql, dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: query sample stored (requests finished after ' ~ (wm if wm else 'the start of DMV retention') ~ ')', info=true) %}
{%- endmacro %}


{# ====================================================== integration writers #}

{% macro sentinel__normalise_stage_status(status) -%}
  {%- set s = (status | string | lower | trim) | replace(' ', '') | replace('_', '') -%}
  {%- set mapping = {
      'success': 'success', 'succeeded': 'success', 'ok': 'success', 'passed': 'success', 'completed': 'success',
      'succeededwithissues': 'warning', 'warning': 'warning', 'warn': 'warning', 'partiallysucceeded': 'warning',
      'failed': 'failed', 'failure': 'failed', 'error': 'failed', 'fail': 'failed',
      'running': 'running', 'started': 'running', 'inprogress': 'running',
      'skipped': 'skipped',
      'cancelled': 'cancelled', 'canceled': 'cancelled'
  } -%}
  {%- if s not in mapping -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: unknown stage status '" ~ status ~ "'. Use success, warning, failed, running, skipped or cancelled (Azure DevOps Agent.JobStatus values are also accepted).") }}
  {%- endif -%}
  {{ return(mapping[s]) }}
{%- endmacro %}

{% macro sentinel_record_stage(pipeline_name, stage, status, pipeline_run_id=none, source_name=none, rows_loaded=none, started_at=none, completed_at=none, message=none) -%}
  {#- Orchestrator stage event (Landing, Bronze/Spark, _SRC, Silver, Gold, ...). -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- for k, v in {'pipeline_name': pipeline_name, 'stage': stage, 'status': status, 'pipeline_run_id': pipeline_run_id,
                   'source_name': source_name, 'rows_loaded': rows_loaded, 'started_at': started_at,
                   'completed_at': completed_at, 'message': message}.items() -%}
    {%- do dbt_sentinel.sentinel_scalar_arg(k, v) -%}
  {%- endfor -%}
  {%- if not pipeline_name or not stage -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel: sentinel_record_stage requires pipeline_name and stage.') }}
  {%- endif -%}
  {%- set run_id = pipeline_run_id if pipeline_run_id is not none else dbt_sentinel.sentinel_pipeline_context()['pipeline_run_id'] -%}
  {%- set event_at = completed_at or started_at or dbt_sentinel.sentinel_sql('SYSUTCDATETIME()') -%}
  {%- set norm = dbt_sentinel.sentinel__normalise_stage_status(status) -%}
  {% do dbt_sentinel.sentinel_insert('stage_events', [{
      'pipeline_name': pipeline_name | string | trim,
      'pipeline_run_id': run_id,
      'stage': stage | string | lower | trim,
      'source_name': source_name,
      'status': norm,
      'rows_loaded': rows_loaded,
      'started_at_utc': started_at,
      'completed_at_utc': completed_at,
      'event_at_utc': event_at,
      'message': message,
      'recorded_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()')
  }], dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: stage ' ~ pipeline_name ~ '/' ~ stage ~ (('/' ~ source_name) if source_name else '') ~ ' = ' ~ norm, info=true) %}
{%- endmacro %}

{% macro sentinel__freshness_row(check) -%}
  {%- if check is not mapping -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel: each freshness check must be an object.') }}
  {%- endif -%}
  {%- for k in ['source_id', 'status', 'age_minutes', 'threshold_minutes', 'max_loaded_at', 'checked_at', 'message', 'pipeline_run_id'] -%}
    {%- do dbt_sentinel.sentinel_scalar_arg(k, check.get(k)) -%}
  {%- endfor -%}
  {%- if not check.get('source_id') or not check.get('status') -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel: freshness checks require source_id and status.') }}
  {%- endif -%}
  {%- set s = check.get('status') | string | lower | trim | replace('_', ' ') -%}
  {%- set mapping = {'pass': 'pass', 'success': 'pass', 'ok': 'pass', 'warn': 'warn', 'warning': 'warn',
                     'error': 'error', 'fail': 'error', 'failed': 'error', 'runtime error': 'runtime error'} -%}
  {%- if s not in mapping -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: unknown freshness status '" ~ check.get('status') ~ "'. Use pass, warn, error or runtime error.") }}
  {%- endif -%}
  {%- set run_id = check.get('pipeline_run_id') if check.get('pipeline_run_id') is not none else dbt_sentinel.sentinel_pipeline_context()['pipeline_run_id'] -%}
  {{ return({
      'source_id': check.get('source_id') | string | trim,
      'status': mapping[s],
      'max_loaded_at_utc': check.get('max_loaded_at'),
      'age_minutes': check.get('age_minutes'),
      'threshold_minutes': check.get('threshold_minutes'),
      'checked_at_utc': check.get('checked_at') or dbt_sentinel.sentinel_sql('SYSUTCDATETIME()'),
      'message': check.get('message'),
      'pipeline_run_id': run_id,
      'project_name': project_name,
      'target_name': target.name,
      'recorded_at_utc': dbt_sentinel.sentinel_sql('SYSUTCDATETIME()')
  }) }}
{%- endmacro %}

{% macro sentinel_record_freshness(source_id, status, age_minutes=none, threshold_minutes=none, max_loaded_at=none, checked_at=none, message=none, pipeline_run_id=none) -%}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set row = dbt_sentinel.sentinel__freshness_row({
      'source_id': source_id, 'status': status, 'age_minutes': age_minutes, 'threshold_minutes': threshold_minutes,
      'max_loaded_at': max_loaded_at, 'checked_at': checked_at, 'message': message, 'pipeline_run_id': pipeline_run_id}) -%}
  {% do dbt_sentinel.sentinel_insert('freshness_events', [row], dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {% do log('dbt_sentinel: freshness ' ~ row['source_id'] ~ ' = ' ~ row['status'], info=true) %}
{%- endmacro %}

{% macro sentinel_record_freshness_batch(checks) -%}
  {#- checks: list of objects with the sentinel_record_freshness argument names.
      scripts/freshness_to_sentinel.py builds these from target/sources.json. -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- if checks is string or checks is mapping or checks is not iterable -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel: checks must be a list of objects.') }}
  {%- endif -%}
  {%- set rows = [] -%}
  {%- for c in checks -%}{%- do rows.append(dbt_sentinel.sentinel__freshness_row(c)) -%}{%- endfor -%}
  {%- if rows | length > 0 -%}
    {% do dbt_sentinel.sentinel_insert('freshness_events', rows, dbt_sentinel.sentinel_on_error_mode('operation')) %}
  {%- endif -%}
  {% do log('dbt_sentinel: ' ~ rows | length ~ ' freshness results stored', info=true) %}
{%- endmacro %}


{# =================================================================== purge #}

{% macro sentinel_purge_history(keep_days=180, dry_run=false, prune_manifests=false) -%}
  {#- Deletes time-series telemetry older than keep_days. Manifest snapshots,
      nodes, edges and install_log are deployment/audit metadata and are kept,
      unless prune_manifests=true: then superseded manifest snapshots (not the
      latest for their project x target) captured before the cutoff are
      deleted with their nodes and edges. The latest snapshot is always kept. -#}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {{ dbt_sentinel.sentinel_assert_adapter() }}
  {%- set k = keep_days | string | trim -%}
  {%- if not modules.re.fullmatch('[0-9]+', k) or (k | int) < 7 -%}
    {{ exceptions.raise_compiler_error('dbt_sentinel: keep_days must be an integer >= 7.') }}
  {%- endif -%}
  {%- set cutoff = 'DATEADD(day, -' ~ (k | int) ~ ', SYSUTCDATETIME())' -%}
  {%- set targets = [
      ['node_results', 'recorded_at_utc'],
      ['run_events', 'event_at_utc'],
      ['warehouse_samples', 'sampled_at_utc'],
      ['storage_samples', 'sampled_at_utc'],
      ['stage_events', 'event_at_utc'],
      ['freshness_events', 'checked_at_utc'],
      ['query_samples', 'sampled_at_utc'],
      ['table_health_samples', 'sampled_at_utc']
  ] -%}
  {%- for t in targets -%}
    {%- set n = run_query('SELECT COUNT_BIG(*) AS n FROM ' ~ dbt_sentinel.sentinel_rel(t[0]) ~ ' WHERE [' ~ t[1] ~ '] < ' ~ cutoff).rows[0][0] -%}
    {%- if dry_run -%}
      {% do log('dbt_sentinel purge (dry run): ' ~ t[0] ~ ' would delete ' ~ n ~ ' rows', info=true) %}
    {%- elif (n | int) > 0 -%}
      {% do run_query('DELETE FROM ' ~ dbt_sentinel.sentinel_rel(t[0]) ~ ' WHERE [' ~ t[1] ~ '] < ' ~ cutoff) %}
      {% do log('dbt_sentinel purge: ' ~ t[0] ~ ' deleted ' ~ n ~ ' rows', info=true) %}
    {%- endif -%}
  {%- endfor -%}

  {%- if prune_manifests -%}
    {%- set superseded -%}
SELECT x.snapshot_id
FROM (
    SELECT ms.snapshot_id, ms.captured_at_utc,
           ROW_NUMBER() OVER (PARTITION BY ms.project_name, ms.target_name ORDER BY ms.captured_at_utc DESC) AS rn
    FROM {{ dbt_sentinel.sentinel_rel('manifest_snapshots') }} AS ms
) AS x
WHERE x.rn > 1 AND x.captured_at_utc < {{ cutoff }}
    {%- endset -%}
    {%- set n = run_query('SELECT COUNT_BIG(*) AS n FROM (' ~ superseded ~ ') AS s').rows[0][0] -%}
    {%- if dry_run -%}
      {% do log('dbt_sentinel purge (dry run): ' ~ n ~ ' superseded manifest snapshots would be deleted', info=true) %}
    {%- elif (n | int) > 0 -%}
      {#- Nodes and edges first, header last: if the purge stops part-way, the
          snapshot header still exists and the remaining rows can be purged on
          the next run (never orphaned). -#}
      {%- for t in ['manifest_edges', 'manifest_nodes', 'manifest_snapshots'] -%}
        {% do run_query('DELETE FROM ' ~ dbt_sentinel.sentinel_rel(t) ~ ' WHERE [snapshot_id] IN (\n' ~ superseded ~ '\n)') %}
      {%- endfor -%}
      {% do log('dbt_sentinel purge: deleted ' ~ n ~ ' superseded manifest snapshots with their nodes and edges', info=true) %}
    {%- endif -%}
  {%- endif -%}
{%- endmacro %}
