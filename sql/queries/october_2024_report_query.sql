/*
Purpose: Generates the monthly marketing campaign summary for October 2024 for an Excel report.
Usage: This query is intended for analysts to run against the data warehouse to export data.
       It selects key performance indicators from the final dbt reporting model for a specific month.
Note: This query assumes the final model is in the `public_reporting` schema.
      This may need to be adjusted based on your dbt profile's target schema.
*/
SELECT
    report_month,
    campaign_name,
    total_spend,
    total_impressions,
    total_clicks,
    total_registrations,
    total_payers_14d,
    total_revenue_14d
FROM
    public_reporting.monthly_campaign_summary
WHERE
    -- Filter for the specific month required for the report.
    -- The report_month column stores the first day of the month (e.g., '2024-10-01').
    report_month = '2024-10-01'
ORDER BY
    campaign_name;