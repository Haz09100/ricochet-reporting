-- Large-range dashboard performance support.
-- Run once after 010_companion_lead_reporting.sql, preferably during a quiet
-- minute because PostgreSQL briefly locks each table while creating an index.

do $indexes$
begin
  if exists (
    select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where n.nspname='reporting' and c.relname='leads' and c.relkind in ('r','p','m')
  ) then
    execute 'create index if not exists dashboard_leads_activity_date_idx on reporting.leads (lead_date_eastern desc,id desc)';
    execute 'create index if not exists dashboard_leads_created_date_idx on reporting.leads (created_date_eastern desc,id desc)';
    execute 'create index if not exists dashboard_leads_first_live_date_idx on reporting.leads (first_live_date_eastern desc,id desc)';
    execute 'create index if not exists dashboard_leads_phone_key_idx on reporting.leads (phone_key) where phone_key is not null';
    execute 'analyze reporting.leads';
  end if;

  if exists (
    select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where n.nspname='reporting' and c.relname='call_events' and c.relkind in ('r','p','m')
  ) then
    execute 'create index if not exists dashboard_calls_date_idx on reporting.call_events (call_date_eastern desc,id desc)';
    execute 'create index if not exists dashboard_calls_lead_time_idx on reporting.call_events (lead_id,call_timestamp desc,id desc) where lead_id is not null';
    execute 'create index if not exists dashboard_calls_phone_time_idx on reporting.call_events (phone_key,call_timestamp desc,id desc) where phone_key is not null';
    execute 'analyze reporting.call_events';
  end if;

  if exists (
    select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where n.nspname='reporting' and c.relname='note_events' and c.relkind in ('r','p','m')
  ) then
    execute 'create index if not exists dashboard_notes_date_idx on reporting.note_events (note_date_eastern desc,id desc)';
    execute 'create index if not exists dashboard_notes_lead_time_idx on reporting.note_events (lead_row_id,note_date_eastern desc,id desc) where lead_row_id is not null';
    execute 'create index if not exists dashboard_notes_phone_time_idx on reporting.note_events (phone_key,note_date_eastern desc,id desc) where phone_key is not null';
    execute 'analyze reporting.note_events';
  end if;
end
$indexes$;

-- Authenticated Supabase API calls often inherit a short statement limit.
-- These bounded report functions are allowed enough time to finish a larger
-- selected range after the indexes above have reduced their scan work.
alter function public.dashboard_overview(date,date,jsonb) set statement_timeout='50s';
alter function public.dashboard_team(date,date,jsonb) set statement_timeout='50s';
alter function public.dashboard_companion_bonus(date,date,jsonb) set statement_timeout='50s';
alter function public.dashboard_first_response_metrics(date,date,jsonb) set statement_timeout='50s';
alter function public.dashboard_calls(date,date,jsonb,integer,integer) set statement_timeout='50s';
alter function public.dashboard_notes(date,date,jsonb,integer,integer) set statement_timeout='50s';
alter function public.dashboard_leads(date,date,jsonb,integer,integer) set statement_timeout='50s';
alter function public.dashboard_ai_review(date,date,jsonb,integer,integer) set statement_timeout='50s';
alter function public.dashboard_lead_export(date,date,jsonb,jsonb,integer,integer) set statement_timeout='50s';
