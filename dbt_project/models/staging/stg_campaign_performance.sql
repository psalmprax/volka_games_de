-- models/staging/stg_campaign_performance.sql

with source as (
    -- This model must select from the dbt snapshot to get the current, active records.
    select * from {{ ref('scd_campaign_performance') }}
    where dbt_valid_to is null -- This filter selects only the currently active records
),

renamed_and_cleaned as (
    select
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
        players_1d,
        payers_1d,
        payments_1d,
        revenue_1d_cents / 100.0 as revenue_1d_eur,
        players_3d,
        payers_3d,
        payments_3d,
        revenue_3d_cents / 100.0 as revenue_3d_eur,
        players_7d,
        payers_7d,
        payments_7d,
        revenue_7d_cents / 100.0 as revenue_7d_eur,
        players_14d,
        payers_14d,
        payments_14d,
        revenue_14d_cents / 100.0 as revenue_14d_eur
    from source
)

select * from renamed_and_cleaned