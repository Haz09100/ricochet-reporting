-- Complete call-AI review details and enriched Calls & AI rows.
-- Run after 006_lead_export_notes_calls.sql.

begin;

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
    select l.id,l.phone_key from reporting.leads l where v_has_filters and report_api.lead_matches(l,p_filters)
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
      and (coalesce(p_filters->>'ai_review','') <> 'completed' or lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed')
      and (coalesce(p_filters->>'ai_review','') <> 'needs_review' or (lower(trim(coalesce(c.ai_analysis_status,''))) = 'completed' and (coalesce(c.ai_status_matches,true) is false or coalesce(c.ai_note_matches,true) is false)))
      and (coalesce(p_filters->>'ai_review','') <> 'not_reviewed' or lower(trim(coalesce(c.ai_analysis_status,''))) <> 'completed')
      and (coalesce(p_filters->>'recording','') <> 'available' or nullif(trim(coalesce(c.call_uuid,'')),'') is not null)
      and (coalesce(p_filters->>'recording','') <> 'missing' or nullif(trim(coalesce(c.call_uuid,'')),'') is null)
  ), page_ids as (
    select c.id from selected c order by c.call_timestamp desc nulls last,c.id desc limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select c.id,coalesce(ld.id,lp.id,c.lead_id) lead_id,
      coalesce(ld.first_name,lp.first_name,c.first_name) first_name,
      coalesce(ld.last_name,lp.last_name,c.last_name) last_name,c.phone,c.phone_key,
      c.user_name,c.user_id,c.call_datetime_text call_date_time,c.call_date_eastern call_date,
      c.duration_seconds,c.call_status,c.call_type_id,
      case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
      coalesce(ld.lead_status,lp.lead_status) lead_status,
      case when ld.id is not null then report_api.classified_lead_type(ld) when lp.id is not null then report_api.classified_lead_type(lp) else coalesce(c.lead_type,'Unknown') end lead_type,
      coalesce(ld.vendor,lp.vendor) vendor,c.call_uuid,c.recording_status,
      c.ai_status,c.ai_analysis_status,c.ai_analysis_model,c.ai_agent_score,c.ai_summary,
      c.ai_status_matches,c.ai_note_matches,c.ai_recommended_status,c.ai_analysis_error
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

create or replace function public.dashboard_call_ai_review(p_call_event_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  if coalesce(p_call_event_id,0) <= 0 then
    raise exception 'A valid call event ID is required.' using errcode='22023';
  end if;

  select jsonb_build_object(
    'call',jsonb_build_object(
      'id',c.id,'call_event_id',c.id,'call_uuid',c.call_uuid,'lead_id',coalesce(l.id,c.lead_id),
      'first_name',coalesce(l.first_name,c.first_name),'last_name',coalesce(l.last_name,c.last_name),
      'phone',coalesce(l.phone,c.phone),'agent_name',c.user_name,'user_name',c.user_name,'user_id',c.user_id,
      'call_date_time',c.call_datetime_text,'call_date',c.call_date_eastern,'duration_seconds',c.duration_seconds,
      'call_status',c.call_status,'direction',case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end,
      'lead_status',l.lead_status,'lead_type',case when l.id is not null then report_api.classified_lead_type(l) else coalesce(c.lead_type,'Unknown') end,
      'vendor',l.vendor,'recording_status',c.recording_status
    ),
    'analysis',jsonb_build_object(
      'transcription_status',c.ai_status,'transcription_model',c.ai_model,'detected_language',c.ai_detected_language,
      'original_transcript',c.ai_transcript_original,'transcription_error',c.ai_error,'transcribed_at',c.ai_processed_at,
      'analysis_status',c.ai_analysis_status,'analysis_model',c.ai_analysis_model,'analysis_language',c.ai_language,
      'english_transcript',c.ai_english_transcript,'summary',c.ai_summary,'ai_lead_type',c.ai_lead_type,
      'note_matches',c.ai_note_matches,'note_match_score',c.ai_note_match_score,'note_differences',c.ai_note_differences,
      'corrected_note',c.ai_corrected_note,'current_status',c.ai_current_lead_status,
      'recommended_status',c.ai_recommended_status,'status_matches',c.ai_status_matches,'status_reason',c.ai_status_reason,
      'agent_score',c.ai_agent_score,'missing_questions',c.ai_missing_questions,'coaching',c.ai_coaching,
      'next_action',c.ai_next_action,'analysis_error',c.ai_analysis_error,'reviewed_at',c.ai_analysis_processed_at
    ),
    'note',case when n.id is null then '{}'::jsonb else jsonb_build_object(
      'id',n.id,'ricochet_note_id',n.ricochet_note_id,'text',n.note_text,
      'owner',coalesce(nullif(trim(n.note_user_name),''),nullif(trim(n.note_user_email),''),'Unknown note owner'),
      'owner_id',n.note_user_id,'created_at',coalesce(n.note_created_at_utc,n.detected_at_utc),
      'match_method',n.match_method,'match_confidence',n.match_confidence
    ) end
  ) into v_result
  from reporting.call_events c
  left join lateral (
    select x.* from reporting.leads x
    where x.id=c.lead_id or (c.lead_id is null and x.phone_key=c.phone_key)
    order by (x.id=c.lead_id) desc nulls last,x.id desc limit 1
  ) l on true
  left join lateral (
    select x.* from reporting.note_events x
    where x.matched_call_event_id=c.id
    order by coalesce(x.note_created_at_utc,x.detected_at_utc) desc nulls last,x.id desc limit 1
  ) n on true
  where c.id=p_call_event_id;

  if v_result is null then raise exception 'Call event was not found.' using errcode='P0002'; end if;
  return v_result;
end;
$$;

revoke execute on function public.dashboard_calls(date,date,jsonb,integer,integer) from public,anon;
revoke execute on function public.dashboard_call_ai_review(bigint) from public,anon;
grant execute on function public.dashboard_calls(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_call_ai_review(bigint) to authenticated;

commit;
