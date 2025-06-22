{%- doc -%}
This model generates a comprehensive date dimension table.
It uses `dbt_utils.date_spine` to create a continuous sequence of dates,
ensuring all necessary date attributes are available for analytical queries.

**Grain**: One row per day.

**Purpose**: Provides a robust and reliable source of date-related attributes
for joining with fact tables and enabling time-based analysis.
{%- enddoc -%}

{{ config(materialized='table') }}

with date_spine as (
    {{ dbt_utils.date_spine(
        datepart="day", -- Generate one record per day
        start_date="cast('2020-01-01' as date)", -- Start date for the dimension (e.g., beginning of data collection)
        end_date="current_date + interval '5 year'" -- Extend 5 years into the future for forecasting/planning
       )
    }}
)
select
    date_day as date_key, -- Primary key for the date dimension
    date_day as full_date, -- Full date value
    extract(year from date_day) as year,
    extract(month from date_day) as month,
    extract(day from date_day) as day,
    extract(dow from date_day) as day_of_week, -- Day of week (0=Sunday, 6=Saturday for PostgreSQL)
    extract(doy from date_day) as day_of_year,
    extract(week from date_day) as week_of_year,
    to_char(date_day, 'Month') as month_name,
    to_char(date_day, 'Mon') as month_name_short,
    to_char(date_day, 'Day') as day_name,
    to_char(date_day, 'Dy') as day_name_short,
    extract(quarter from date_day) as quarter, -- Quarter of the year
    -- Flag to identify weekends (Sunday=0, Saturday=6 in PostgreSQL)
    case when extract(dow from date_day) in (0, 6) then true else false end as is_weekend
from date_spine
order by full_date
