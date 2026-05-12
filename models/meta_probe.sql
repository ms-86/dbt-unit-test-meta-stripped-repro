{{- config(
    materialized='table',
    meta={'sql_flag': true, 'sql_label': 'set-from-sql'}
) -}}

{%- set sql_flag    = config.get('meta', {}).get('sql_flag',  'NOT_SET') -%}
{%- set sql_label   = config.get('meta', {}).get('sql_label', 'NOT_SET') -%}
{%- set yml_flag    = config.get('meta', {}).get('yml_flag',  'NOT_SET') -%}
{%- set meta_dict   = config.get('meta', {}) -%}

SELECT
    CAST('{{ sql_flag  }}' AS VARCHAR) AS sql_block_flag,
    CAST('{{ sql_label }}' AS VARCHAR) AS sql_block_label,
    CAST('{{ yml_flag  }}' AS VARCHAR) AS yml_block_flag,
    CAST('{{ meta_dict }}' AS VARCHAR) AS meta_dict_repr
