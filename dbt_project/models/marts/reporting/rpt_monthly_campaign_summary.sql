-- /volka_data_pipeline/dbt_project/models/reporting/monthly_campaign_summary.sql
{{
  config(
    materialized='view',
    schema='reporting'
  )
}}

WITH daily_performance AS (
    -- Source from the clean, reliable staging model, not the raw table.
    SELECT * from {{ ref('stg_campaign_performance') }}

),

monthly_aggregated AS (
    SELECT
        -- Use dbt's cross-database macro for date truncation for better portability.
        cast({{ dbt.date_trunc("month", "report_date") }} as date) as report_month,
        campaign_name,
        SUM(spend_eur) AS total_spend,
        SUM(impressions) AS total_impressions,
        SUM(clicks) AS total_clicks,
        SUM(registrations) AS total_registrations,
        
        SUM(revenue_1d_eur) AS total_revenue_1d,
        SUM(revenue_3d_eur) AS total_revenue_3d,
        SUM(revenue_7d_eur) AS total_revenue_7d,
        SUM(revenue_14d_eur) AS total_revenue_14d,
        
        SUM(payers_1d) AS total_payers_1d,
        SUM(payers_3d) AS total_payers_3d,
        SUM(payers_7d) AS total_payers_7d,
        SUM(payers_14d) AS total_payers_14d,

        SUM(players_1d) AS total_players_1d,
        SUM(players_3d) AS total_players_3d,
        SUM(players_7d) AS total_players_7d,
        SUM(players_14d) AS total_players_14d

    FROM daily_performance
    GROUP BY 1, 2
)

SELECT
    -- Dimensions
    report_month,
    campaign_name,
    
    -- Base Metrics for reporting
    total_spend,
    total_impressions,
    total_clicks,
    total_registrations,
    total_payers_14d,
    total_revenue_14d,

    -- Calculated KPIs
    -- ROAS 3 day (Revenue 3 day / Spend)
    -- Calculated as total revenue within 3 days divided by total spend for the month.
    {{ dbt_utils.safe_divide('total_revenue_3d', 'total_spend') }} as roas_3d,

    -- CPI (Cost per registration)
    -- Calculated as total spend divided by total registrations for the month.
    {{ dbt_utils.safe_divide('total_spend', 'total_registrations') }} as cpi,
    
    -- CPP (Cost per payer) N day
    -- Calculated as total spend divided by total payers within N days for the month.
    {{ dbt_utils.safe_divide('total_spend', 'total_payers_1d') }} as cpp_1d,
    {{ dbt_utils.safe_divide('total_spend', 'total_payers_3d') }} as cpp_3d,
    {{ dbt_utils.safe_divide('total_spend', 'total_payers_7d') }} as cpp_7d,
    {{ dbt_utils.safe_divide('total_spend', 'total_payers_14d') }} as cpp_14d,

    -- Retention Rate N day
    {{ dbt_utils.safe_divide('total_players_1d', 'total_registrations') }} as retention_rate_1d,
    {{ dbt_utils.safe_divide('total_players_3d', 'total_registrations') }} as retention_rate_3d,
    {{ dbt_utils.safe_divide('total_players_7d', 'total_registrations') }} as retention_rate_7d,
    {{ dbt_utils.safe_divide('total_players_14d', 'total_registrations') }} as retention_rate_14d
    
FROM monthly_aggregated
ORDER BY report_month, campaign_name