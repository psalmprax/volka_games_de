{%- doc -%}
This model creates a dimension table for marketing campaigns.

**Grain**: One row per unique campaign name.

**Purpose**: Provides a centralized, unique list of campaigns that can be joined
with fact tables for filtering and grouping. It assigns a stable surrogate key
to each campaign.
{%- enddoc -%}

with distinct_campaigns as (

    -- Select unique campaign names from the staging performance data.
    -- This ensures the dimension only contains campaigns that have appeared in the source data.
    select distinct campaign_name
    from {{ ref('stg_campaign_performance') }}
    where campaign_name is not null -- Exclude any null or empty campaign names

)

select
    -- Generate a surrogate key to serve as the primary key for the dimension.
    {{ dbt_utils.generate_surrogate_key(['campaign_name']) }} as campaign_key,

    -- The natural key of the dimension.
    campaign_name

    -- Placeholder for future campaign-specific attributes (e.g., campaign start date, budget, channel).
    -- These could be added from other source systems or seed files.

from distinct_campaigns
