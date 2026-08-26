-- Ricochet GitHub dashboard API
-- Run once in the Supabase SQL Editor after the existing reporting/AI sync tables exist.
-- Coexistence-safe installation: this file adds the new dashboard API without changing
-- any existing grants on the synchronized reporting or AI schemas. Run the optional
-- lockdown migration only after the old dashboard is retired and the new site is verified.

begin;

create schema if not exists report_api;
revoke all on schema report_api from public, anon, authenticated;

create table if not exists public.report_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'viewer' check (role in ('viewer', 'manager', 'admin')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.report_users enable row level security;
revoke all on table public.report_users from public, anon, authenticated;
grant select on table public.report_users to authenticated;

do $policy$
begin
  if not exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'report_users'
      and policyname = 'report users can read their own access'
  ) then
    create policy "report users can read their own access"
      on public.report_users for select to authenticated
      using ((select auth.uid()) = user_id and active is true);
  end if;
end
$policy$;

create or replace function report_api.assert_access()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.report_users u
    where u.user_id = (select auth.uid()) and u.active is true
  ) then
    raise exception 'This user is not authorized for Ricochet reporting.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.dashboard_authorized()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform report_api.assert_access();
  return true;
end;
$$;

create or replace function report_api.validate_range(p_from date, p_to date)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'A valid From and To date is required.' using errcode = '22023';
  end if;
  if p_to - p_from > 370 then
    raise exception 'Dashboard date ranges are limited to 370 days.' using errcode = '22023';
  end if;
end;
$$;

create or replace function report_api.normalize_phone(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when length(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')) = 11
      and regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g') like '1%'
      then substr(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g'), 2)
    else regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')
  end
$$;

create or replace function report_api.appointment_type(p_lead reporting.leads)
returns text
language sql
stable
set search_path = ''
as $$
  with source as (
    select lower(coalesce(nullif(trim(p_lead.note), ''), nullif(trim(p_lead.all_notes), ''), '')) value
  )
  select case
    when value not like '%appointment type%' then 'Not provided'
    when value like '%appointment type%in person%' or value like '%appointment type%in-person%'
      or value like '%appointment type%face to face%' or value like '%appointment type%onsite%' then 'In person'
    when value like '%appointment type%phone call%' or value like '%appointment type%telephone%'
      or value like '%appointment type%phone appointment%' then 'Phone call'
    when value like '%appointment type%virtual%' or value like '%appointment type%zoom%'
      or value like '%appointment type%video call%' or value like '%appointment type%google meet%' then 'Virtual'
    else 'Other / unclear'
  end from source
$$;

create or replace function report_api.lead_matches(p_lead reporting.leads, p_filters jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select
    (nullif(trim(coalesce(p_filters->>'status', '')), '') is null
      or p_lead.lead_status = p_filters->>'status')
    and (nullif(trim(coalesce(p_filters->>'agent', '')), '') is null
      or lower(trim(coalesce(p_lead.user_id, ''))) = lower(trim(p_filters->>'agent'))
      or lower(trim(coalesce(p_lead.user_name, ''))) = lower(trim(p_filters->>'agent')))
    and (nullif(trim(coalesce(p_filters->>'vendor', '')), '') is null
      or lower(trim(coalesce(p_lead.vendor, ''))) = lower(trim(p_filters->>'vendor')))
    and (nullif(trim(coalesce(p_filters->>'lead_type', '')), '') is null
      or p_lead.lead_type = p_filters->>'lead_type')
    and (nullif(trim(coalesce(p_filters->>'state', '')), '') is null
      or upper(trim(coalesce(p_lead.property_state, ''))) = upper(trim(p_filters->>'state')))
    and (nullif(trim(coalesce(p_filters->>'city', '')), '') is null
      or lower(trim(coalesce(p_lead.city, ''))) = lower(trim(p_filters->>'city')))
    and (nullif(trim(coalesce(p_filters->>'appointment_type', '')), '') is null
      or report_api.appointment_type(p_lead) = p_filters->>'appointment_type')
    and (nullif(trim(coalesce(p_filters->>'source_description', '')), '') is null
      or lower(trim(coalesce(p_lead.source_lead_description, ''))) = lower(trim(p_filters->>'source_description')))
    and (coalesce(p_filters->>'email_status', '') <> 'sent' or p_lead.live_email_sent is true)
    and (coalesce(p_filters->>'email_status', '') <> 'not_sent' or coalesce(p_lead.live_email_sent, false) is false)
    and (
      nullif(trim(coalesce(p_filters->>'address_quality', '')), '') is null
      or (p_filters->>'address_quality' = 'missing_city_or_zip' and
        (nullif(trim(coalesce(p_lead.city,'')), '') is null or coalesce(p_lead.property_zip,'') !~ '^[0-9]{5}'))
      or (p_filters->>'address_quality' = 'missing_city' and nullif(trim(coalesce(p_lead.city,'')), '') is null)
      or (p_filters->>'address_quality' = 'missing_zip' and coalesce(p_lead.property_zip,'') !~ '^[0-9]{5}')
      or (p_filters->>'address_quality' = 'complete' and nullif(trim(coalesce(p_lead.city,'')), '') is not null
        and coalesce(p_lead.property_zip,'') ~ '^[0-9]{5}')
    )
    and (
      nullif(trim(coalesce(p_filters->>'search', '')), '') is null
      or lower(concat_ws(' ', p_lead.first_name, p_lead.last_name)) like '%' || lower(trim(p_filters->>'search')) || '%'
      or lower(coalesce(p_lead.email, '')) like '%' || lower(trim(p_filters->>'search')) || '%'
      or (report_api.normalize_phone(p_filters->>'search') <> ''
        and report_api.normalize_phone(p_lead.phone) like '%' || report_api.normalize_phone(p_filters->>'search') || '%')
      or p_lead.id::text = trim(p_filters->>'search')
      or lower(coalesce(p_lead.fub_id::text, '')) = lower(trim(p_filters->>'search'))
    )
$$;

create or replace function report_api.has_lead_filters(p_filters jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1 from jsonb_each_text(coalesce(p_filters, '{}'::jsonb)) f
    where f.key in ('status','agent','vendor','lead_type','state','city','appointment_type',
      'source_description','address_quality','email_status','search')
      and nullif(trim(coalesce(f.value, '')), '') is not null
  )
$$;

create or replace function public.dashboard_filter_options(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with leads as materialized (
    select l.lead_status,l.user_id,l.user_name,l.vendor,l.lead_type,l.property_state,l.city,l.source_lead_description
    from reporting.leads l
    where l.lead_date_eastern between p_from and p_to
       or l.created_date_eastern between p_from and p_to
  )
  select jsonb_build_object(
    'statuses', coalesce((select jsonb_agg(v order by v) from (select distinct trim(lead_status) v from leads where nullif(trim(lead_status),'') is not null) s), '[]'::jsonb),
    'agents', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'label', label) order by label) from (
      select distinct coalesce(nullif(trim(user_id),''), trim(user_name)) value, coalesce(nullif(trim(user_name),''), trim(user_id)) label
      from leads where nullif(trim(coalesce(user_id,user_name,'')),'') is not null
    ) a), '[]'::jsonb),
    'vendors', coalesce((select jsonb_agg(v order by v) from (select distinct trim(vendor) v from leads where nullif(trim(vendor),'') is not null) s), '[]'::jsonb),
    'lead_types', coalesce((select jsonb_agg(v order by v) from (select distinct trim(lead_type) v from leads where nullif(trim(lead_type),'') is not null) s), '[]'::jsonb),
    'source_descriptions', coalesce((select jsonb_agg(v order by v) from (select distinct trim(source_lead_description) v from leads where nullif(trim(source_lead_description),'') is not null order by v limit 1000) s), '[]'::jsonb),
    'states', coalesce((select jsonb_agg(v order by v) from (select distinct upper(trim(property_state)) v from leads where nullif(trim(property_state),'') is not null) s), '[]'::jsonb),
    'cities', coalesce((select jsonb_agg(v order by v) from (select distinct trim(city) v from leads where nullif(trim(city),'') is not null order by v limit 1000) s), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_overview(p_from date, p_to date, p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with all_filtered as materialized (
    select l.id,l.phone_key,l.lead_status,l.created_date_eastern,l.lead_date_eastern,
      l.first_live_date_eastern,l.live_email_sent
    from reporting.leads l where report_api.lead_matches(l, p_filters)
  ), selected as materialized (
    select l.* from all_filtered l
    where case when coalesce(p_filters->>'date_basis','activity') = 'created'
      then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
  ), received as materialized (
    select l.* from all_filtered l where l.created_date_eastern between p_from and p_to
  ), calls as materialized (
    select c.lead_id,c.phone_key,c.duration_seconds,c.ai_analysis_status,c.ai_agent_score,
      c.ai_status_matches,c.ai_note_matches
    from reporting.call_events c
    where c.call_date_eastern between p_from and p_to
      and (
        coalesce(nullif(trim(c.call_type_id), ''), '0') not in ('7','10')
        or lower(trim(coalesce(c.recording_status,''))) in ('available','stored','completed')
        or nullif(trim(coalesce(c.recording_storage_key,'')),'') is not null
        or nullif(trim(coalesce(c.recording_url,'')),'') is not null
        or nullif(trim(coalesce(c.ai_transcript_original,'')),'') is not null
      )
      and (
        not v_has_filters
        or (c.lead_id is not null and c.lead_id in (select l.id from all_filtered l))
        or (c.lead_id is null and c.phone_key in (select l.phone_key from all_filtered l where l.phone_key is not null))
      )
  ), notes as materialized (
    select n.lead_row_id,n.phone_key
    from reporting.note_events n
    where n.note_date_eastern between p_from and p_to and n.is_new_append is true
      and (
        not v_has_filters
        or (n.lead_row_id is not null and n.lead_row_id in (select l.id from all_filtered l))
        or (n.lead_row_id is null and n.phone_key in (select l.phone_key from all_filtered l where l.phone_key is not null))
      )
  ), worked as (
    select c.lead_id id from calls c where c.lead_id is not null
    union
    select s.id from selected s join calls c on c.lead_id is null and c.phone_key = s.phone_key
    union
    select n.lead_row_id id from notes n where n.lead_row_id is not null
    union
    select s.id from selected s join notes n on n.lead_row_id is null and n.phone_key = s.phone_key
  ), totals as (
    select
      (select count(*) from received)::bigint leads_received,
      (select count(*) from selected)::bigint activity_cohort,
      (select count(*) from worked)::bigint worked_leads,
      (select count(*) from all_filtered l where
        (lower(trim(coalesce(l.lead_status,''))) like '%live%' or lower(trim(coalesce(l.lead_status,''))) like '%appointment%')
        and l.live_email_sent is true and l.first_live_date_eastern between p_from and p_to)::bigint live_leads_sent,
      (select count(*) from calls)::bigint calls_logged,
      (select count(distinct coalesce(c.lead_id::text, 'phone:' || c.phone_key)) from calls c)::bigint unique_called_leads,
      (select count(*) from selected s where trim(coalesce(s.lead_status,'')) like '2.%')::bigint contacted_leads,
      (select count(*) from calls c where coalesce(c.duration_seconds,0) >= 6)::bigint handled_calls,
      (select count(*) from notes)::bigint notes_added,
      (select count(distinct coalesce(n.lead_row_id::text, 'phone:' || n.phone_key)) from notes n)::bigint leads_with_notes,
      (select count(*) from calls c where lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed')::bigint ai_reviewed,
      (select round(avg(c.ai_agent_score)::numeric,1) from calls c where lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed') average_ai_score,
      (select count(*) from calls c where lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed'
        and (coalesce(c.ai_status_matches,true) is false or coalesce(c.ai_note_matches,true) is false))::bigint needs_attention
  ), status_rows as (
    select coalesce(nullif(trim(s.lead_status),''),'Unknown') status, count(*)::bigint count
    from selected s group by 1 order by count desc, status
  ), daily_rows as (
    select (case when coalesce(p_filters->>'date_basis','activity') = 'created' then s.created_date_eastern else s.lead_date_eastern end) report_date,
      count(*)::bigint leads
    from selected s group by 1 order by 1
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'leads_received', t.leads_received,
      'activity_cohort', t.activity_cohort,
      'worked_leads', t.worked_leads,
      'live_leads_sent', t.live_leads_sent,
      'live_emails_sent', t.live_leads_sent,
      'calls_logged', t.calls_logged,
      'unique_called_leads', t.unique_called_leads,
      'contacted_leads', t.contacted_leads,
      'handled_calls', t.handled_calls,
      'notes_added', t.notes_added,
      'leads_with_notes', t.leads_with_notes,
      'ai_reviewed', t.ai_reviewed,
      'average_ai_score', t.average_ai_score,
      'needs_attention', t.needs_attention,
      'contact_rate', case when t.activity_cohort > 0 then round(t.contacted_leads::numeric * 100 / t.activity_cohort, 1) else 0 end
    ),
    'status_breakdown', coalesce((select jsonb_agg(to_jsonb(s)) from status_rows s), '[]'::jsonb),
    'daily_trend', coalesce((select jsonb_agg(to_jsonb(d)) from daily_rows d), '[]'::jsonb),
    'generated_at', now()
  ) into v_result from totals t;
  return v_result;
end;
$$;

create or replace function public.dashboard_team(p_from date, p_to date, p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with filtered_leads as materialized (
    select l.id,l.phone_key from reporting.leads l where report_api.lead_matches(l, p_filters)
  ), base as materialized (
    select c.lead_id,c.phone_key,c.user_id,c.user_name,c.duration_seconds,c.call_datetime_text,
      coalesce(nullif(trim(c.user_id),''), 'name:' || lower(nullif(trim(c.user_name),'')), 'unknown') caller_key
    from reporting.call_events c
    where c.call_date_eastern between p_from and p_to
      and (
        coalesce(nullif(trim(c.call_type_id), ''), '0') not in ('7','10')
        or lower(trim(coalesce(c.recording_status,''))) in ('available','stored','completed')
        or nullif(trim(coalesce(c.recording_storage_key,'')),'') is not null
        or nullif(trim(coalesce(c.recording_url,'')),'') is not null
        or nullif(trim(coalesce(c.ai_transcript_original,'')),'') is not null
      )
      and (
        not v_has_filters
        or (c.lead_id is not null and c.lead_id in (select l.id from filtered_leads l))
        or (c.lead_id is null and c.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null))
      )
  ), agent_stats as (
    select caller_key, coalesce(max(nullif(trim(user_name),'')),'Unknown') user_name,
      coalesce(max(nullif(trim(user_id),'')),'') user_id,
      count(*)::bigint calls,
      count(distinct coalesce(lead_id::text,'phone:'||phone_key))::bigint unique_leads,
      count(*) filter (where coalesce(duration_seconds,0) >= 6)::bigint handled_calls,
      coalesce(sum(duration_seconds),0)::bigint duration_seconds,
      round(avg(nullif(duration_seconds,0))::numeric,1) average_duration_seconds,
      min(call_datetime_text) first_call, max(call_datetime_text) last_call
    from base group by caller_key
  ), maximums as (
    select greatest(max(calls),1) max_calls, greatest(max(unique_leads),1) max_leads from agent_stats
  ), scored as (
    select a.*,
      round(least(100,
        30 * a.calls::numeric/m.max_calls +
        20 * a.unique_leads::numeric/m.max_leads +
        20 * a.handled_calls::numeric/greatest(a.calls,1) +
        15 * least(coalesce(a.average_duration_seconds,0),300)/300 +
        15 * least(a.unique_leads::numeric/greatest(a.calls,1),1)
      ))::integer score
    from agent_stats a cross join maximums m
  ), note_authors as (
    select coalesce(nullif(trim(n.note_user_name),''),nullif(trim(n.note_user_email),''),'Unknown') author,
      count(*)::bigint notes,
      count(distinct coalesce(n.lead_row_id::text,'phone:'||n.phone_key))::bigint unique_leads,
      min(coalesce(n.note_created_at_utc,n.detected_at_utc)) first_note,
      max(coalesce(n.note_created_at_utc,n.detected_at_utc)) last_note
    from reporting.note_events n
    where n.note_date_eastern between p_from and p_to and n.is_new_append is true
      and (
        not v_has_filters
        or (n.lead_row_id is not null and n.lead_row_id in (select l.id from filtered_leads l))
        or (n.lead_row_id is null and n.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null))
      )
    group by 1 order by notes desc
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'calls', coalesce((select count(*) from base),0),
      'agents', coalesce((select count(*) from agent_stats),0),
      'unique_leads', coalesce((select count(distinct coalesce(lead_id::text,'phone:'||phone_key)) from base),0),
      'duration_seconds', coalesce((select sum(duration_seconds) from base),0)
    ),
    'agents', coalesce((select jsonb_agg(to_jsonb(s) order by s.score desc, s.calls desc, s.user_name) from scored s), '[]'::jsonb),
    'note_authors', coalesce((select jsonb_agg(to_jsonb(n) order by n.notes desc, n.author) from note_authors n), '[]'::jsonb),
    'generated_at', now()
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_leads(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),200); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with selected as materialized (
    select l.* from reporting.leads l
    where report_api.lead_matches(l,p_filters)
      and case when coalesce(p_filters->>'date_basis','activity')='created' then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
  ), page_rows as (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.lead_status,l.lead_type,l.vendor,l.user_name,l.user_id,
      l.city,l.property_state,l.property_zip,l.lead_date_eastern lead_date,l.created_date_eastern created_date,
      l.first_live_date_eastern first_live_date,l.live_email_sent,l.fub_id
    from selected l order by l.lead_date_eastern desc nulls last,l.id desc
    limit v_size offset (v_page-1)*v_size
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_calls(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),200); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with filtered_leads as materialized (
    select l.id,l.phone_key from reporting.leads l where report_api.lead_matches(l,p_filters)
  ), selected as materialized (
    select c.id,c.call_timestamp from reporting.call_events c
    where c.call_date_eastern between p_from and p_to
      and (
        coalesce(nullif(trim(c.call_type_id), ''), '0') not in ('7','10')
        or lower(trim(coalesce(c.recording_status,''))) in ('available','stored','completed')
        or nullif(trim(coalesce(c.recording_storage_key,'')),'') is not null
        or nullif(trim(coalesce(c.recording_url,'')),'') is not null
        or nullif(trim(coalesce(c.ai_transcript_original,'')),'') is not null
      )
      and (
        not v_has_filters
        or (c.lead_id is not null and c.lead_id in (select l.id from filtered_leads l))
        or (c.lead_id is null and c.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null))
      )
      and (coalesce(p_filters->>'ai_review','') <> 'completed'
        or lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed')
      and (coalesce(p_filters->>'ai_review','') <> 'needs_review'
        or (lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed'
          and (coalesce(c.ai_status_matches,true) is false or coalesce(c.ai_note_matches,true) is false)))
      and (coalesce(p_filters->>'ai_review','') <> 'not_reviewed'
        or lower(trim(coalesce(c.ai_analysis_status,''))) <> 'completed')
      and (coalesce(p_filters->>'recording','') <> 'available'
        or nullif(trim(coalesce(c.call_uuid,'')),'') is not null)
      and (coalesce(p_filters->>'recording','') <> 'missing'
        or nullif(trim(coalesce(c.call_uuid,'')),'') is null)
  ), page_ids as (
    select c.id from selected c order by c.call_timestamp desc nulls last,c.id desc limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select c.id,coalesce(ld.first_name,lp.first_name,c.first_name) first_name,
      coalesce(ld.last_name,lp.last_name,c.last_name) last_name,c.phone,c.phone_key,
      c.user_name,c.user_id,c.call_datetime_text call_date_time,c.call_date_eastern call_date,
      c.duration_seconds,c.call_status,c.call_type_id,
      case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
      coalesce(ld.lead_status,lp.lead_status) lead_status,coalesce(ld.lead_type,lp.lead_type,c.lead_type) lead_type,
      coalesce(ld.vendor,lp.vendor) vendor,c.call_uuid,c.recording_status,c.recording_url,
      c.ai_analysis_status,c.ai_agent_score,c.ai_summary,c.ai_status_matches,c.ai_note_matches
    from page_ids p join reporting.call_events c on c.id=p.id
    left join reporting.leads ld on ld.id=c.lead_id
    left join lateral (select l.* from reporting.leads l where c.lead_id is null and l.phone_key=c.phone_key order by l.id desc limit 1) lp on true
    order by c.call_timestamp desc nulls last,c.id desc
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_notes(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),100); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with filtered_leads as materialized (
    select l.id,l.phone_key from reporting.leads l where report_api.lead_matches(l,p_filters)
  ), selected as materialized (
    select n.id,n.note_created_at_utc from reporting.note_events n
    where n.note_date_eastern between p_from and p_to and n.is_new_append is true
      and (
        not v_has_filters
        or (n.lead_row_id is not null and n.lead_row_id in (select l.id from filtered_leads l))
        or (n.lead_row_id is null and n.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null))
      )
  ), page_ids as (
    select n.id from selected n order by n.note_created_at_utc desc nulls last,n.id desc limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select n.id,n.ricochet_note_id,n.lead_row_id,n.phone,n.phone_key,n.note_text,n.note_user_name,n.note_user_email,
      coalesce(n.note_created_at_utc,n.detected_at_utc) note_created_at,n.note_date_eastern note_date,
      n.matched_call_event_id,n.match_method,n.match_confidence,
      coalesce(ld.first_name,lp.first_name) first_name,coalesce(ld.last_name,lp.last_name) last_name,
      coalesce(ld.lead_status,lp.lead_status) lead_status,coalesce(ld.lead_type,lp.lead_type) lead_type,
      coalesce(recordings.items,'[]'::jsonb) recordings
    from page_ids p join reporting.note_events n on n.id=p.id
    left join reporting.leads ld on ld.id=n.lead_row_id
    left join lateral (select l.* from reporting.leads l where n.lead_row_id is null and l.phone_key=n.phone_key order by l.id desc limit 1) lp on true
    left join lateral (
      select jsonb_agg(to_jsonb(r) order by r.exact_match desc,r.sort_at desc nulls last,r.id desc) items from (
        select c.id,c.call_uuid,c.call_datetime_text call_date_time,c.call_timestamp sort_at,c.call_date_eastern call_date,
          c.duration_seconds,c.user_name,c.user_id,
          case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
          c.recording_status,(c.id=n.matched_call_event_id) exact_match
        from reporting.call_events c
        where nullif(trim(coalesce(c.call_uuid,'')),'') is not null
          and ((n.lead_row_id is not null and c.lead_id=n.lead_row_id)
            or (n.lead_row_id is null and c.phone_key=n.phone_key))
        order by (c.id=n.matched_call_event_id) desc,c.call_timestamp desc nulls last,c.id desc
        limit 25
      ) r
    ) recordings on true
    order by n.note_created_at_utc desc nulls last,n.id desc
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_ai_review(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),100); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with filtered_leads as materialized (
    select l.id,l.phone_key from reporting.leads l where report_api.lead_matches(l,p_filters)
  ), selected as materialized (
    select c.id,c.call_timestamp,c.ai_analysis_status,c.ai_status_matches,c.ai_note_matches
    from reporting.call_events c where c.call_date_eastern between p_from and p_to
      and (
        not v_has_filters
        or (c.lead_id is not null and c.lead_id in (select l.id from filtered_leads l))
        or (c.lead_id is null and c.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null))
      )
      and (coalesce(p_filters->>'ai_review','') <> 'completed'
        or lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed')
      and (coalesce(p_filters->>'ai_review','') <> 'needs_review'
        or (lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed'
          and (coalesce(c.ai_status_matches,true) is false or coalesce(c.ai_note_matches,true) is false)))
      and (coalesce(p_filters->>'ai_review','') <> 'not_reviewed'
        or lower(trim(coalesce(c.ai_analysis_status,''))) <> 'completed')
      and (coalesce(p_filters->>'recording','') <> 'available'
        or nullif(trim(coalesce(c.call_uuid,'')),'') is not null)
      and (coalesce(p_filters->>'recording','') <> 'missing'
        or nullif(trim(coalesce(c.call_uuid,'')),'') is null)
      and nullif(trim(coalesce(c.call_uuid,'')),'') is not null
  ), page_ids as (
    select c.id from selected c
    order by case when lower(trim(coalesce(c.ai_analysis_status,'')))='completed'
      and (coalesce(c.ai_status_matches,true) is false or coalesce(c.ai_note_matches,true) is false) then 0 else 1 end,
      c.call_timestamp desc nulls last,c.id desc limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select c.id call_event_id,c.call_uuid,c.call_datetime_text call_date_time,c.user_name,c.user_id,
      coalesce(l.first_name,c.first_name) first_name,coalesce(l.last_name,c.last_name) last_name,l.lead_status,
      c.ai_analysis_status,c.ai_agent_score,c.ai_summary,c.ai_status_matches,c.ai_note_matches,
      case when coalesce(c.ai_status_matches,true) is false then 'Status mismatch'
        when coalesce(c.ai_note_matches,true) is false then 'Note mismatch'
        when lower(trim(coalesce(c.ai_analysis_status,''))) <> 'completed' then 'Not reviewed'
        else 'Completed' end trigger_reason
    from page_ids p join reporting.call_events c on c.id=p.id left join reporting.leads l on l.id=c.lead_id
    order by c.call_timestamp desc nulls last,c.id desc
  ), totals as (
    select count(*) filter (where lower(trim(coalesce(ai_analysis_status,'')))='completed')::bigint reviewed,
      count(*) filter (where lower(trim(coalesce(ai_analysis_status,'')))='completed' and (coalesce(ai_status_matches,true) is false or coalesce(ai_note_matches,true) is false))::bigint needs_review,
      count(*) filter (where lower(trim(coalesce(ai_analysis_status,''))) in ('queued','pending'))::bigint queued,
      count(*) filter (where lower(trim(coalesce(ai_analysis_status,'')))='processing')::bigint processing
    from selected
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'totals',(select to_jsonb(t) from totals t),'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_csv_match(p_rows jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'p_rows must be a JSON array.' using errcode='22023'; end if;
  if jsonb_array_length(p_rows) > 500 then raise exception 'CSV batches are limited to 500 rows.' using errcode='22023'; end if;
  with input as (
    select * from jsonb_to_recordset(p_rows) as x(row_number integer,first_name text,last_name text,email text,phone text)
  ), matched as (
    select i.*,m.id,m.first_name matched_first_name,m.last_name matched_last_name,m.phone matched_phone,m.email matched_email,
      m.lead_status,m.lead_type,m.vendor,m.user_name,m.user_id,m.match_method,m.match_count,
      coalesce(ca.call_count,0) call_count,coalesce(ca.recording_count,0) recording_count,ca.latest_call_at,
      coalesce(na.note_count,0) note_count,na.latest_note
    from input i
    left join lateral (
      select l.*,
        case when report_api.normalize_phone(i.phone) <> '' and l.phone_key = report_api.normalize_phone(i.phone) then 'PHONE' else 'EMAIL' end match_method,
        count(*) over () match_count
      from reporting.leads l
      where (report_api.normalize_phone(i.phone) <> '' and l.phone_key = report_api.normalize_phone(i.phone))
         or (nullif(lower(trim(coalesce(i.email,''))),'') is not null and lower(trim(coalesce(l.email,''))) = lower(trim(i.email)))
      order by (report_api.normalize_phone(i.phone) <> '' and l.phone_key = report_api.normalize_phone(i.phone)) desc,l.id desc
      limit 1
    ) m on true
    left join lateral (
      select count(*)::bigint call_count,
        count(*) filter (where nullif(trim(coalesce(c.call_uuid,'')),'') is not null)::bigint recording_count,
        max(c.call_datetime_text) latest_call_at
      from reporting.call_events c
      where m.id is not null and (c.lead_id=m.id or (c.lead_id is null and c.phone_key=m.phone_key))
    ) ca on true
    left join lateral (
      select count(*)::bigint note_count,(array_agg(n.note_text order by n.id desc))[1] latest_note
      from reporting.note_events n
      where m.id is not null and n.is_new_append is true
        and (n.lead_row_id=m.id or (n.lead_row_id is null and n.phone_key=m.phone_key))
    ) na on true
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'row_number',row_number,'input_first_name',first_name,'input_last_name',last_name,'input_phone',phone,'input_email',email,
    'match_status',case when id is null then 'NOT_FOUND' when match_count > 1 then 'MULTIPLE_MATCHES' else 'MATCHED' end,
    'match_method',match_method,'match_count',coalesce(match_count,0),'lead_id',id,
    'matched_first_name',matched_first_name,'matched_last_name',matched_last_name,'matched_phone',matched_phone,'matched_email',matched_email,
    'lead_status',lead_status,'lead_type',lead_type,'vendor',vendor,'user_name',user_name,'user_id',user_id,
    'call_count',call_count,'note_count',note_count,'recording_count',recording_count,
    'latest_call_at',latest_call_at,'latest_note',latest_note
  ) order by row_number),'[]'::jsonb) into v_result from matched;
  return v_result;
end;
$$;

create or replace function public.dashboard_csv_call_details(p_lead_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  if coalesce(array_length(p_lead_ids,1),0) = 0 then return '[]'::jsonb; end if;
  if array_length(p_lead_ids,1) > 500 then raise exception 'Call-detail batches are limited to 500 lead IDs.' using errcode='22023'; end if;
  with leads as materialized (
    select l.id,l.phone_key,l.first_name,l.last_name,l.phone,l.email,l.lead_status,l.lead_type,l.vendor
    from reporting.leads l where l.id=any(p_lead_ids)
  ), rows as (
    select c.id call_event_id,c.call_uuid,c.call_datetime_text call_date_time,c.call_date_eastern call_date,
      c.duration_seconds,c.call_status,c.user_name,c.user_id,c.recording_status,
      case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
      c.ai_analysis_status,c.ai_summary,c.ai_agent_score,
      l.id lead_id,l.first_name,l.last_name,l.phone,l.email,l.lead_status,l.lead_type,l.vendor,
      (select n.note_text from reporting.note_events n where n.matched_call_event_id=c.id order by n.id desc limit 1) matched_note
    from reporting.call_events c
    join lateral (
      select x.* from leads x
      where x.id=c.lead_id or (c.lead_id is null and x.phone_key=c.phone_key)
      order by (x.id=c.lead_id) desc,x.id desc limit 1
    ) l on true
    order by c.call_timestamp desc nulls last,c.id desc
    limit 10000
  )
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_result from rows r;
  return v_result;
end;
$$;

-- Supporting indexes for the RPCs. Existing indexes are reused when already present.
create index if not exists reporting_leads_activity_date_idx on reporting.leads (lead_date_eastern);
create index if not exists reporting_leads_created_date_idx on reporting.leads (created_date_eastern);
create index if not exists reporting_leads_phone_key_idx on reporting.leads (phone_key);
create index if not exists reporting_leads_email_lower_idx on reporting.leads (lower(trim(email)));
create index if not exists reporting_leads_source_description_idx on reporting.leads (lower(trim(source_lead_description)));
create index if not exists reporting_leads_live_email_idx on reporting.leads (live_email_sent);
create index if not exists reporting_leads_city_idx on reporting.leads (lower(trim(city)));
create index if not exists reporting_leads_zip_idx on reporting.leads (property_zip);
create index if not exists reporting_leads_first_live_sent_idx on reporting.leads (first_live_date_eastern) where live_email_sent is true;
create index if not exists reporting_calls_date_id_idx on reporting.call_events (call_date_eastern,id desc);
create index if not exists reporting_calls_lead_date_idx on reporting.call_events (lead_id,call_date_eastern,id desc);
create index if not exists reporting_calls_phone_date_idx on reporting.call_events (phone_key,call_date_eastern,id desc) where lead_id is null;
create index if not exists reporting_calls_uuid_idx on reporting.call_events (call_uuid) where call_uuid is not null;
create index if not exists reporting_notes_date_id_idx on reporting.note_events (note_date_eastern,id desc) where is_new_append is true;
create index if not exists reporting_notes_lead_date_idx on reporting.note_events (lead_row_id,note_date_eastern,id desc) where is_new_append is true;
create index if not exists reporting_notes_phone_date_idx on reporting.note_events (phone_key,note_date_eastern,id desc) where lead_row_id is null and is_new_append is true;

-- Deliberately preserve every existing reporting/AI schema and table grant during the
-- parallel testing period. The new website itself uses only the protected RPC functions.

revoke execute on function public.dashboard_authorized() from public, anon;
revoke execute on function public.dashboard_filter_options(date,date) from public, anon;
revoke execute on function public.dashboard_overview(date,date,jsonb) from public, anon;
revoke execute on function public.dashboard_team(date,date,jsonb) from public, anon;
revoke execute on function public.dashboard_leads(date,date,jsonb,integer,integer) from public, anon;
revoke execute on function public.dashboard_calls(date,date,jsonb,integer,integer) from public, anon;
revoke execute on function public.dashboard_notes(date,date,jsonb,integer,integer) from public, anon;
revoke execute on function public.dashboard_ai_review(date,date,jsonb,integer,integer) from public, anon;
revoke execute on function public.dashboard_csv_match(jsonb) from public, anon;
revoke execute on function public.dashboard_csv_call_details(bigint[]) from public, anon;

grant execute on function public.dashboard_authorized() to authenticated;
grant execute on function public.dashboard_filter_options(date,date) to authenticated;
grant execute on function public.dashboard_overview(date,date,jsonb) to authenticated;
grant execute on function public.dashboard_team(date,date,jsonb) to authenticated;
grant execute on function public.dashboard_leads(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_calls(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_notes(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_ai_review(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_csv_match(jsonb) to authenticated;
grant execute on function public.dashboard_csv_call_details(bigint[]) to authenticated;

commit;

-- After inviting a user in Authentication > Users, authorize that user once:
-- insert into public.report_users (user_id, display_name, role)
-- select id, email, 'admin' from auth.users where email = 'you@example.com'
-- on conflict (user_id) do update set active=true, role=excluded.role;
