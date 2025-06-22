-- models/marts/core/fct_daily_performance.sql
with current_performance_snapshot as (
    select * from {{ ref('scd_campaign_performance') }}
    where dbt_valid_to is null -- Select only the current version of each record
),

dim_campaigns as (
    select * from {{ ref('dim_campaigns') }}
),

dim_ads as (
    select * from {{ ref('dim_ads') }}
),

dim_dates as (
    select * from {{ ref('dim_dates') }}
)

select
    -- Surrogate key for the fact table
    -- Use the snapshot's unique ID for the version of the record
    cps.dbt_scd_id as daily_performance_key, 

    -- Dimension Keys
    dd.date_id,
    dc.campaign_id,
    da.ad_id,

    -- Degenerate Dimensions (attributes from the source that don't fit well in separate dims)
    cps.campaign_name, 
    cps.ad_name,       

    -- Measures
    cps.spend_cents,
    cps.impressions,
    cps.clicks,
    cps.registrations,
    cps.ctr,
    cps.cr,
    cps.cpc_cents,
    cps.players_1d,
    cps.payers_1d,
    cps.payments_1d,
    cps.revenue_1d_cents,
    cps.players_3d,
    cps.payers_3d,
    cps.payments_3d,
    cps.revenue_3d_cents,
    cps.players_7d,
    cps.payers_7d,
    cps.payments_7d,
    cps.revenue_7d_cents,
    cps.players_14d,
    cps.payers_14d,
    cps.payments_14d,
    cps.revenue_14d_cents

from current_performance_snapshot cps
left join dim_dates dd on cps.campaigns_execution_date = dd.date_id -- or dd.full_date
left join dim_campaigns dc on cps.campaign_name = dc.campaign_name
left join dim_ads da on cps.ad_name = da.ad_name
    and dc.campaign_id = da.campaign_id -- Join on campaign_id if ad_name is not globally unique
