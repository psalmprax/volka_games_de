-- /volka_data_pipeline/sql/queries/october_2024_report_query.sql
-- Query for October 2024 Campaign Summary for Excel Export
-- Assumes the dbt model is materialized as a view in the 'reporting' schema
SELECT
    campaign_name,
    -- Spend: Convert cents to currency unit (e.g., Euros)
    total_spend_cents / 100.0 AS spend_euros,
    total_impressions,
    total_clicks,
    total_registrations,
    total_payers_14d,
    -- Revenue 14d: Convert cents to currency unit
    total_revenue_14d_cents / 100.0 AS revenue_14d_euros
FROM reporting.monthly_campaign_summary -- Or public.monthly_campaign_summary if schema not specified in dbt
WHERE report_month = '2024-10-01' -- dbt model stores report_month as the first day of the month
ORDER BY campaign_name;