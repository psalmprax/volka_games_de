{% snapshot scd_campaign_performance %}

{{
    config(
      target_schema='snapshots',
      unique_key="campaigns_execution_date || '-' || campaign_name || '-' || ad_name",
      strategy='check',
      check_cols=[
        'spend_cents', 'impressions', 'clicks', 'registrations', 'ctr', 'cr', 'cpc_cents',
        'players_1d', 'payers_1d', 'payments_1d', 'revenue_1d_cents',
        'players_3d', 'payers_3d', 'payments_3d', 'revenue_3d_cents',
        'players_7d', 'payers_7d', 'payments_7d', 'revenue_7d_cents',
        'players_14d', 'payers_14d', 'payments_14d', 'revenue_14d_cents'
      ],
      invalidate_hard_deletes=True
    )
}}

-- Selects the raw data that will be snapshotted
select * from {{ source('raw_data', 'campaign_performance_raw_appends') }}

{% endsnapshot %}