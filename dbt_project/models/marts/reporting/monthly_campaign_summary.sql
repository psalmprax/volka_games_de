-- models/marts/reporting/monthly_campaign_summary.sql

{{ config(
    materialized='view'
) }}

with daily_data as (
    select * from {{ ref('stg_campaign_performance') }}
),

monthly_agg as (
    select
        date_trunc('month', report_date)::date as report_month,
        campaign_name,

        -- Aggregate base metrics by summing up daily values
        sum(spend_eur) as total_spend,
        sum(impressions) as total_impressions,
        sum(clicks) as total_clicks,
        sum(registrations) as total_registrations,

        -- Aggregate lifeday metrics for all required time windows
        sum(revenue_3d_eur) as total_revenue_3d,
        sum(payers_3d) as total_payers_3d,
        sum(players_3d) as total_players_3d,

        sum(revenue_7d_eur) as total_revenue_7d,
        sum(payers_7d) as total_payers_7d,
        sum(players_7d) as total_players_7d,

        sum(revenue_14d_eur) as total_revenue_14d,
        sum(players_14d) as total_players_14d,
        sum(payers_14d) as total_payers_14d

    from daily_data
    group by 1, 2
),

final_view as (
    select
        -- Dimensions
        report_month,
        campaign_name,

        -- Base Metrics for Excel Report
        total_spend,
        total_impressions,
        total_clicks,
        total_registrations,
        total_payers_14d,
        total_revenue_14d,

        -- Required KPIs for the View
        total_revenue_3d / nullif(total_spend, 0) as roas_3d,
        total_spend / nullif(total_registrations, 0) as cpi, -- Cost Per Install/Registration
        total_spend / nullif(total_payers_14d, 0) as cpp_14d, -- Cost Per Payer 14d
        total_players_14d / nullif(total_registrations, 0) as retention_rate_14d

    from monthly_agg
)

select * from final_view