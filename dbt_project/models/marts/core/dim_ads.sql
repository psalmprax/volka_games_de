/*
This model creates a dimension table for ads, containing a unique record for each ad name.
It helps in analyzing performance per ad.
*/

with ad_source as (

    -- Select unique combinations of campaign and ad names from the staging data.
    select distinct
        campaign_name,
        ad_name
    from {{ ref('stg_campaign_performance') }}
    where ad_name is not null and ad_name != 'N/A' -- Exclude null or default ad names

),

campaigns as (

    -- Get the surrogate key from the campaigns dimension to build the foreign key relationship.
    select
        campaign_key,
        campaign_name
    from {{ ref('dim_campaigns') }}

)

select
    -- Generate a surrogate key for the ad, ensuring uniqueness by including the campaign name.
    {{ dbt_utils.generate_surrogate_key(['ad_source.campaign_name', 'ad_source.ad_name']) }} as ad_key,
    -- Foreign key to link back to the campaign dimension.
    campaigns.campaign_key as campaign_fk,
    -- Natural key of the dimension.
    ad_source.ad_name
    -- Placeholder for future ad-specific attributes (e.g., ad type, creative format).
from ad_source
left join campaigns on ad_source.campaign_name = campaigns.campaign_name
