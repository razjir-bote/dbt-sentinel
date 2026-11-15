-- Fails only when --vars '{sentinel_it_force_failure: true}' is supplied.
{% if var('sentinel_it_force_failure', false) %}
select id from {{ ref('sentinel_it_passing') }}
{% else %}
select id from {{ ref('sentinel_it_passing') }} where 1 = 0
{% endif %}
