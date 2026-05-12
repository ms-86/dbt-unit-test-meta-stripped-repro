# dbt unit-test `config.meta` stripping — minimal reproducer

A minimal dbt project that demonstrates a discrepancy between **normal model
rendering** and **unit-test rendering**: the model's own `config.meta` is
visible during `dbt compile` / `dbt run`, but is replaced with an empty dict
`{}` when the same model is rendered inside a `dbt test` unit test. The
behavior is the same on dbt Core and dbt Fusion — Fusion reproduces Core here.

No third-party dbt packages, no custom macros — just stock dbt + dbt-duckdb.

## Symptoms

Same model, same Jinja, two different render paths produce two different
outputs:

| Source of `meta` | `dbt compile` (model) | `dbt test` (unit test) |
|-----------------|----------------------|------------------------|
| `{{ config(meta={...}) }}` in `.sql` | visible | stripped to `{}` |
| `config.meta:` in `.yml` | visible | stripped to `{}` |

Concrete output from this project:

```sql
-- target/compiled/.../meta_probe.sql  (normal model render — both engines)
SELECT
    CAST('True'         AS VARCHAR) AS sql_block_flag,
    CAST('set-from-sql' AS VARCHAR) AS sql_block_label,
    CAST('set-from-yml' AS VARCHAR) AS yml_block_flag,
    CAST('{...}'        AS VARCHAR) AS meta_dict_repr

-- target/compiled/.../meta_probe_sees_meta.sql  (unit test render — both engines)
SELECT
    CAST('NOT_SET' AS VARCHAR) AS sql_block_flag,
    CAST('NOT_SET' AS VARCHAR) AS sql_block_label,
    CAST('NOT_SET' AS VARCHAR) AS yml_block_flag,
    CAST('{}'      AS VARCHAR) AS meta_dict_repr
```

## Why this matters

Several dbt packages switch SQL on `config.meta` toggles. The most prominent
example is [**automate_dv**](https://github.com/Datavault-UK/automate-dv),
where `automate_dv.databricks__eff_sat` reads `is_auto_end_dating` from the
model's config to choose between the auto-end-dating SQL pattern and the
manual one
([`macros/tables/databricks/eff_sat.sql:11`](https://github.com/Datavault-UK/automate-dv/blob/master/macros/tables/databricks/eff_sat.sql#L11)):

```jinja
{%- set is_auto_end_dating = automate_dv.config_meta_get('is_auto_end_dating', default=false) %}
```

`automate_dv.config_meta_get` lives in
[`macros/supporting/fusion_compat.sql`](https://github.com/Datavault-UK/automate-dv/blob/master/macros/supporting/fusion_compat.sql)
and probes **both** the `meta` dict and the top-level config:

```jinja
{% macro _config_meta_lookup(key) %}
    {%- set meta = config.get('meta') or {} -%}
    {%- if key in meta -%}
        {{ return(meta[key]) }}
    {%- endif -%}
    {%- set config_val = config.get(key) -%}
    {%- if config_val is not none -%}
        {{ return(config_val) }}
    {%- endif -%}
    {{ return(none) }}
{% endmacro %}
```

The file is named `fusion_compat.sql` because it was added in
[automate_dv commit 704b775](https://github.com/Datavault-UK/automate-dv/commit/704b775f72)
(Sept 2025) — **not** because the helper itself is engine-specific (it's
plain Jinja that runs on every adapter and on both engines), but because of
the **policy** difference it works around: dbt Fusion enforces strict
validation of custom top-level config keys
([dbt-fusion#511](https://github.com/dbt-labs/dbt-fusion/issues/511)), so the
legacy automate_dv pattern `{{ config(is_auto_end_dating=true) }}` is
rejected on Fusion. The Fusion-compatible pattern is to nest the toggle
under `meta`: `{{ config(meta={'is_auto_end_dating': true}) }}`.
`config_meta_get` accepts both forms so the same package keeps working on
Core (where either form is syntactically allowed) and on Fusion (where only
the `meta`-nested form is allowed).

**The unit-test bug reported here defeats both forms.** Because dbt rebuilds
`config` from scratch as an empty `UnitTestNodeConfig` for the unit-test
render, neither `config.get('meta').get(key)` nor `config.get(key)` returns
anything when the tested model runs inside a unit test. The auto-end-dating
branch of `automate_dv.eff_sat` therefore becomes **unreachable in any unit
test, on either engine**. The same is true of any other package or user
macro that switches SQL on `config.meta`. Users either give up on
unit-testing those models, or have to re-implement the macro to hard-code
the toggle and avoid the lookup.

## Root cause (dbt-core)

`core/dbt/parser/unit_tests.py` builds the `UnitTestNode` with a fresh
`UnitTestNodeConfig` that only carries `materialized`, `expected_rows`, and
`expected_sql` — none of the tested model's config (including `meta`) is
propagated:

```python
# core/dbt/parser/unit_tests.py
unit_test_node = UnitTestNode(
    ...,
    config=UnitTestNodeConfig(
        materialized="unit",
        expected_rows=expected_rows,
        expected_sql=expected_sql,
    ),
    raw_code=tested_node.raw_code,   # tested model's Jinja
    ...,
)

ctx = generate_parser_unit_test_context(unit_test_node, ...)
get_rendered(unit_test_node.raw_code, ctx, unit_test_node, capture_macros=True)
```

`get_rendered` then renders the tested model's `raw_code` against the empty
`UnitTestNodeConfig`, so `config.get('meta')` returns the default `{}`.

## Setup

```bash
uv sync         # installs dbt-core 1.11.6 + dbt-duckdb
```

(Also install `dbt-fusion` separately per
https://docs.getdbt.com/docs/fusion if you want to confirm Fusion matches
Core.)

## Reproduce

### dbt Core

```bash
uv run dbt compile --profiles-dir . --select meta_probe
# → meta values flow into the SELECT

uv run dbt test    --profiles-dir . --select meta_probe
# → unit test fails: meta values come out as NOT_SET / {}
cat target/compiled/unit_test_meta_repro/models/meta_probe.yml/models/meta_probe_sees_meta.sql
```

### dbt Fusion

```bash
dbt compile --profiles-dir . --select meta_probe
dbt test    --profiles-dir . --select meta_probe
cat target/compiled/models/meta_probe_sees_meta.sql
```

## Expected behavior

When dbt renders a tested model inside a unit test, `config.meta` should
return the same dictionary that `dbt compile` / `dbt run` would see — i.e. the
union of `meta` set via `{{ config(meta=...) }}` in the `.sql` file and
`config.meta:` in the `.yml`. Anything less makes meta-driven SQL switches
untestable.
