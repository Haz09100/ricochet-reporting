-- Lead-created timestamp to first-call response timing.
-- Run after 007_call_ai_review.sql.

begin;

create or replace function report_api.try_local_timestamp(p_value text)
returns timestamp
language plpgsql
immutable
set search_path = ''
as $$
declare v_value text := nullif(trim(coalesce(p_value,'')),'');
begin
  if v_value is null then return null; end if;
  begin
    return v_value::timestamp;
  exception when others then
    return null;
  end;
end;
$$;

create or replace function public.dashboard_first_response_metrics(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from,p_to);
  with received as materialized (
    select l.id,l.phone_key,report_api.try_local_timestamp(l.created_date_text) created_at
    from reporting.leads l
    where l.created_date_eastern between p_from and p_to
      and (not v_has_filters or report_api.lead_matches(l,p_filters))
  ), response_rows as materialized (
    select r.id,r.created_at,fc.first_call_at,
      case when r.created_at is not null and fc.first_call_at is not null
        then greatest(0,extract(epoch from (fc.first_call_at-r.created_at)))::bigint else null end seconds_to_first_call
    from received r
    left join lateral (
      select coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) first_call_at
      from reporting.call_events ce
      where (ce.lead_id=r.id or (ce.lead_id is null and ce.phone_key=r.phone_key))
        and (r.created_at is null or coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) >= r.created_at)
      order by coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) asc nulls last,ce.id asc
      limit 1
    ) fc on true
  )
  select jsonb_build_object(
    'received_leads',count(*)::bigint,
    'created_time_available',count(*) filter (where created_at is not null)::bigint,
    'first_called_leads',count(*) filter (where first_call_at is not null)::bigint,
    'never_called_leads',count(*) filter (where first_call_at is null)::bigint,
    'response_sample',count(seconds_to_first_call)::bigint,
    'average_seconds',round(avg(seconds_to_first_call))::bigint,
    'median_seconds',round(percentile_cont(0.5) within group (order by seconds_to_first_call))::bigint,
    'within_5_minutes',count(*) filter (where seconds_to_first_call between 0 and 300)::bigint,
    'within_5_minutes_rate',case when count(*) filter (where created_at is not null)>0
      then round(100.0*count(*) filter (where seconds_to_first_call between 0 and 300)/(count(*) filter (where created_at is not null)),1) else 0 end,
    'generated_at',now()
  ) into v_result
  from response_rows;
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
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),1000); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with selected as materialized (
    select l.* from reporting.leads l
    where (not v_has_filters or report_api.lead_matches(l,p_filters))
      and case when coalesce(p_filters->>'date_basis','activity')='created' then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
  ), page_ids as materialized (
    select l.id from selected l
    order by l.lead_date_eastern desc nulls last,l.id desc
    limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.lead_status,report_api.classified_lead_type(l) lead_type,l.vendor,l.user_name,l.user_id,
      l.address,l.address_2,l.city,coalesce(nullif(trim(l.property_state),''),g.geo_state) property_state,l.property_zip,
      g.county,g.metro,g.match_method geo_match_method,l.lead_date_eastern lead_date,l.created_date_eastern created_date,
      l.created_date_text created_at,l.first_live_date_eastern first_live_date,l.live_email_sent,l.fub_id,
      l.source_lead_description,report_api.appointment_type(l) appointment_type,
      fc.first_call_at,fc.first_call_owner,fc.first_call_direction,
      case when fc.first_call_at is not null and report_api.try_local_timestamp(l.created_date_text) is not null
        then greatest(0,extract(epoch from (fc.first_call_at-report_api.try_local_timestamp(l.created_date_text))))::bigint
        else null end seconds_to_first_call
    from page_ids p
    join selected l on l.id=p.id
    left join lateral report_api.resolve_geo(l.property_zip,l.property_state,l.city) g on true
    left join lateral (
      select
        coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) first_call_at,
        ce.user_name first_call_owner,
        case when trim(coalesce(ce.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(ce.call_direction,''),'Outbound') end first_call_direction
      from reporting.call_events ce
      where (ce.lead_id=l.id or (ce.lead_id is null and ce.phone_key=l.phone_key))
        and (report_api.try_local_timestamp(l.created_date_text) is null
          or coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) >= report_api.try_local_timestamp(l.created_date_text))
      order by coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) asc nulls last,ce.id asc
      limit 1
    ) fc on true
    order by l.lead_date_eastern desc nulls last,l.id desc
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_lead_export(
  p_from date,
  p_to date,
  p_filters jsonb default '{}'::jsonb,
  p_fields jsonb default '[]'::jsonb,
  p_page integer default 1,
  p_page_size integer default 250
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_page integer := greatest(coalesce(p_page,1),1);
  v_size integer := least(greatest(coalesce(p_page_size,250),10),500);
  v_has_filters boolean := report_api.has_lead_filters(p_filters);
  v_need_notes boolean := coalesce(p_fields,'[]'::jsonb) ?| array['note_count','latest_note_date','latest_note_owner','latest_note','all_notes'];
  v_need_calls boolean := coalesce(p_fields,'[]'::jsonb) ?| array['call_count','latest_call_date','latest_call_owner','latest_call_direction','latest_call_duration','latest_call_status','recording_count','latest_call_uuid','all_calls'];
  v_need_response boolean := coalesce(p_fields,'[]'::jsonb) ?| array['created_time','first_call_time','first_call_owner','first_call_direction','seconds_to_first_call','time_to_first_call'];
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from,p_to);

  with selected as materialized (
    select l.* from reporting.leads l
    where (not v_has_filters or report_api.lead_matches(l,p_filters))
      and case when coalesce(p_filters->>'date_basis','activity')='created' then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
  ), page_ids as materialized (
    select l.id from selected l order by l.lead_date_eastern desc nulls last,l.id desc
    limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.lead_status,
      report_api.classified_lead_type(l) lead_type,l.vendor,l.user_name,l.user_id,
      l.address,l.address_2,l.city,coalesce(nullif(trim(l.property_state),''),g.geo_state) property_state,
      l.property_zip,g.county,g.metro,g.match_method geo_match_method,
      l.lead_date_eastern lead_date,l.created_date_eastern created_date,l.created_date_text created_at,
      l.first_live_date_eastern first_live_date,l.live_email_sent,l.fub_id,
      l.source_lead_description,report_api.appointment_type(l) appointment_type,
      fc.first_call_at,fc.first_call_owner,fc.first_call_direction,
      case when fc.first_call_at is not null and report_api.try_local_timestamp(l.created_date_text) is not null
        then greatest(0,extract(epoch from (fc.first_call_at-report_api.try_local_timestamp(l.created_date_text))))::bigint else null end seconds_to_first_call,
      coalesce(n.note_count,0) note_count,n.latest_note_date,n.latest_note_owner,n.latest_note,n.all_notes,
      coalesce(c.call_count,0) call_count,c.latest_call_date,c.latest_call_owner,c.latest_call_direction,c.latest_call_duration,c.latest_call_status,
      coalesce(c.recording_count,0) recording_count,c.latest_call_uuid,c.all_calls
    from page_ids p
    join selected l on l.id=p.id
    left join lateral report_api.resolve_geo(l.property_zip,l.property_state,l.city) g on true
    left join lateral (
      select
        coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) first_call_at,
        ce.user_name first_call_owner,
        case when trim(coalesce(ce.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(ce.call_direction,''),'Outbound') end first_call_direction
      from reporting.call_events ce
      where v_need_response and (ce.lead_id=l.id or (ce.lead_id is null and ce.phone_key=l.phone_key))
        and (report_api.try_local_timestamp(l.created_date_text) is null
          or coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) >= report_api.try_local_timestamp(l.created_date_text))
      order by coalesce(ce.call_timestamp at time zone 'America/New_York',report_api.try_local_timestamp(coalesce(nullif(ce.call_datetime_text,''),ce.call_datetime_raw))) asc nulls last,ce.id asc
      limit 1
    ) fc on true
    left join lateral (
      select coalesce(max(x.total_count),0)::integer note_count,
        (array_agg(x.note_time order by x.note_time desc nulls last,x.id desc))[1] latest_note_date,
        (array_agg(x.note_owner order by x.note_time desc nulls last,x.id desc))[1] latest_note_owner,
        (array_agg(x.note_text order by x.note_time desc nulls last,x.id desc))[1] latest_note,
        string_agg(concat_ws(' | ',coalesce(to_char(x.note_time,'YYYY-MM-DD HH24:MI:SS'),'Time unavailable'),coalesce(nullif(trim(x.note_owner),''),'Unknown note owner'),regexp_replace(coalesce(x.note_text,''),'[[:space:]]+',' ','g')),E'\n---\n' order by x.note_time desc nulls last,x.id desc) all_notes
      from (
        select ne.id,coalesce(ne.note_created_at_utc,ne.detected_at_utc) note_time,coalesce(nullif(trim(ne.note_user_name),''),nullif(trim(ne.note_user_email),'')) note_owner,ne.note_text,count(*) over() total_count
        from reporting.note_events ne
        where v_need_notes and (ne.lead_row_id=l.id or (ne.lead_row_id is null and ne.phone_key=l.phone_key))
        order by coalesce(ne.note_created_at_utc,ne.detected_at_utc) desc nulls last,ne.id desc limit 100
      ) x
    ) n on v_need_notes
    left join lateral (
      select coalesce(max(x.total_count),0)::integer call_count,
        (array_agg(x.call_date_time order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_date,
        (array_agg(x.call_owner order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_owner,
        (array_agg(x.direction order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_direction,
        (array_agg(x.duration_seconds order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_duration,
        (array_agg(x.call_status order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_status,
        coalesce(max(x.total_recordings),0)::integer recording_count,
        (array_agg(x.call_uuid order by x.call_timestamp desc nulls last,x.id desc))[1] latest_call_uuid,
        string_agg(concat_ws(' | ',coalesce(nullif(trim(x.call_date_time),''),'Time unavailable'),coalesce(nullif(trim(x.call_owner),''),'Unknown call owner'),coalesce(nullif(trim(x.direction),''),'Unknown direction'),concat(coalesce(x.duration_seconds,0),' seconds'),coalesce(nullif(trim(x.call_status),''),'Unknown status'),case when nullif(trim(coalesce(x.call_uuid,'')),'') is not null then concat('Recording UUID: ',x.call_uuid) end),E'\n---\n' order by x.call_timestamp desc nulls last,x.id desc) all_calls
      from (
        select ce.id,ce.call_timestamp,ce.call_datetime_text call_date_time,ce.user_name call_owner,ce.duration_seconds,ce.call_status,ce.call_uuid,
          case when trim(coalesce(ce.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(ce.call_direction,''),'Outbound') end direction,
          count(*) over() total_count,count(*) filter (where nullif(trim(coalesce(ce.call_uuid,'')),'') is not null) over() total_recordings
        from reporting.call_events ce
        where v_need_calls and (ce.lead_id=l.id or (ce.lead_id is null and ce.phone_key=l.phone_key))
        order by ce.call_timestamp desc nulls last,ce.id desc limit 100
      ) x
    ) c on v_need_calls
    order by l.lead_date_eastern desc nulls last,l.id desc
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

revoke execute on function public.dashboard_leads(date,date,jsonb,integer,integer) from public,anon;
grant execute on function public.dashboard_leads(date,date,jsonb,integer,integer) to authenticated;
revoke execute on function public.dashboard_first_response_metrics(date,date,jsonb) from public,anon;
grant execute on function public.dashboard_first_response_metrics(date,date,jsonb) to authenticated;
revoke execute on function public.dashboard_lead_export(date,date,jsonb,jsonb,integer,integer) from public,anon;
grant execute on function public.dashboard_lead_export(date,date,jsonb,jsonb,integer,integer) to authenticated;

commit;
