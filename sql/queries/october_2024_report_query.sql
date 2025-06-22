/*
File: /sql/queries/october_2024_report_query.sql
Purpose: Generates the monthly marketing campaign summary for October 2024.
Usage: This query is intended for analysts to export data for business reporting (e.g., to Excel).
       It selects the key performance indicators from the final dbt reporting model for a specific month.

Dependencies:
- It queries the `monthly_campaign_summary` view, which is expected to be in the `public_reporting` schema
  as per the project's data modeling conventions. If your dbt profile targets a different
  schema.
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
    -- The report_month column in the dbt model stores the first day of the month.
    report_month = '2024-10-01'
ORDER BY
    campaign_name;