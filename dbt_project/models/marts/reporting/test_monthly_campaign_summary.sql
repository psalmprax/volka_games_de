-- /volka_data_pipeline/dbt_project/models/reporting/monthly_campaign_summary.sql
{{
  config(
    materialized='view'
  )
}}

WITH daily_performance AS (
    SELECT * FROM {{ source('public', 'campaign_performance_raw_appends') }}
    -- SELECT * from {{ ref('stg_campaign_performance') }}

),

monthly_aggregated AS (
    SELECT
        DATE_TRUNC('month', campaigns_execution_date)::DATE AS report_month,
        campaign_name,
        SUM(spend_cents) AS total_spend_cents,
        SUM(impressions) AS total_impressions,
        SUM(clicks) AS total_clicks,
        SUM(registrations) AS total_registrations,
        
        SUM(revenue_1d_cents) AS total_revenue_1d_cents,
        SUM(revenue_3d_cents) AS total_revenue_3d_cents,
        SUM(revenue_7d_cents) AS total_revenue_7d_cents,
        SUM(revenue_14d_cents) AS total_revenue_14d_cents,
        
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
    report_month,
    campaign_name,
    
    total_spend_cents,
    total_impressions,
    total_clicks,
    total_registrations,
    total_payers_14d,
    total_revenue_14d_cents,

    -- ROAS 3 day (Revenue 3 day / Spend)
    -- Calculated as total revenue within 3 days divided by total spend for the month.
    CASE
        WHEN total_spend_cents > 0 THEN (total_revenue_3d_cents * 1.0 / total_spend_cents)
        ELSE 0
    END AS roas_3d,

    -- CPI (Cost per registration) in cents
    -- Calculated as total spend divided by total registrations for the month.
    CASE
        WHEN total_registrations > 0 THEN (total_spend_cents * 1.0 / total_registrations)
        ELSE 0
    END AS cpi_cents,
    
    -- CPP (Cost per payer) N day in cents
    -- Calculated as total spend divided by total payers within N days for the month.
    CASE
        WHEN total_payers_1d > 0 THEN (total_spend_cents * 1.0 / total_payers_1d)
        ELSE 0 
    END AS cpp_1d_cents,
    CASE
        WHEN total_payers_3d > 0 THEN (total_spend_cents * 1.0 / total_payers_3d)
        ELSE 0
    END AS cpp_3d_cents,
    CASE
        WHEN total_payers_7d > 0 THEN (total_spend_cents * 1.0 / total_payers_7d)
        ELSE 0
    END AS cpp_7d_cents,
    CASE
        WHEN total_payers_14d > 0 THEN (total_spend_cents * 1.0 / total_payers_14d)
        ELSE 0
    END AS cpp_14d_cents,

    CASE
        WHEN total_registrations > 0 THEN (total_players_1d * 1.0 / total_registrations)
        ELSE 0
    END AS retention_rate_1d,
    CASE
        WHEN total_registrations > 0 THEN (total_players_3d * 1.0 / total_registrations)
        ELSE 0
    END AS retention_rate_3d,
    CASE
        WHEN total_registrations > 0 THEN (total_players_7d * 1.0 / total_registrations)
        ELSE 0
    END AS retention_rate_7d,
    CASE
        WHEN total_registrations > 0 THEN (total_players_14d * 1.0 / total_registrations)
        ELSE 0
    END AS retention_rate_14d
    
FROM monthly_aggregated
ORDER BY report_month, campaign_name