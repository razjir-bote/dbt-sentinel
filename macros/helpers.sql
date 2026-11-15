{#-
  dbt Sentinel - helpers.sql
  Adapter checks, configuration, identifier/literal escaping, batched inserts.

  Synapse Dedicated SQL Pool notes that shape this file:
    * INSERT ... VALUES accepts one row only, so batches are written as
      INSERT INTO t (...) SELECT ... UNION ALL SELECT ...
    * UNION ALL resolves column types from every branch, so every literal is
      wrapped in CAST(<literal> AS <column type>) - a NULL in the first row
      would otherwise be typed as int and break later string rows.
    * Cross-database (three-part) names are not supported; all objects are
      addressed as [schema].[object] in the connected database.
-#}

{% macro sentinel_version() -%}
  {{ return('0.2.2') }}
{%- endmacro %}

{% macro sentinel_schema_version() -%}
  {#- Bump when table definitions change; recorded in install_log. -#}
  {{ return(3) }}
{%- endmacro %}


{# ------------------------------------------------------------------ config #}

{% macro sentinel_identifier(value, what='identifier') -%}
  {%- set s = value | string -%}
  {%- if not modules.re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,127}', s) -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: " ~ what ~ " '" ~ s ~ "' must be a simple identifier (letters, digits and underscores, not starting with a digit).") }}
  {%- endif -%}
  {{ return(s) }}
{%- endmacro %}

{% macro sentinel_quote_name(value, what='principal') -%}
  {#- Bracket-quotes a database principal name (role, user or Entra ID group such
      as 'PBI-Readers' or 'svc_pbi@contoso.com'). Any printable name up to 128
      characters is accepted; ']' is escaped. -#}
  {%- set s = (value | string | trim) if value is not none else '' -%}
  {%- if s == '' or s | length > 128 or not s.isprintable() -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: " ~ what ~ " '" ~ s ~ "' must be a non-empty name of at most 128 printable characters.") }}
  {%- endif -%}
  {{ return('[' ~ s.replace(']', ']]') ~ ']') }}
{%- endmacro %}

{% macro sentinel_schema() -%}
  {{ return(dbt_sentinel.sentinel_identifier(var('sentinel_schema', 'sentinel'), 'sentinel_schema')) }}
{%- endmacro %}

{% macro sentinel_rel(name) -%}
  {#- Two-part, bracket-quoted name of a Sentinel object. -#}
  {{ return('[' ~ dbt_sentinel.sentinel_schema() ~ '].[' ~ dbt_sentinel.sentinel_identifier(name, 'object name') ~ ']') }}
{%- endmacro %}

{% macro sentinel_int_var(name, default, minimum=none) -%}
  {%- set raw = var(name, default) | string | trim -%}
  {%- if not modules.re.fullmatch('[0-9]+', raw) -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must be a non-negative integer, got '" ~ raw ~ "'.") }}
  {%- endif -%}
  {%- set v = raw | int -%}
  {%- if minimum is not none and v < minimum -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must be >= " ~ minimum ~ ", got " ~ v ~ ".") }}
  {%- endif -%}
  {{ return(v) }}
{%- endmacro %}

{% macro sentinel_bool_var(name, default) -%}
  {#- Booleans from env_var() or quoted --vars arrive as strings; 'false' must
      mean false. Accepts true/false, 1/0, yes/no, y/n, on/off (any case). -#}
  {%- set raw = var(name, default) -%}
  {%- if raw is sameas true or raw is sameas false -%}{{ return(raw) }}{%- endif -%}
  {%- if raw is none -%}{{ return(false) }}{%- endif -%}
  {%- set s = raw | string | lower | trim -%}
  {%- if s in ['true', '1', 'yes', 'y', 'on'] -%}{{ return(true) }}{%- endif -%}
  {%- if s in ['false', '0', 'no', 'n', 'off', '', 'none', 'null'] -%}{{ return(false) }}{%- endif -%}
  {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must be a boolean (true/false), got '" ~ raw ~ "'.") }}
{%- endmacro %}

{% macro sentinel_list_var(name, default) -%}
  {#- A list of strings. A plain string (e.g. from env_var() or --vars
      'x: a') is read as a comma-separated list, never character by character. -#}
  {%- set raw = var(name, default) -%}
  {%- if raw is none -%}{{ return([]) }}{%- endif -%}
  {%- if raw is string -%}
    {%- set out = [] -%}
    {%- for part in raw.split(',') -%}
      {%- if part | trim != '' -%}{%- do out.append(part | trim) -%}{%- endif -%}
    {%- endfor -%}
    {{ return(out) }}
  {%- endif -%}
  {%- if raw is mapping or raw is not iterable -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must be a list of strings (or a comma-separated string).") }}
  {%- endif -%}
  {%- set out = [] -%}
  {%- for item in raw -%}
    {%- if item is mapping or (item is iterable and item is not string) -%}
      {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must contain only strings.") }}
    {%- endif -%}
    {%- do out.append(item | string | trim) -%}
  {%- endfor -%}
  {{ return(out) }}
{%- endmacro %}

{% macro sentinel_float_var(name, default) -%}
  {%- set raw = var(name, default) | string | trim -%}
  {%- if not modules.re.fullmatch('[0-9]+([.][0-9]+)?', raw) -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: var '" ~ name ~ "' must be a non-negative number, got '" ~ raw ~ "'.") }}
  {%- endif -%}
  {{ return(raw | float) }}
{%- endmacro %}

{% macro sentinel_on_error_mode(context_kind='hook') -%}
  {#- 'warn' wraps writes in TRY/CATCH and logs a warning; 'fail' raises. -#}
  {%- if context_kind == 'hook' -%}
    {%- set mode = var('sentinel_hook_on_error', 'warn') | string | lower -%}
  {%- else -%}
    {%- set mode = var('sentinel_operation_on_error', 'fail') | string | lower -%}
  {%- endif -%}
  {%- if mode not in ['warn', 'fail'] -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: on-error mode must be 'warn' or 'fail', got '" ~ mode ~ "'.") }}
  {%- endif -%}
  {{ return(mode) }}
{%- endmacro %}


{# ------------------------------------------------------- adapter / context #}

{% macro sentinel_is_supported_adapter() -%}
  {{ return(target.type in dbt_sentinel.sentinel_list_var('sentinel_supported_adapters', ['synapse'])) }}
{%- endmacro %}

{% macro sentinel_assert_adapter() -%}
  {%- if not dbt_sentinel.sentinel_is_supported_adapter() -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel supports Azure Synapse Dedicated SQL Pool via dbt-synapse (target.type 'synapse'); current target.type is '" ~ target.type ~ "'. Set var sentinel_supported_adapters to override at your own risk.") }}
  {%- endif -%}
{%- endmacro %}

{% macro sentinel_command() -%}
  {#- The dbt sub-command being run (build, run, test, ...). -#}
  {%- set which = none -%}
  {%- if flags is defined and flags.WHICH is defined and flags.WHICH -%}
    {%- set which = flags.WHICH -%}
  {%- elif invocation_args_dict is defined and invocation_args_dict.get('which') -%}
    {%- set which = invocation_args_dict.get('which') -%}
  {%- endif -%}
  {{ return((which | string | lower) if which is not none else 'unknown') }}
{%- endmacro %}

{% macro sentinel_warn(message) -%}
  {#- Non-fatal notice. Deliberately not exceptions.warn: under --warn-error /
      --warn-error-options dbt promotes that to an error, which would let a
      swallowed telemetry problem fail the host build. -#}
  {% do log('[WARNING] ' ~ message, info=true) %}
{%- endmacro %}

{% macro sentinel_hooks_active() -%}
  {%- if not execute or not dbt_sentinel.sentinel_bool_var('sentinel_enabled', true) -%}
    {{ return(false) }}
  {%- endif -%}
  {%- if not dbt_sentinel.sentinel_is_supported_adapter() -%}
    {% do dbt_sentinel.sentinel_warn("dbt_sentinel: hooks skipped - adapter '" ~ target.type ~ "' is not supported.") %}
    {{ return(false) }}
  {%- endif -%}
  {%- set tracked = dbt_sentinel.sentinel_list_var('sentinel_tracked_commands', ['build', 'run', 'test', 'seed', 'snapshot']) -%}
  {{ return(dbt_sentinel.sentinel_command() in tracked) }}
{%- endmacro %}

{% macro sentinel_pipeline_context() -%}
  {#-
    Pipeline metadata. Explicit SENTINEL_* environment variables win, otherwise
    the Azure DevOps predefined variables are used. No secrets are read.
  -#}
  {%- set ctx = {
      'pipeline_name':   env_var('SENTINEL_PIPELINE_NAME',   env_var('BUILD_DEFINITIONNAME', '')),
      'pipeline_run_id': env_var('SENTINEL_PIPELINE_RUN_ID', env_var('BUILD_BUILDID', '')),
      'commit_id':       env_var('SENTINEL_COMMIT_ID',       env_var('BUILD_SOURCEVERSION', '')),
      'branch_name':     env_var('SENTINEL_BRANCH',          env_var('BUILD_SOURCEBRANCH', '')),
      'build_reason':    env_var('SENTINEL_BUILD_REASON',    env_var('BUILD_REASON', ''))
  } -%}
  {%- set cleaned = {} -%}
  {%- for k, v in ctx.items() -%}
    {%- do cleaned.update({k: (v if v else none)}) -%}
  {%- endfor -%}
  {{ return(cleaned) }}
{%- endmacro %}


{# --------------------------------------------------------------- literals #}

{% macro sentinel_sql(expression) -%}
  {#- Marks a trusted, package-authored SQL expression (never user input). -#}
  {{ return({'__sentinel_sql__': expression}) }}
{%- endmacro %}

{% macro sentinel_scalar_arg(name, value) -%}
  {#- Rejects mappings/lists in operator-supplied arguments. -#}
  {%- if value is mapping or (value is iterable and value is not string) -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: argument '" ~ name ~ "' must be a scalar value.") }}
  {%- endif -%}
  {{ return(value) }}
{%- endmacro %}

{% macro sentinel_nstring(value, max_length=4000) -%}
  {%- set s = value | string -%}
  {%- set s = s.replace('\x00', '').replace('\r\n', ' ').replace('\n', ' ').replace('\r', ' ').replace('\t', ' ') -%}
  {%- if s | length > max_length -%}
    {%- set s = s[:(max_length - 3)] ~ '...' -%}
  {%- endif -%}
  {{ return("N'" ~ s.replace("'", "''") ~ "'") }}
{%- endmacro %}

{% macro sentinel_timestamp_text(value) -%}
  {#- Returns 'YYYY-MM-DD HH:MM:SS[.fffffff]' (UTC) or raises. -#}
  {%- if value.strftime is defined -%}
    {%- set dt = value -%}
    {%- if dt.tzinfo is defined and dt.tzinfo is not none -%}
      {%- set dt = dt.astimezone(modules.pytz.utc) -%}
    {%- endif -%}
    {{ return(dt.strftime('%Y-%m-%d %H:%M:%S.%f')) }}
  {%- endif -%}
  {%- set s = value | string | trim -%}
  {%- set m = modules.re.fullmatch('([0-9]{4}-[0-9]{2}-[0-9]{2})(?:[T ]([0-9]{2}:[0-9]{2}(?::[0-9]{2})?)(?:[.]([0-9]{1,7})[0-9]*)?)?(Z|[+-]00:?00)?', s) -%}
  {%- if not m -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: '" ~ s ~ "' is not an ISO-8601 UTC timestamp (use e.g. 2026-01-31T04:05:06Z; non-UTC offsets are rejected).") }}
  {%- endif -%}
  {%- set out = m.group(1) ~ ' ' ~ (m.group(2) if m.group(2) else '00:00') -%}
  {%- if m.group(2) and m.group(2) | length == 5 -%}{%- set out = out ~ ':00' -%}{%- elif not m.group(2) -%}{%- set out = out ~ ':00' -%}{%- endif -%}
  {%- if m.group(3) -%}{%- set out = out ~ '.' ~ m.group(3) -%}{%- endif -%}
  {{ return(out) }}
{%- endmacro %}

{% macro sentinel_literal(value, sql_type) -%}
  {#- Renders CAST(<safe literal> AS <sql_type>). -#}
  {%- set t = sql_type | lower -%}
  {%- if value is mapping and '__sentinel_sql__' in value -%}
    {{ return('CAST(' ~ value['__sentinel_sql__'] ~ ' AS ' ~ sql_type ~ ')') }}
  {%- endif -%}
  {%- if value is none or value is undefined or (value is string and value | trim == '' and not t.startswith('nvarchar')) -%}
    {{ return('CAST(NULL AS ' ~ sql_type ~ ')') }}
  {%- endif -%}

  {%- if t.startswith('nvarchar') -%}
    {%- set m = modules.re.search('[(]([0-9]+)[)]', t) -%}
    {%- set lit = dbt_sentinel.sentinel_nstring(value, (m.group(1) | int) if m else 4000) -%}

  {%- elif t == 'bit' -%}
    {%- set s = value | string | lower | trim -%}
    {%- if s in ['true', '1', 'yes', 'y'] -%}{%- set lit = '1' -%}
    {%- elif s in ['false', '0', 'no', 'n'] -%}{%- set lit = '0' -%}
    {%- else -%}
      {{ exceptions.raise_compiler_error("dbt_sentinel: '" ~ s ~ "' is not a boolean.") }}
    {%- endif -%}

  {%- elif t in ['int', 'bigint', 'smallint', 'tinyint'] -%}
    {%- set s = value | string | trim -%}
    {%- if modules.re.fullmatch('[-+]?[0-9]+[.]0+', s) -%}{%- set s = s.split('.')[0] -%}{%- endif -%}
    {%- if not modules.re.fullmatch('[-+]?[0-9]{1,19}', s) -%}
      {{ exceptions.raise_compiler_error("dbt_sentinel: '" ~ s ~ "' is not an integer.") }}
    {%- endif -%}
    {%- set lit = s -%}

  {%- elif t == 'float' or t.startswith('decimal') or t.startswith('numeric') -%}
    {%- set s = value | string | trim -%}
    {%- if not modules.re.fullmatch('[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?', s) -%}
      {{ exceptions.raise_compiler_error("dbt_sentinel: '" ~ s ~ "' is not a number.") }}
    {%- endif -%}
    {%- set lit = s -%}

  {%- elif t.startswith('datetime2') or t == 'date' -%}
    {%- set lit = "N'" ~ dbt_sentinel.sentinel_timestamp_text(value) ~ "'" -%}

  {%- else -%}
    {{ exceptions.raise_compiler_error("dbt_sentinel: unsupported column type '" ~ sql_type ~ "'.") }}
  {%- endif -%}
  {{ return('CAST(' ~ lit ~ ' AS ' ~ sql_type ~ ')') }}
{%- endmacro %}


{# -------------------------------------------------------------- execution #}

{% macro sentinel_execute(sql, on_error='fail', label='telemetry write') -%}
  {#-
    Runs one batch. In 'warn' mode the statement is wrapped in TRY/CATCH and the
    error is returned as a result set, logged (see sentinel_warn) and swallowed,
    so telemetry problems do not fail a production build. Object and column
    name-resolution errors (Sentinel not installed, or installed from an older
    version) are compile errors in T-SQL that TRY/CATCH cannot catch;
    sentinel_insert checks the table and its columns before writing. A lost
    connection still raises from run_query, since Jinja has no exception
    handling.
  -#}
  {%- if on_error == 'fail' -%}
    {% do run_query(sql) %}
    {{ return(true) }}
  {%- endif -%}
  {%- set wrapped -%}
SET NOCOUNT ON;
BEGIN TRY
{{ sql }};
SELECT CAST(0 AS int) AS sentinel_error_number, CAST(NULL AS nvarchar(4000)) AS sentinel_error_message;
END TRY
BEGIN CATCH
SELECT ERROR_NUMBER() AS sentinel_error_number, CAST(ERROR_MESSAGE() AS nvarchar(4000)) AS sentinel_error_message;
END CATCH
  {%- endset -%}
  {%- set res = run_query(wrapped) -%}
  {%- if res is not none and res.rows | length > 0 and (res.rows[0][0] | int) != 0 -%}
    {% do dbt_sentinel.sentinel_warn("dbt_sentinel: " ~ label ~ " failed (error " ~ res.rows[0][0] ~ "): " ~ res.rows[0][1]) %}
    {{ return(false) }}
  {%- endif -%}
  {{ return(true) }}
{%- endmacro %}

{% macro sentinel_table_ready(table_name) -%}
  {#- none when the table exists with every column this package version writes;
      otherwise a short description of what is missing. -#}
  {%- set names = [] -%}
  {%- for c in dbt_sentinel.sentinel_table_columns()[table_name] -%}
    {%- do names.append(dbt_sentinel.sentinel_nstring(c[0] | lower)) -%}
  {%- endfor -%}
  {%- set sql -%}
SELECT tf.n AS table_found, cf.n AS columns_found
FROM (
    SELECT COUNT(*) AS n
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = {{ dbt_sentinel.sentinel_nstring(dbt_sentinel.sentinel_schema()) }}
      AND t.name = {{ dbt_sentinel.sentinel_nstring(table_name) }}
) AS tf
CROSS JOIN (
    SELECT COUNT(*) AS n
    FROM sys.columns AS c
    JOIN sys.tables AS t ON t.object_id = c.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = {{ dbt_sentinel.sentinel_nstring(dbt_sentinel.sentinel_schema()) }}
      AND t.name = {{ dbt_sentinel.sentinel_nstring(table_name) }}
      AND LOWER(c.name) IN ({{ names | join(', ') }})
) AS cf
  {%- endset -%}
  {%- set res = run_query(sql) -%}
  {%- if res is none or res.rows | length == 0 or (res.rows[0][0] | int) == 0 -%}
    {{ return('table ' ~ dbt_sentinel.sentinel_rel(table_name) ~ ' not found') }}
  {%- endif -%}
  {%- if (res.rows[0][1] | int) < names | length -%}
    {{ return('table ' ~ dbt_sentinel.sentinel_rel(table_name) ~ ' is missing ' ~ (names | length - (res.rows[0][1] | int)) ~ ' column(s) added in a newer dbt_sentinel version') }}
  {%- endif -%}
  {{ return(none) }}
{%- endmacro %}

{% macro sentinel_insert(table_name, rows, on_error='fail') -%}
  {#-
    Inserts a list of dicts into a Sentinel table in batches of
    var('sentinel_batch_size'). Missing keys become typed NULLs; unknown keys
    are ignored. Returns the number of rows submitted, or -1 if any batch
    failed or the table is not ready (warn mode; nothing is written). In
    'fail' mode an unready table raises a clear error instead of a raw
    'Invalid column name' from the database.
  -#}
  {%- set problem = dbt_sentinel.sentinel_table_ready(table_name) -%}
  {%- if problem is not none -%}
    {%- set msg = 'dbt_sentinel: ' ~ problem ~ ". Run 'dbt run-operation sentinel_install' for this target." -%}
    {%- if on_error == 'warn' -%}
      {% do dbt_sentinel.sentinel_warn(msg ~ ' Telemetry skipped.') %}
      {{ return(-1) }}
    {%- endif -%}
    {{ exceptions.raise_compiler_error(msg) }}
  {%- endif -%}
  {%- set cols = dbt_sentinel.sentinel_table_columns()[table_name] -%}
  {%- set size = dbt_sentinel.sentinel_int_var('sentinel_batch_size', 35, 1) -%}
  {%- set col_list = [] -%}
  {%- for c in cols -%}{%- do col_list.append('[' ~ c[0] ~ ']') -%}{%- endfor -%}
  {%- set ns = namespace(ok=true) -%}
  {%- for chunk in rows | batch(size) -%}
    {%- set selects = [] -%}
    {%- for row in chunk -%}
      {%- set lits = [] -%}
      {%- for c in cols -%}
        {%- do lits.append(dbt_sentinel.sentinel_literal(row.get(c[0]), c[1])) -%}
      {%- endfor -%}
      {%- do selects.append('SELECT ' ~ lits | join(', ')) -%}
    {%- endfor -%}
    {%- set sql = 'INSERT INTO ' ~ dbt_sentinel.sentinel_rel(table_name) ~ ' (' ~ col_list | join(', ') ~ ')\n' ~ selects | join('\nUNION ALL\n') -%}
    {%- if not dbt_sentinel.sentinel_execute(sql, on_error) -%}{%- set ns.ok = false -%}{%- endif -%}
  {%- endfor -%}
  {{ return(rows | length if ns.ok else -1) }}
{%- endmacro %}
