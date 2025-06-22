-- /volka_data_pipeline/sql/schema.sql
CREATE TABLE IF NOT EXISTS public.campaign_performance_raw_appends (
    campaigns_execution_date DATE NOT NULL,
    campaign_name VARCHAR(255) NOT NULL,
    ad_name VARCHAR(255) NOT NULL, -- ETL must provide a default if API omits it (e.g., 'N/A')
    spend_cents INTEGER NOT NULL, -- Cost from API, in euro cents
    impressions INTEGER NOT NULL,
    clicks INTEGER NOT NULL,
    registrations INTEGER NOT NULL,
    ctr NUMERIC(18, 10), -- Click-Through Rate
    cr NUMERIC(18, 10),  -- Conversion Rate - from clicks to registrations
    cpc_cents INTEGER,   -- Cost Per Click, in euro cents
    players_1d INTEGER,
    payers_1d INTEGER,
    payments_1d INTEGER,
    revenue_1d_cents BIGINT, -- Revenue for lifeday 1, in euro cents
    players_3d INTEGER,
    payers_3d INTEGER,
    payments_3d INTEGER,
    revenue_3d_cents BIGINT, -- Revenue for lifeday 3, in euro cents
    players_7d INTEGER,
    payers_7d INTEGER,
    payments_7d INTEGER,
    revenue_7d_cents BIGINT, -- Revenue for lifeday 7, in euro cents
    players_14d INTEGER,
    payers_14d INTEGER,
    payments_14d INTEGER,
    revenue_14d_cents BIGINT, -- Revenue for lifeday 14, in euro cents
    _etl_loaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP -- Added to track when the record was loaded
);

-- Index for common query patterns
CREATE INDEX IF NOT EXISTS idx_raw_campaign_perf_date ON public.campaign_performance_raw_appends (campaigns_execution_date);
CREATE INDEX IF NOT EXISTS idx_raw_campaign_perf_campaign_name ON public.campaign_performance_raw_appends (campaign_name);

-- Note on this table: This is an append-only table containing all data pulled from the API.
-- It may contain multiple versions of the same record for a given day.
-- A dbt snapshot is used downstream to create a clean, historized view (SCD Type 2).