{#
This model creates a daily performance fact table, providing a central place for analytics.

**Grain**: One row per campaign, per ad, per day, representing the most current performance data.

**Sources**:
- `stg_campaign_performance`: The primary source of performance metrics.
- `dim_dates`, `dim_campaigns`, `dim_ads`: Dimension tables to provide context.

**Key Logic**:
- Builds on the cleaned `stg_campaign_performance` model, which provides current data with correct data types.
- Joins to dimension tables to get surrogate keys for robust dimensional analysis.
- Includes key performance metrics and lifeday cohort data in standard currency units (EUR).
 #}

with performance as (
    -- Use the staging model which provides cleaned, correctly-typed, and current data
    select * from {{ ref('stg_campaign_performance') }}
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
    -- Surrogate key for the fact table, inherited from the staging layer
    performance.campaign_performance_sk as daily_performance_sk,

    -- Dimension Foreign Keys
    -- These keys link our performance facts to the dimensional context.
    dim_dates.date_key,
    dim_campaigns.campaign_key,
    dim_ads.ad_key,

    -- Degenerate Dimensions: useful attributes that don't warrant a full dimension
    -- and can simplify querying in BI tools.
    performance.campaign_name,
    performance.ad_name,

    -- Core Performance Measures (in EUR)
    performance.spend_eur,
    performance.impressions,
    performance.clicks,
    performance.registrations,
    performance.cpc_eur,
    performance.ctr,
    performance.cr,

    -- Lifeday Metrics (in EUR)
    performance.players_1d,
    performance.payers_1d,
    performance.payments_1d,
    performance.revenue_1d_eur,
    performance.players_3d,
    performance.payers_3d,
    performance.payments_3d,
    performance.revenue_3d_eur,
    performance.players_7d,
    performance.payers_7d,
    performance.payments_7d,
    performance.revenue_7d_eur,
    performance.players_14d,
    performance.payers_14d,
    performance.payments_14d,
    performance.revenue_14d_eur,

    -- Metadata for data lineage and debugging
    performance.valid_from_timestamp,
    performance.updated_at_timestamp

from performance
left join dim_dates on performance.report_date = dim_dates.date_key -- Join on the date column, which serves as the key in this dimension.
left join dim_campaigns on performance.campaign_name = dim_campaigns.campaign_name
-- Join on natural keys to get the ad dimension's surrogate key. This is more performant
-- than regenerating the key on the fly for every row in the fact table.
left join dim_ads on performance.campaign_name = dim_ads.campaign_name and performance.ad_name = dim_ads.ad_name
