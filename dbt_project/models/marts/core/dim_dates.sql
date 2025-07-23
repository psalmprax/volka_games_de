{#
This model generates a comprehensive date dimension table.
It is designed to be cross-database compatible between PostgreSQL and DuckDB.

**Grain**: One row per day.
**Purpose**: To provide a rich set of date attributes for joining with fact tables,
enabling time-based analysis like filtering by month, quarter, or day of the week.
#}

{{ config(materialized='table') }}

-- Generate a spine of dates using dbt's built-in macro.
with date_spine as (
    {{ dbt.date_spine(
        datepart="day",
        start_date="cast('2020-01-01' as date)",
        end_date="cast('2030-12-31' as date)"
    ) }}
)

select
    date_day as date_key,
    extract(year from date_day) as year,
    extract(month from date_day) as month,
    extract(day from date_day) as day,
    extract(dayofweek from date_day) as day_of_week, -- Sunday=0 for both pg/duckdb
    extract(dayofyear from date_day) as day_of_year,
    extract(quarter from date_day) as quarter_of_year,

    -- Use target-specific functions for date formatting to ensure compatibility.
    {% if target.type == 'postgres' %}
    to_char(date_day, 'Month') as month_name,
    to_char(date_day, 'Mon') as month_name_short,
    to_char(date_day, 'Day') as day_name,
    to_char(date_day, 'Dy') as day_name_short
    {% else %} -- Assumes duckdb or other strftime-compatible db
    strftime(date_day, '%B') as month_name,
    strftime(date_day, '%b') as month_name_short,
    strftime(date_day, '%A') as day_name,
    strftime(date_day, '%a') as day_name_short
    {% endif %},

    case when extract(dayofweek from date_day) in (0, 6) then true else false end as is_weekend

from date_spine