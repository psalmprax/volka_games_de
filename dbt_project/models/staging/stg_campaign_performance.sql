{%- doc -%}
This staging model provides a clean, current-state view of campaign performance.
It builds on top of the `scd_campaign_performance` snapshot, filtering for only the active records.

Key transformations:
- Renames columns to follow a consistent naming convention (e.g., `report_date`).
- Converts monetary values from cents to a standard currency unit (EUR).
- Generates a surrogate key (`campaign_performance_sk`) to uniquely identify each record.
{%- enddoc -%}

with source_snapshot as (

    -- Select the most recent, active records from the campaign performance snapshot.
    -- The `dbt_valid_to is null` filter is crucial for getting the current state.
    select *
    from {{ ref('scd_campaign_performance') }}
    where dbt_valid_to is null

),

renamed_and_casted as (

    select
        -- Generate a surrogate key to serve as the primary key for this model.
        {{ dbt_utils.generate_surrogate_key([
            'campaigns_execution_date',
            'campaign_name',
            'ad_name'
        ]) }} as campaign_performance_sk,

        -- Identifiers and Dates
        campaigns_execution_date as report_date,
        campaign_name,
        ad_name,

        -- Base Metrics (monetary values converted from cents to EUR)
        -- It's a good practice to recalculate derived metrics like CPC in the marts layer
        -- to ensure consistency, rather than relying on source-provided values.
        spend_cents / 100.0 as spend_eur,
        impressions,
        clicks,
        registrations,
        cpc_cents / 100.0 as cpc_eur,
        ctr,
        cr,

        -- 1-Day Lifeday Metrics
        players_1d,
        payers_1d,
        payments_1d,
        revenue_1d_cents / 100.0 as revenue_1d_eur,

        -- 3-Day Lifeday Metrics
        players_3d,
        payers_3d,
        payments_3d,
        revenue_3d_cents / 100.0 as revenue_3d_eur,

        -- 7-Day Lifeday Metrics
        players_7d,
        payers_7d,
        payments_7d,
        revenue_7d_cents / 100.0 as revenue_7d_eur,

        -- 14-Day Lifeday Metrics
        players_14d,
        payers_14d,
        payments_14d,
        revenue_14d_cents / 100.0 as revenue_14d_eur,

        -- Snapshot metadata for lineage and debugging
        dbt_valid_from as valid_from_timestamp,
        dbt_updated_at as updated_at_timestamp

    from source_snapshot
)

select * from renamed_and_casted