{#
This model cleans and prepares the raw campaign performance data.
It selects the most current records from the snapshot and performs basic transformations
like renaming columns and converting currency from cents to EUR.

**Grain**: One row per campaign, per ad, per day (most current version).

**Sources**:
- `scd_campaign_performance`: The dbt snapshot that tracks historical changes.

**Key Logic**:
- Filters for `dbt_valid_to is null` to get only the latest record for each natural key.
- Renames columns for business clarity.
- Converts monetary values from cents to a standard currency unit (EUR).
- Generates a surrogate key for use in downstream fact tables.
#}

with source as (
    -- Use the dbt snapshot to get the current version of each record
    select * from {{ ref('scd_campaign_performance') }}
    where dbt_valid_to is null -- This filter selects only the currently active records
),

renamed_and_cleaned as (
    select
        -- Generate a surrogate key using a cross-database compatible MD5 hash.
        -- This avoids potential macro resolution issues between dbt-core and adapters.
        md5(cast(campaigns_execution_date as {{ dbt.type_string() }}) || '-' ||
            cast(campaign_name as {{ dbt.type_string() }}) || '-' || cast(ad_name as {{ dbt.type_string() }})) as campaign_performance_sk,

        -- Identifiers and Dates
        campaigns_execution_date as report_date,
        campaign_name,
        ad_name,

        -- Metrics (convert from cents to standard currency unit)
        spend_cents / 100.0 as spend_eur,
        impressions,
        clicks,
        registrations,
        cpc_cents / 100.0 as cpc_eur,
        ctr,
        cr,

        -- Lifeday metrics
        players_1d, payers_1d, payments_1d, revenue_1d_cents / 100.0 as revenue_1d_eur,
        players_3d, payers_3d, payments_3d, revenue_3d_cents / 100.0 as revenue_3d_eur,
        players_7d, payers_7d, payments_7d, revenue_7d_cents / 100.0 as revenue_7d_eur,
        players_14d, payers_14d, payments_14d, revenue_14d_cents / 100.0 as revenue_14d_eur,

        -- Metadata for lineage
        dbt_valid_from as valid_from_timestamp,
        _etl_loaded_at as updated_at_timestamp
    from source
)

select * from renamed_and_cleaned