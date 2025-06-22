-- models/marts/core/dim_campaigns.sql
with stg_campaign_performance as (
    select distinct campaign_name
    from {{ ref('stg_campaign_performance') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['campaign_name']) }} as campaign_id,
    campaign_name
    -- Add other campaign-specific attributes if they become available
from stg_campaign_performance
where campaign_name is not null -- Ensure we don't create a dimension for null campaign names
