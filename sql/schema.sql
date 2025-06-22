/*
File: /sql/schema.sql
Purpose: Defines the schema for the raw data ingestion table in PostgreSQL.
This table serves as the initial landing zone for data extracted from the
external API, designed for append-only inserts.
*/
CREATE TABLE IF NOT EXISTS public.campaign_performance_raw_appends (
    campaigns_execution_date DATE NOT NULL, -- The specific date for which performance metrics are recorded.
    campaign_name VARCHAR(255) NOT NULL,    -- The name of the marketing campaign.
    ad_name VARCHAR(255) NOT NULL,          -- The name of the specific ad. ETL must provide a default if API omits it (e.g., 'N/A').
    spend_cents INTEGER NOT NULL,           -- Total cost of the campaign for the day, in euro cents.
    impressions INTEGER NOT NULL,           -- Total number of times the ad was displayed.
    clicks INTEGER NOT NULL,                -- Total number of clicks on the ad.
    registrations INTEGER NOT NULL,         -- Total number of new user registrations attributed to the ad.
    ctr NUMERIC(18, 10),                    -- Click-Through Rate: (clicks / impressions).
    cr NUMERIC(18, 10),                     -- Conversion Rate: (registrations / clicks).
    cpc_cents INTEGER,                      -- Cost Per Click, in euro cents.
    players_1d INTEGER,                     -- Number of unique users who played within 1 day of registration.
    payers_1d INTEGER,                      -- Number of unique users who made a payment within 1 day of registration.
    payments_1d INTEGER,                    -- Total count of payments within 1 day of registration.
    revenue_1d_cents BIGINT,                -- Total revenue from users within 1 day of registration, in euro cents.
    players_3d INTEGER,                     -- Number of unique users who played within 3 days of registration.
    payers_3d INTEGER,                      -- Number of unique users who made a payment within 3 days of registration.
    payments_3d INTEGER,                    -- Total count of payments within 3 days of registration.
    revenue_3d_cents BIGINT,                -- Total revenue from users within 3 days of registration, in euro cents.
    players_7d INTEGER,                     -- Number of unique users who played within 7 days of registration.
    payers_7d INTEGER,                      -- Number of unique users who made a payment within 7 days of registration.
    payments_7d INTEGER,                    -- Total count of payments within 7 days of registration.
    revenue_7d_cents BIGINT,                -- Total revenue from users within 7 days of registration, in euro cents.
    players_14d INTEGER,                    -- Number of unique users who played within 14 days of registration.
    payers_14d INTEGER,                     -- Number of unique users who made a payment within 14 days of registration.
    payments_14d INTEGER,                   -- Total count of payments within 14 days of registration.
    revenue_14d_cents BIGINT,               -- Total revenue from users within 14 days of registration, in euro cents.
    _etl_loaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP -- Timestamp when the record was loaded into the database.
);

/*
Table Notes:
- This is an append-only table, meaning new records are always inserted,
  and existing records are never updated or deleted.
- It may contain duplicate records or multiple versions of the same logical
  record over time, as it captures all data pulled from the API.
- A dbt snapshot (SCD Type 2) is used downstream to process this raw data
  into a clean, historized view, handling changes and providing a single
  current version of each record.
*/

-- Indexes to optimize queries filtering or ordering by date and campaign name.
CREATE INDEX IF NOT EXISTS idx_raw_campaign_perf_date ON public.campaign_performance_raw_appends (campaigns_execution_date);
CREATE INDEX IF NOT EXISTS idx_raw_campaign_perf_campaign_name ON public.campaign_performance_raw_appends (campaign_name);