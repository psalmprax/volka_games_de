{{ config(
    materialized='view',
    schema='reporting'
) }}

{#
This model provides a granular, daily deep-dive into campaign performance,
calculating a wide range of advanced KPIs.

**Grain**: One row per report_date, per campaign_name, per ad_name.

**Purpose**: To serve as a foundational view for detailed marketing analysis,
allowing analysts to slice and dice performance by any dimension and track
profitability, monetization, and engagement metrics over time.
#}

with source as (
    select * from {{ ref('stg_campaign_performance') }}
),

final_kpis as (
    select
        -- Dimensions for slicing and dicing
        report_date,
        campaign_name,
        ad_name,

        -- Core Metrics
        spend_eur,
        impressions,
        clicks,
        registrations,

        -- Key Lifeday Metrics (using 7-day as an example)
        revenue_7d_eur,
        payers_7d,
        players_7d,
        payments_7d,

        -------------------------------------------
        -- DERIVED KPIS
        -------------------------------------------

        -- Profitability & Efficiency KPIs
        -- KPI 1: 7-Day Return on Ad Spend (ROAS)
        {{ dbt_utils.safe_divide('revenue_7d_eur', 'spend_eur') }} as roas_7d,

        -- KPI 2: 7-Day Cost Per Payer (CPP)
        {{ dbt_utils.safe_divide('spend_eur', 'payers_7d') }} as cpp_7d_eur,

        -- KPI 3: 7-Day Cost Per Player (CPL)
        {{ dbt_utils.safe_divide('spend_eur', 'players_7d') }} as cpl_7d_eur,

        -- Monetization & LTV KPIs
        -- KPI 4: 7-Day Lifetime Value (LTV) Proxy
        {{ dbt_utils.safe_divide('revenue_7d_eur', 'registrations') }} as ltv_7d_eur,

        -- KPI 5: 7-Day Average Revenue Per Payer (ARPPU)
        {{ dbt_utils.safe_divide('revenue_7d_eur', 'payers_7d') }} as arppu_7d_eur,

        -- Engagement & Retention KPIs
        -- KPI 6: 7-Day Player Retention Rate
        {{ dbt_utils.safe_divide('players_7d', 'registrations') }} as retention_rate_7d,

        -- KPI 7: 7-Day Payer Conversion Rate
        {{ dbt_utils.safe_divide('payers_7d', 'registrations') }} as payer_conversion_rate_7d

    from source
)

select * from final_kpis