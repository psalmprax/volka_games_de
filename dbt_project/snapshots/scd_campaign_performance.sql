{%- snapshot scd_campaign_performance -%}
{#
This snapshot creates a Type 2 Slowly Changing Dimension (SCD) table
for campaign performance data. It tracks historical changes to records
based on the `check` strategy.

**Source**: `public.campaign_performance_raw_appends`
**Strategy**: `check` on all columns to detect any data changes.
**Unique Key**: A composite key of `campaigns_execution_date`, `campaign_name`, and `ad_name`.
**Purpose**: To provide a full historical view of campaign metrics, allowing for
analysis of how data may have been restated or corrected over time.
#}

{%- set unique_key_expr = "CONCAT(cast(campaigns_execution_date as " ~ dbt.type_string() ~ "), '-', campaign_name, '-', ad_name)" -%}

{{
    config(
      target_schema="main" if target.name == 'duckdb_iceberg' else "public",
      strategy='check',
      unique_key=unique_key_expr,
      check_cols='all',
      updated_at='_etl_loaded_at'
    )
}}

select * from {{ source('raw_data_source', 'campaign_performance_raw_appends') }}


{%- endsnapshot -%}