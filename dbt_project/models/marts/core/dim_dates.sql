-- models/marts/core/dim_dates.sql

-- Option 1: Using dbt_utils.date_spine (Recommended for production)
-- Ensure dbt_utils is in your packages.yml and you've run dbt deps
{{ config(materialized='table') }}

with date_spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2020-01-01' as date)",
        end_date="current_date + interval '5 year'"
       )
    }}
)
select
    date_day as date_id, -- Or keep as date_day
    date_day as full_date,
    extract(year from date_day) as year,
    extract(month from date_day) as month,
    extract(day from date_day) as day,
    extract(dow from date_day) as day_of_week, -- PostgreSQL DOW (0=Sunday, 6=Saturday)
    extract(doy from date_day) as day_of_year,
    extract(week from date_day) as week_of_year,
    to_char(date_day, 'Month') as month_name,
    to_char(date_day, 'Mon') as month_name_short,
    to_char(date_day, 'Day') as day_name,
    to_char(date_day, 'Dy') as day_name_short,
    extract(quarter from date_day) as quarter,
    -- For PostgreSQL, DOW is 0 for Sunday, 6 for Saturday
    case when extract(dow from date_day) in (0, 6) then true else false end as is_weekend
from date_spine
order by full_date

-- {# -- Option 2: Basic CTE based approach (Simpler, less feature-rich)
-- -- This requires your source data to have a good range of dates.
-- -- For a more robust solution, use dbt_utils.date_spine (Option 1) or a seed file.
-- with all_dates as (
--     select distinct execution_date as full_date
--     from {{ ref('stg_campaign_performance') }}
-- )
-- select
--     full_date as date_id,
--     full_date,
--     -- extract(year from full_date) as year,
--     -- extract(month from full_date) as month,
--     -- extract(day from full_date) as day,
--     DATE_PART('year', full_date) as year,
--     DATE_PART('month', full_date) as month,
--     DATE_PART('day', full_date) as day,
--     extract(dow from full_date) as day_of_week, -- Sunday=0, Saturday=6 for PostgreSQL
--     to_char(full_date, 'YYYY-MM') as year_month,
--     to_char(full_date, 'Month') as month_name,
--     to_char(full_date, 'Mon') as month_name_short,
--     to_char(full_date, 'Day') as day_name,
--     to_char(full_date, 'Dy') as day_name_short,
--     extract(quarter from full_date) as quarter_of_year,
--     case when extract(dow from full_date) in (0, 6) then true else false end as is_weekend
-- from all_dates
-- order by full_date #}
