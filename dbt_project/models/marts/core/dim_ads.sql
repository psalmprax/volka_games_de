-- models/marts/core/dim_ads.sql
with stg_campaign_performance as (
    select distinct
        campaign_name, -- Include campaign_name if ad_name is only unique within a campaign
        ad_name
    from {{ ref('stg_campaign_performance') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['campaign_name', 'ad_name']) }} as ad_id,
    ad_name,
    {{ dbt_utils.generate_surrogate_key(['campaign_name']) }} as campaign_id -- Foreign key to dim_campaigns
    -- Add other ad-specific attributes if they become available
from stg_campaign_performance
where ad_name is not null -- Ensure we don't create a dimension for null ad names
